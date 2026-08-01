use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::ffi::{CString, CStr};
use std::os::raw::c_char;
use crate::edf::{EdfFile, EdfSignal};

pub struct SingleEmblaChannel {
    pub name: String,
    pub sample_rate: f32,
    pub scale: f64,
    pub samples: Vec<f32>,
}

pub fn load_single_ebm(file_path: &Path) -> Result<SingleEmblaChannel, String> {
    let mut file = File::open(file_path).map_err(|e| format!("Cannot open .ebm file: {e}"))?;
    let file_len = file.metadata().map_err(|e| e.to_string())?.len() as usize;

    // Read magic header up to 0x1A
    let mut magic_buf = Vec::new();
    let mut ch_buf = [0u8; 1];
    loop {
        if file.read_exact(&mut ch_buf).is_err() { break; }
        if ch_buf[0] == 0x1a { break; }
        magic_buf.push(ch_buf[0]);
    }
    let magic_str = String::from_utf8_lossy(&magic_buf);
    if !magic_str.contains("Embla") {
        return Err(format!("Not a valid Embla header: {magic_str}"));
    }

    // Endianness
    if file.read_exact(&mut ch_buf).is_err() {
        return Err("Truncated Embla header".into());
    }
    let is_big_endian = ch_buf[0] == 0xff;

    // Wide flag
    let mut is_wide = false;
    if file.read_exact(&mut ch_buf).is_err() {
        return Err("Truncated Embla header".into());
    }
    if ch_buf[0] == 0xff {
        let mut wide_buf = [0u8; 4];
        if file.read_exact(&mut wide_buf).is_ok() && wide_buf == [0xff, 0xff, 0xff, 0xff] {
            is_wide = true;
            let _ = file.seek(SeekFrom::Current(26)); // Skip 32-6
        }
    }

    let mut chan_name = file_path.file_stem().and_then(|s| s.to_str()).unwrap_or("EEG").to_string();
    let mut sample_rate = 200.0f32;
    let mut raw_range = [0.0f64, 0.0f64, 0.0f64];
    let mut data_start: usize = 0;
    let mut data_bytes_len: usize = 0;

    // Read tags
    loop {
        let tag_read_len = if is_wide { 4 } else { 2 };
        let mut marker_buf = [0u8; 4];
        if file.read_exact(&mut marker_buf[..tag_read_len]).is_err() { break; }
        if !is_wide {
            marker_buf[2] = 0;
            marker_buf[3] = 0;
        }

        let mut size_buf = [0u8; 4];
        if file.read_exact(&mut size_buf).is_err() { break; }
        let size = u32::from_le_bytes(size_buf) as usize;

        let marker = u32::from_le_bytes(marker_buf);

        match marker {
            0x00000090 => { // Channel Name
                let mut name_bytes = vec![0u8; size];
                if file.read_exact(&mut name_bytes).is_ok() {
                    let s = String::from_utf8_lossy(&name_bytes).trim_matches('\0').trim().to_string();
                    if !s.is_empty() { chan_name = s; }
                }
            }
            0x00000089 => { // DBLsampling
                let mut d_buf = [0u8; 8];
                if file.read_exact(&mut d_buf).is_ok() {
                    let val = if is_big_endian { f64::from_be_bytes(d_buf) } else { f64::from_le_bytes(d_buf) };
                    if val > 0.0 { sample_rate = val as f32; }
                }
            }
            0x0000008b => { // RawRange (3 doubles or 2 doubles)
                let n_doubles = size / 8;
                let mut r_vals = Vec::new();
                for _ in 0..n_doubles {
                    let mut d_buf = [0u8; 8];
                    if file.read_exact(&mut d_buf).is_ok() {
                        let val = if is_big_endian { f64::from_be_bytes(d_buf) } else { f64::from_le_bytes(d_buf) };
                        r_vals.push(val);
                    }
                }
                if r_vals.len() >= 3 {
                    raw_range = [r_vals[0], r_vals[1], r_vals[2]];
                } else if r_vals.len() == 2 {
                    raw_range = [r_vals[0], r_vals[1], 0.0];
                }
            }
            0x00000020 => { // Data
                data_start = file.stream_position().unwrap_or(0) as usize;
                data_bytes_len = size;
                let _ = file.seek(SeekFrom::Current(size as i64));
            }
            _ => {
                let _ = file.seek(SeekFrom::Current(size as i64));
            }
        }

        if (file.stream_position().unwrap_or(0) as usize) >= file_len {
            break;
        }
    }

    if data_start == 0 || data_bytes_len == 0 {
        return Err("No data block found in .ebm file".into());
    }

    // Determine scale (in microvolts per LSB count)
    let default_embla_scale = (1000.0 / 65536.0) as f64; // ~0.015258789 uV per count
    let scale = if raw_range[2] != 0.0 {
        let r2 = raw_range[2];
        if r2.abs() <= 1e-4 { r2 * 1e6 } else { r2 }
    } else {
        let max_abs = raw_range[0].abs().max(raw_range[1].abs());
        if max_abs > 0.0 {
            let max_abs_uv = if max_abs <= 1.0 { max_abs * 1e6 } else { max_abs };
            max_abs_uv / 32767.0
        } else {
            default_embla_scale
        }
    };

    // Read samples
    file.seek(SeekFrom::Start(data_start as u64)).map_err(|e| e.to_string())?;

    let sample_size = if is_wide { 2 } else { 1 };
    let n_samples = data_bytes_len / sample_size;
    let mut samples = Vec::with_capacity(n_samples);

    let mut raw_bytes = vec![0u8; data_bytes_len];
    file.read_exact(&mut raw_bytes).map_err(|e| format!("Failed to read sample bytes: {e}"))?;

    if is_wide {
        for chunk in raw_bytes.chunks_exact(2) {
            let val = if is_big_endian {
                i16::from_be_bytes([chunk[0], chunk[1]])
            } else {
                i16::from_le_bytes([chunk[0], chunk[1]])
            } as f64;
            samples.push((val * scale) as f32);
        }
    } else {
        for &b in &raw_bytes {
            let val = (b as i8) as f64;
            samples.push((val * scale) as f32);
        }
    }

    Ok(SingleEmblaChannel {
        name: chan_name,
        sample_rate,
        scale,
        samples,
    })
}

