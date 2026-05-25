use std::ffi::CStr;
use std::f32::consts::PI;
use std::os::raw::c_char;
use std::path::Path;
use std::ptr;

mod morlet;

#[repr(C)]
pub struct SleepEegPoint {
    pub x: f32,
    pub y: f32,
    pub channel: i32,
}

#[repr(C)]
pub struct SleepEegViewport {
    pub sample_rate_hz: f32,
    pub epoch_seconds: i32,
    pub channel_count: i32,
    pub point_count: i32,
    pub points: *mut SleepEegPoint,
}

#[no_mangle]
pub extern "C" fn sleep_eeg_load_viewport(path: *const c_char) -> *mut SleepEegViewport {
    if path.is_null() {
        return ptr::null_mut();
    }

    let path = unsafe { CStr::from_ptr(path) };
    let Ok(path) = path.to_str() else {
        return ptr::null_mut();
    };

    match load_viewport(Path::new(path)) {
        Ok(viewport) => Box::into_raw(Box::new(viewport)),
        Err(_) => Box::into_raw(Box::new(demo_viewport())),
    }
}

#[no_mangle]
pub extern "C" fn sleep_eeg_free_viewport(viewport: *mut SleepEegViewport) {
    if viewport.is_null() {
        return;
    }

    unsafe {
        let viewport = Box::from_raw(viewport);
        if !viewport.points.is_null() && viewport.point_count > 0 {
            let _ = Vec::from_raw_parts(
                viewport.points,
                viewport.point_count as usize,
                viewport.point_count as usize,
            );
        }
    }
}

fn load_viewport(path: &Path) -> Result<SleepEegViewport, String> {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some(extension) if extension.eq_ignore_ascii_case("edf") => load_edf_viewport(path),
        Some(extension) if extension.eq_ignore_ascii_case("mat") => load_mat_viewport(path),
        _ => Err(format!("unsupported EEG file: {}", path.display())),
    }
}

fn load_edf_viewport(_path: &Path) -> Result<SleepEegViewport, String> {
    // Next porting step: map EDF signal headers and samples into channel-major f32 arrays.
    // The crate dependency is in place, but the exact EDF channel conventions from
    // ScoringHero should be mirrored before enabling this loader.
    Err("EDF parsing is not implemented yet".to_string())
}

fn load_mat_viewport(_path: &Path) -> Result<SleepEegViewport, String> {
    // Next porting step: support EEGLAB v7 and v7.3 shapes currently handled by
    // ScoringHero-0.2.4/eeg/load_eeglab.py.
    Err("MAT parsing is not implemented yet".to_string())
}

fn demo_viewport() -> SleepEegViewport {
    let channel_count = 5;
    let samples_per_channel = 1800;
    let mut points = Vec::with_capacity(channel_count * samples_per_channel);

    for channel in 0..channel_count {
        let baseline = (channel as f32 + 0.5) / channel_count as f32;
        let frequency = 2.0 + channel as f32 * 0.8;
        for sample in 0..samples_per_channel {
            let t = sample as f32 / (samples_per_channel - 1) as f32;
            let slow_wave = (t * PI * 2.0 * frequency).sin();
            let spindle = (t * PI * 2.0 * 13.5).sin() * 0.18;
            let drift = (t * PI * 2.0 * 0.18 + channel as f32).sin() * 0.08;
            points.push(SleepEegPoint {
                x: t,
                y: baseline + (slow_wave * 0.10 + spindle + drift) / channel_count as f32,
                channel: channel as i32,
            });
        }
    }

    let point_count = points.len() as i32;
    let points = points.leak().as_mut_ptr();

    SleepEegViewport {
        sample_rate_hz: 256.0,
        epoch_seconds: 30,
        channel_count: channel_count as i32,
        point_count,
        points,
    }
}

#[repr(C)]
pub struct SleepEegMorletResult {
    pub power: *mut f32,
    pub power_len: i32,
    pub n_freqs: i32,
    pub n_samples: i32,
}

#[no_mangle]
pub extern "C" fn sleep_eeg_compute_morlet_tf(
    signal: *const f32,
    n_samples: i32,
    srate: f32,
    freqs: *const f32,
    n_freqs: i32,
    l2_normalize: bool,
) -> *mut SleepEegMorletResult {
    if signal.is_null() || freqs.is_null() || n_samples <= 0 || n_freqs <= 0 {
        return ptr::null_mut();
    }

    let signal_slice = unsafe { std::slice::from_raw_parts(signal, n_samples as usize) };
    let freqs_slice = unsafe { std::slice::from_raw_parts(freqs, n_freqs as usize) };

    let mut power_vec = morlet::compute_morlet_tf(signal_slice, srate, freqs_slice, l2_normalize);

    let result = Box::new(SleepEegMorletResult {
        power_len: power_vec.len() as i32,
        n_freqs,
        n_samples,
        power: power_vec.leak().as_mut_ptr(),
    });

    Box::into_raw(result)
}

#[no_mangle]
pub extern "C" fn sleep_eeg_free_morlet_tf(result: *mut SleepEegMorletResult) {
    if result.is_null() {
        return;
    }

    unsafe {
        let result_box = Box::from_raw(result);
        if !result_box.power.is_null() && result_box.power_len > 0 {
            let _ = Vec::from_raw_parts(
                result_box.power,
                result_box.power_len as usize,
                result_box.power_len as usize,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn demo_viewport_has_channel_major_points() {
        let viewport = demo_viewport();
        assert_eq!(viewport.channel_count, 5);
        assert_eq!(viewport.point_count, 9000);
        assert!(!viewport.points.is_null());

        unsafe {
            let points = Vec::from_raw_parts(
                viewport.points,
                viewport.point_count as usize,
                viewport.point_count as usize,
            );
            assert_eq!(points[0].channel, 0);
            assert_eq!(points[1800].channel, 1);
        }
    }
}
