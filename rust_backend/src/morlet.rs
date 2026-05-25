use rustfft::{FftPlanner, num_complex::Complex};
use rayon::prelude::*;

pub fn compute_morlet_tf(
    signal: &[f32],
    srate: f32,
    freqs: &[f32],
    l2_normalize: bool,
) -> Vec<f32> {
    let n_samples = signal.len();
    if n_samples == 0 || freqs.is_empty() {
        return Vec::new();
    }

    // 1. Remove DC offset
    let mean = signal.iter().sum::<f32>() / n_samples as f32;
    let mut signal_complex: Vec<Complex<f32>> = signal
        .iter()
        .map(|&x| Complex::new(x - mean, 0.0))
        .collect();

    // 2. Forward FFT of the signal
    let mut planner = FftPlanner::new();
    let fft = planner.plan_fft_forward(n_samples);
    fft.process(&mut signal_complex);

    let mut power = vec![0.0; freqs.len() * n_samples];

    // Compute FFT frequencies
    let mut fft_freqs = vec![0.0; n_samples];
    for i in 0..n_samples {
        let f = if i <= n_samples / 2 {
            i as f32
        } else {
            (i as i32 - n_samples as i32) as f32
        };
        fft_freqs[i] = f * srate / n_samples as f32;
    }

    // 3. Process each frequency in parallel using rayon
    power
        .par_chunks_mut(n_samples)
        .enumerate()
        .for_each(|(freq_idx, row)| {
            let freq = freqs[freq_idx];
            let n_cycles = f32::max(3.0, freq / 2.0);
            let sigma_f = freq / n_cycles;

            let mut wavelet_fft = vec![0.0; n_samples];
            let mut sum_sq = 0.0;

            for i in 0..n_samples {
                let f = fft_freqs[i];
                let val = f32::exp(-0.5 * f32::powi((f - freq) / sigma_f, 2));
                wavelet_fft[i] = val;
                sum_sq += val * val;
            }

            let norm_factor = if l2_normalize {
                1.0 / f32::sqrt(sum_sq)
            } else {
                1.0
            };

            let mut analytic: Vec<Complex<f32>> = signal_complex
                .iter()
                .zip(wavelet_fft.iter())
                .map(|(s, w)| s * Complex::new(w * norm_factor, 0.0))
                .collect();

            // Inverse FFT
            let mut planner = FftPlanner::new();
            let ifft = planner.plan_fft_inverse(n_samples);
            ifft.process(&mut analytic);

            // Calculate power (squared magnitude), scale down by 1/N due to unnormalized rustfft IFFT
            let inv_n = 1.0 / n_samples as f32;
            for i in 0..n_samples {
                let scaled = analytic[i] * inv_n;
                row[i] = scaled.norm_sqr();
            }
        });

    power
}
