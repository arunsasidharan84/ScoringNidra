use std::fs::File;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;
use std::ffi::{CString, CStr};
use std::os::raw::c_char;
use crate::edf::{EdfFile, EdfSignal};

#[derive(Debug, Clone)]
pub struct NkPatient {
    pub id: String,
    pub name: String,
    pub sex: String,
    pub birthday: String,
    pub start_date: String,
    pub start_time: String,
}

impl Default for NkPatient {
    fn default() -> Self {
        Self {
            id: "ANONYMOUS".into(),
            name: "Anonymous".into(),
            sex: "X".into(),
            birthday: "01-JAN-1900".into(),
            start_date: "01.01.20".into(),
            start_time: "00.00.00".into(),
        }
    }
}

pub struct NkDataBlock {
    pub address: u32,
    pub rec_address: u32,
    pub num_samples: usize,
}

pub fn get_nk_channel_name(ch_idx: usize) -> String {
    match ch_idx + 1 {
        1 => "FP1".into(),
        2 => "FP2".into(),
        3 => "F3".into(),
        4 => "F4".into(),
        5 => "C3".into(),
        6 => "C4".into(),
        7 => "P3".into(),
        8 => "P4".into(),
        9 => "O1".into(),
        10 => "O2".into(),
        11 => "F7".into(),
        12 => "F8".into(),
        13 => "T3".into(),
        14 => "T4".into(),
        15 => "T5".into(),
        16 => "T6".into(),
        17 => "FZ".into(),
        18 => "CZ".into(),
        19 => "PZ".into(),
        20 => "E".into(),
        21 => "PG1".into(),
        22 => "PG2".into(),
        23 => "A1".into(),
        24 => "A2".into(),
        25 => "T1".into(),
        26 => "T2".into(),
        27..=37 => format!("X{}", ch_idx + 1 - 26),
        38 => "BN".into(),
        39 => "AV".into(),
        40 => "SD".into(),
        41 => "Aav".into(),
        42 => "0V".into(),
        43..=70 => format!("DC{:02}", ch_idx + 1 - 42),
        71 => "SpO2".into(),
        72 => "EtCO2".into(),
        73 => "Pulse".into(),
        74 => "CO2Wave".into(),
        75 => "BN1".into(),
        76 => "BN2".into(),
        77 => "Mark1".into(),
        78 => "Mark2".into(),
        101 => "BP1".into(),
        102 => "BP2".into(),
        103 => "BP3".into(),
        104 => "BP4".into(),
        other => format!("EEG{}", other),
    }
}

pub fn read_21e_channel_names(path: &Path) -> std::collections::HashMap<usize, String> {
    let mut names = std::collections::HashMap::new();
    let Ok(file) = File::open(path) else { return names; };
    let reader = BufReader::new(file);
    let mut in_electrode_section = false;

    for line in reader.lines().flatten() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if trimmed.eq_ignore_ascii_case("[ELECTRODE]") {
            in_electrode_section = true;
            continue;
        }
        if trimmed.starts_with('[') {
            in_electrode_section = false;
            continue;
        }
        if in_electrode_section && trimmed.contains('=') {
            let parts: Vec<&str> = trimmed.split('=').collect();
            if parts.len() == 2 {
                if let Ok(idx) = parts[0].trim().parse::<usize>() {
                    let name = parts[1].trim();
                    if !name.is_empty() {
                        names.insert(idx, name.to_string());
                    }
                }
            }
        }
    }
    names
}

pub fn read_pnt_patient_info(path: &Path) -> NkPatient {
    let mut p = NkPatient::default();
    let Ok(mut file) = File::open(path) else { return p; };
    let mut buf = vec![0u8; 2048];
    if file.read(&mut buf).is_err() { return p; }

    let clean = |b: &[u8]| -> String {
        String::from_utf8_lossy(b).trim_matches(|c: char| c == '\0' || c.is_whitespace()).to_string()
    };

    if buf.len() >= 1550 { p.id = clean(&buf[1540..1550]); }
    if buf.len() >= 1602 { p.name = clean(&buf[1582..1602]); }
    if buf.len() >= 1616 { p.sex = clean(&buf[1610..1616]); }
    if buf.len() >= 1642 { p.birthday = clean(&buf[1632..1642]); }
    if buf.len() >= 78 {
        let date_str = clean(&buf[64..78]);
        if date_str.len() >= 14 {
            p.start_date = format!("{}.{}.{}", &date_str[6..8], &date_str[4..6], &date_str[2..4]);
            p.start_time = format!("{}.{}.{}", &date_str[8..10], &date_str[10..12], &date_str[12..14]);
        }
    }

    p
}

