use std::path::Path;
use std::ffi::{CString, CStr};
use std::os::raw::c_char;
use std::io::Read;
use ole::Reader;

#[derive(Debug, Clone, serde::Serialize)]
pub struct EsedbStageRecord {
    pub stage: String,
    pub start_sec: f64,
}

pub struct EbmEvent {
    pub group_type_idx: usize,
}

pub fn parse_esedb_file(file_path: &Path) -> Result<Vec<EsedbStageRecord>, String> {
    let path_str = file_path.to_str().ok_or_else(|| "Invalid UTF-8 path".to_string())?;
    let mut reader = Reader::from_path(path_str).map_err(|e| format!("Cannot open OLE file {}: {:?}", file_path.display(), e))?;
    
    // Find Events stream
    let entry = reader.iterate().find(|e| e.name().contains("Events"))
        .ok_or_else(|| "No Events stream found in .esedb file".to_string())?;
    
    let mut slice = reader.get_entry_slice(&entry).map_err(|e| format!("Cannot read OLE stream: {:?}", e))?;
    let mut data = Vec::new();
    slice.read_to_end(&mut data).map_err(|e| format!("Cannot read stream data: {e}"))?;

    if data.is_empty() {
        return Err("Events stream is empty".into());
    }

    let mut event_types: Vec<String> = Vec::new();
    let mut events: Vec<EbmEvent> = Vec::new();
    let mut start_times: Vec<f64> = Vec::new();

    parse_parcel_entries(&data, 0, data.len(), false, &mut event_types, &mut events, &mut start_times);

    println!("[esedb] Total event_types: {}, events: {}, times: {}", event_types.len(), events.len(), start_times.len());
    println!("[esedb] Event types sample: {:?}", &event_types[..event_types.len().min(10)]);
    for (i, ev) in events.iter().take(10).enumerate() {
        let label = if ev.group_type_idx < event_types.len() { &event_types[ev.group_type_idx] } else { "OUT_OF_BOUNDS" };
        println!("  Event {}: grp={} ({})", i, ev.group_type_idx, label);
    }

    let first_time = start_times[0];
    let mut records = Vec::new();
    let n = events.len().min(start_times.len());

    for i in 0..n {
        let grp = events[i].group_type_idx;
        if grp < event_types.len() {
            let label = &event_types[grp];
            if label.contains("SLEEP") || label.contains("STAGE") || label.contains("NonREM") || label.contains("Wake") || label.contains("REM") {
                let start_sec = (start_times[i] - first_time).max(0.0);
                let stage_code = map_remlogic_label(label);
                records.push(EsedbStageRecord {
                    stage: stage_code,
                    start_sec,
                });
            }
        }
    }

    if records.is_empty() {
        return Err("No sleep stage records extracted from .esedb".into());
    }

    Ok(records)
}

fn parse_parcel_entries(
    data: &[u8],
    start: usize,
    end: usize,
    in_event_types: bool,
    event_types: &mut Vec<String>,
    events: &mut Vec<EbmEvent>,
    start_times: &mut Vec<f64>,
) {
    let mut pos = start;
    while pos + 12 <= end {
        let size = u32::from_le_bytes([data[pos], data[pos+1], data[pos+2], data[pos+3]]) as usize;
        let dsize = u32::from_le_bytes([data[pos+4], data[pos+5], data[pos+6], data[pos+7]]) as usize;
        let etype = u16::from_le_bytes([data[pos+8], data[pos+9]]);

        if size < 12 || pos + size > end || dsize > size {
            pos += 1;
            continue;
        }

        let name_start = pos + 12 + dsize;
        let name_end = pos + size;
        let name = if name_start < name_end && name_end <= end {
            String::from_utf8_lossy(&data[name_start..name_end]).trim_matches('\0').trim().to_string()
        } else {
            String::new()
        };

        let data_start = pos + 12;
        let data_end = (pos + 12 + dsize).min(end);

        match etype {
            13 => { // Parcel sub-container
                let is_event_types_parcel = name == "Event Types";
                parse_parcel_entries(data, data_start, data_end, is_event_types_parcel, event_types, events, start_times);
            }
            3 => { // String
                if in_event_types {
                    let val_str = String::from_utf8_lossy(&data[data_start..data_end]).trim_matches('\0').trim().to_string();
                    if !val_str.is_empty() {
                        event_types.push(val_str);
                    }
                }
            }
            2000 => { // Events
                let mut p = data_start;
                while p + 112 <= data_end {
                    let group_type_idx = u32::from_le_bytes([data[p+4], data[p+5], data[p+6], data[p+7]]) as usize;
                    events.push(EbmEvent { group_type_idx });
                    p += 112;
                }
            }
            2001 => { // EventsStartTimes
                let mut p = data_start;
                while p + 12 <= data_end {
                    let year = u16::from_le_bytes([data[p], data[p+1]]) as f64;
                    let mon = data[p+2] as f64;
                    let day = data[p+3] as f64;
                    let hour = data[p+4] as f64;
                    let min = data[p+5] as f64;
                    let sec = data[p+6] as f64;
                    let us = u32::from_le_bytes([data[p+8], data[p+9], data[p+10], data[p+11]]) as f64 / 1_000_000.0;

                    let total_sec = year * 31_536_000.0 + mon * 2_592_000.0 + day * 86_400.0 + hour * 3600.0 + min * 60.0 + sec + us;
                    start_times.push(total_sec);
                    p += 12;
                }
            }
            _ => {}
        }

        pos += size;
    }
}

fn map_remlogic_label(raw: &str) -> String {
    let s = raw.to_uppercase();
    if s.contains("SLEEP-S0") || s.contains("WAKE") || s.contains("WAK") || s.ends_with("-W") {
        "W".into()
    } else if s.contains("SLEEP-S1") || s.contains("NONREM1") || s.contains("N1") {
        "N1".into()
    } else if s.contains("SLEEP-S2") || s.contains("NONREM2") || s.contains("N2") {
        "N2".into()
    } else if s.contains("SLEEP-S3") || s.contains("SLEEP-S4") || s.contains("NONREM3") || s.contains("N3") {
        "N3".into()
    } else if s.contains("SLEEP-REM") || s.contains("REM") {
        "R".into()
    } else {
        "?".into()
    }
}

#[no_mangle]
pub extern "C" fn sleep_eeg_load_esedb_json(path: *const c_char) -> *mut c_char {
    if path.is_null() { return std::ptr::null_mut(); }
    let path_str = unsafe { CStr::from_ptr(path) };
    let Ok(path_str) = path_str.to_str() else { return std::ptr::null_mut(); };

    match parse_esedb_file(Path::new(path_str)) {
        Ok(records) => {
            if let Ok(json) = serde_json::to_string(&records) {
                if let Ok(c_str) = CString::new(json) {
                    return c_str.into_raw();
                }
            }
            std::ptr::null_mut()
        }
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn sleep_eeg_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}