pub fn load_embla_dir_or_file_impl(path: &Path) -> Result<EdfFile, String> {
    let target_dir = if path.is_dir() {
        path.to_path_buf()
    } else {
        path.parent().unwrap_or_else(|| Path::new(".")).to_path_buf()
    };

    let mut ebm_files = Vec::new();
    let entries = fs::read_dir(&target_dir).map_err(|e| format!("Cannot list directory {}: {e}", target_dir.display()))?;
    for entry in entries.flatten() {
        let p = entry.path();
        if p.is_file() && p.extension().and_then(|s| s.to_str()).map(|s| s.eq_ignore_ascii_case("ebm")).unwrap_or(false) {
            ebm_files.push(p);
        }
    }

    if ebm_files.is_empty() {
        return Err("No .ebm channel files found in directory".into());
    }

    // Sort alphabetically so order is deterministic
    ebm_files.sort_by_key(|p| p.file_name().unwrap_or_default().to_os_string());

    let mut channels = Vec::new();
    for ebm_path in &ebm_files {
        if let Ok(ch) = load_single_ebm(ebm_path) {
            if !ch.samples.is_empty() {
                channels.push(ch);
            }
        }
    }

    if channels.is_empty() {
        return Err("Failed to parse any valid .ebm channels".into());
    }

    let max_sample_rate = channels.iter().map(|c| c.sample_rate).fold(0.0f32, f32::max);
    let target_sample_rate = if max_sample_rate > 0.0 { max_sample_rate } else { 200.0 };

    // Resample lower-rate channels to target_sample_rate using linear interpolation
    for ch in &mut channels {
        if ch.sample_rate > 0.0 && (ch.sample_rate - target_sample_rate).abs() > 0.1 && !ch.samples.is_empty() {
            let channel_dur = ch.samples.len() as f64 / ch.sample_rate as f64;
            let target_len = (channel_dur * target_sample_rate as f64) as usize;
            let old_len = ch.samples.len();
            if old_len > 1 && target_len > 1 {
                let mut resampled = Vec::with_capacity(target_len);
                let step = (old_len - 1) as f64 / (target_len - 1) as f64;
                for i in 0..target_len {
                    let src_idx = i as f64 * step;
                    let idx0 = (src_idx.floor() as usize).min(old_len - 1);
                    let idx1 = (idx0 + 1).min(old_len - 1);
                    let frac = (src_idx - idx0 as f64) as f32;
                    let val = ch.samples[idx0] * (1.0 - frac) + ch.samples[idx1] * frac;
                    resampled.push(val);
                }
                ch.samples = resampled;
                ch.sample_rate = target_sample_rate;
            }
        }
    }

    let max_samples = channels.iter().map(|c| c.samples.len()).max().unwrap_or(0);

    let mut signals = Vec::with_capacity(channels.len());
    for mut ch in channels {
        if ch.samples.len() < max_samples {
            let last_val = ch.samples.last().copied().unwrap_or(0.0);
            ch.samples.resize(max_samples, last_val);
        }
        let count = ch.samples.len() as i32;
        let label_c = CString::new(ch.name).unwrap_or_else(|_| CString::new("").unwrap());
        let samps = std::mem::take(&mut ch.samples);

        signals.push(EdfSignal {
            label: label_c.into_raw(),
            samples: samps.leak().as_mut_ptr(),
            sample_count: count,
        });
    }

    let num_channels = signals.len();
    let total_duration = if num_channels > 0 && max_samples > 0 {
        max_samples as f32 / target_sample_rate
    } else {
        0.0
    };

    Ok(EdfFile {
        sample_rate_hz: target_sample_rate,
        signal_count: num_channels as i32,
        signals: signals.leak().as_mut_ptr(),
        duration_seconds: total_duration,
    })
}

#[no_mangle]
pub extern "C" fn sleep_eeg_load_embla(path: *const c_char) -> *mut EdfFile {
    if path.is_null() { return std::ptr::null_mut(); }
    let path_str = unsafe { CStr::from_ptr(path) };
    let Ok(path_str) = path_str.to_str() else { return std::ptr::null_mut(); };

    match load_embla_dir_or_file_impl(Path::new(path_str)) {
        Ok(edf) => Box::into_raw(Box::new(edf)),
        Err(_) => std::ptr::null_mut(),
    }
}