pub fn load_nihon_kohden_impl(eeg_path: &Path) -> Result<EdfFile, String> {
    let mut file = File::open(eeg_path).map_err(|e| format!("Cannot open .EEG file: {e}"))?;
    let file_len = file.metadata().map_err(|e| e.to_string())?.len() as usize;

    let mut header = vec![0u8; 6144];
    file.read_exact(&mut header).map_err(|e| format!("EEG file header truncated: {e}"))?;

    let ctl_cnt = header[145] as usize;
    if ctl_cnt == 0 {
        return Err("Invalid Nihon Kohden control block count".into());
    }

    // Locate data blocks
    let mut blocks = Vec::new();
    for i in 0..ctl_cnt {
        let ctl_offset = 146 + i * 20;
        if ctl_offset + 4 > header.len() { break; }
        let ctl_addr = u32::from_le_bytes([header[ctl_offset], header[ctl_offset+1], header[ctl_offset+2], header[ctl_offset+3]]) as usize;
        if ctl_addr + 24 > file_len { continue; }

        let mut ctl_hdr = [0u8; 32];
        file.seek(SeekFrom::Start(ctl_addr as u64)).map_err(|e| e.to_string())?;
        if file.read_exact(&mut ctl_hdr).is_err() { continue; }

        let data_cnt = ctl_hdr[23] as usize;
        for j in 0..data_cnt {
            let data_ptr_addr = ctl_addr + j * 20 + 18;
            file.seek(SeekFrom::Start(data_ptr_addr as u64)).map_err(|e| e.to_string())?;
            let mut addr_buf = [0u8; 4];
            if file.read_exact(&mut addr_buf).is_err() { continue; }
            let data_addr = u32::from_le_bytes(addr_buf);
            if data_addr > 0 && (data_addr as usize) < file_len {
                let rec_addr = data_addr + 32;
                blocks.push(NkDataBlock {
                    address: data_addr,
                    rec_address: rec_addr,
                    num_samples: 0,
                });
            }
        }
    }

    if blocks.is_empty() {
        return Err("No valid data blocks found in Nihon Kohden .EEG file".into());
    }

    // Sort blocks by start address
    blocks.sort_by_key(|b| b.address);

    // Determine channels
    let parent = eeg_path.parent().unwrap_or_else(|| Path::new("."));
    let stem = eeg_path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let elec_path_21e = parent.join(format!("{stem}.21E"));
    let elec_path_lower = parent.join(format!("{stem}.21e"));
    let custom_names = if elec_path_21e.exists() {
        read_21e_channel_names(&elec_path_21e)
    } else if elec_path_lower.exists() {
        read_21e_channel_names(&elec_path_lower)
    } else {
        std::collections::HashMap::new()
    };

    let max_custom_ch = custom_names.keys().max().copied().unwrap_or(0);
    let num_channels = std::cmp::max(32, max_custom_ch + 1);
    let sample_rate = 200.0f32; // Default NK EEG sample rate

    let u_v_gain = 1e-6 * ((3199.902 + 3200.0) / 65535.0); // ~9.7656e-8

    // Pre-allocate channels
    let mut channel_samples: Vec<Vec<f32>> = (0..num_channels).map(|_| Vec::new()).collect();

    // Read full block payload across all data blocks
    for i in 0..blocks.len() {
        let rec_start = blocks[i].rec_address as usize;
        let block_end = if i + 1 < blocks.len() {
            blocks[i + 1].address as usize
        } else {
            file_len
        };

        if block_end <= rec_start { continue; }
        let bytes_to_read = block_end - rec_start;

        if file.seek(SeekFrom::Start(rec_start as u64)).is_err() { continue; }

        let frame_bytes = num_channels * 2;
        let chunk_size = 1024 * 1024 * 4; // 4MB chunks
        let mut buf = vec![0u8; chunk_size];
        let mut remaining = bytes_to_read;

        while remaining >= frame_bytes {
            let target_read = std::cmp::min(remaining, chunk_size);
            let target_read = (target_read / frame_bytes) * frame_bytes;
            if target_read == 0 { break; }

            let n_read = file.read(&mut buf[..target_read]).unwrap_or(0);
            if n_read < frame_bytes { break; }

            remaining -= n_read;
            let n_frames = n_read / frame_bytes;

            for f in 0..n_frames {
                for ch in 0..num_channels {
                    let val_idx = f * num_channels + ch;
                    let b0 = buf[val_idx * 2];
                    let b1 = buf[val_idx * 2 + 1];
                    let raw_val = u16::from_le_bytes([b0, b1]) as f64;
                    let phys_microvolts = (raw_val - 32768.0) * u_v_gain * 1e6;
                    channel_samples[ch].push(phys_microvolts as f32);
                }
            }
        }
    }

    let mut signals = Vec::with_capacity(num_channels);
    for ch in 0..num_channels {
        let label_str = custom_names.get(&ch).cloned().unwrap_or_else(|| get_nk_channel_name(ch));
        let label_c = CString::new(label_str).unwrap_or_else(|_| CString::new("").unwrap());
        let samps = std::mem::take(&mut channel_samples[ch]);
        let count = samps.len() as i32;

        signals.push(EdfSignal {
            label: label_c.into_raw(),
            samples: samps.leak().as_mut_ptr(),
            sample_count: count,
        });
    }

    let total_duration = if num_channels > 0 && !signals.is_empty() {
        signals[0].sample_count as f32 / sample_rate
    } else {
        0.0
    };

    Ok(EdfFile {
        sample_rate_hz: sample_rate,
        signal_count: num_channels as i32,
        signals: signals.leak().as_mut_ptr(),
        duration_seconds: total_duration,
    })
}

#[no_mangle]
pub extern "C" fn sleep_eeg_load_nihon_kohden(path: *const c_char) -> *mut EdfFile {
    if path.is_null() { return std::ptr::null_mut(); }
    let path_str = unsafe { CStr::from_ptr(path) };
    let Ok(path_str) = path_str.to_str() else { return std::ptr::null_mut(); };

    match load_nihon_kohden_impl(Path::new(path_str)) {
        Ok(edf) => Box::into_raw(Box::new(edf)),
        Err(_) => std::ptr::null_mut(),
    }
}
