// lib/src/signal_processing.dart
//
// Pure-Dart port of the ScoringHero-0.2.4 signal_processing/ package.
// Provides: Welch spectrogram, SWA, per-epoch periodogram, Morlet TF, median filter.
// No external FFT dependency — uses a built-in Cooley-Tukey radix-2 FFT.

import 'dart:math' as math;
import 'dart:typed_data';

// ─────────────────────────────────────────────────────────────────────────────
// 1.  LOW-LEVEL FFT  (in-place, power-of-2 only)
// ─────────────────────────────────────────────────────────────────────────────

/// In-place radix-2 Cooley-Tukey FFT.
/// [re] and [im] must have the same length, which must be a power of 2.
void _fft(Float64List re, Float64List im) {
  final n = re.length;
  assert(n & (n - 1) == 0, 'FFT length must be a power of 2');

  // Bit-reversal permutation
  var j = 0;
  for (var i = 1; i < n; i++) {
    var bit = n >> 1;
    while (j & bit != 0) {
      j ^= bit;
      bit >>= 1;
    }
    j ^= bit;
    if (i < j) {
      var t = re[i]; re[i] = re[j]; re[j] = t;
      t = im[i]; im[i] = im[j]; im[j] = t;
    }
  }

  // Butterfly stages
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2.0 * math.pi / len;
    final wRe = math.cos(ang);
    final wIm = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      double curRe = 1.0, curIm = 0.0;
      final half = len >> 1;
      for (var k = 0; k < half; k++) {
        final uRe = re[i + k], uIm = im[i + k];
        final vRe = re[i + k + half] * curRe - im[i + k + half] * curIm;
        final vIm = re[i + k + half] * curIm + im[i + k + half] * curRe;
        re[i + k] = uRe + vRe;
        im[i + k] = uIm + vIm;
        re[i + k + half] = uRe - vRe;
        im[i + k + half] = uIm - vIm;
        final nRe = curRe * wRe - curIm * wIm;
        curIm = curRe * wIm + curIm * wRe;
        curRe = nRe;
      }
    }
  }
}

/// Inverse FFT (uses the same butterfly with +angle, then scales by 1/N).
void _ifft(Float64List re, Float64List im) {
  final n = re.length;
  // Conjugate → forward FFT → conjugate → scale
  for (var i = 0; i < n; i++) im[i] = -im[i];
  _fft(re, im);
  for (var i = 0; i < n; i++) {
    re[i] /= n;
    im[i] = -im[i] / n;
  }
}

int _nextPow2(int v) {
  var p = 1;
  while (p < v) p <<= 1;
  return p;
}

// ─────────────────────────────────────────────────────────────────────────────
// 2.  HANN WINDOW  &  WELCH PSD
// ─────────────────────────────────────────────────────────────────────────────

Float64List _hannWindow(int n) {
  final w = Float64List(n);
  for (var i = 0; i < n; i++) {
    w[i] = 0.5 * (1.0 - math.cos(2.0 * math.pi * i / (n - 1)));
  }
  return w;
}

/// One-sided Welch power spectral density estimate, matching scipy's defaults.
///
/// [signal]   : raw EEG samples (already sliced to the epoch + extension window)
/// [srate]    : sampling rate in Hz
/// [winlenSec]: window length in seconds (default 4s, matching Python)
/// [stepSec]  : step between windows in seconds (default 2s)
///
/// Returns (psd, freqs):
///   psd   – List<double> length nfft/2+1, units µV²/Hz
///   freqs – List<double> length nfft/2+1, units Hz
(List<double>, List<double>) welchPsd(
  List<double> signal,
  double srate, {
  double winlenSec = 4.0,
  double stepSec = 2.0,
}) {
  final winSamples = (winlenSec * srate).round();
  final stepSamples = (stepSec * srate).round();
  final nfft = _nextPow2(winSamples);
  final nfreqs = nfft ~/ 2 + 1;

  final window = _hannWindow(winSamples);
  // window normalization factor: sum(w²) for density scaling
  double winNorm = 0.0;
  for (final w in window) winNorm += w * w;

  final psd = Float64List(nfreqs);
  var nWindows = 0;

  for (var start = 0; start + winSamples <= signal.length; start += stepSamples) {
    final re = Float64List(nfft);
    final im = Float64List(nfft);
    for (var i = 0; i < winSamples; i++) {
      re[i] = signal[start + i] * window[i];
    }
    _fft(re, im);

    // Accumulate |FFT|²
    psd[0] += re[0] * re[0] + im[0] * im[0];
    for (var i = 1; i < nfreqs - 1; i++) {
      psd[i] += 2.0 * (re[i] * re[i] + im[i] * im[i]); // ×2 for one-sided
    }
    psd[nfreqs - 1] += re[nfreqs - 1] * re[nfreqs - 1] + im[nfreqs - 1] * im[nfreqs - 1];
    nWindows++;
  }

  if (nWindows == 0) {
    return (List.filled(nfreqs, 0.0), linspaceList(0.0, srate / 2.0, nfreqs));
  }

  final scale = 1.0 / (nWindows.toDouble() * srate * winNorm);
  final freqs = <double>[];
  final psdOut = <double>[];
  for (var i = 0; i < nfreqs; i++) {
    freqs.add(i * srate / nfft);
    psdOut.add(psd[i] * scale);
  }
  return (psdOut, freqs);
}

List<double> linspaceList(double start, double stop, int num) {
  if (num == 1) return [start];
  final result = <double>[];
  for (var i = 0; i < num; i++) {
    result.add(start + (stop - start) * i / (num - 1));
  }
  return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// 3.  FULL-NIGHT SPECTROGRAM  (one Welch PSD per epoch)
// ─────────────────────────────────────────────────────────────────────────────

/// Compute the whole-night Welch spectrogram for [channelSamples[channel]].
///
/// Returns ({power: List<List<double>>, freqs: List<double>}) where:
///   power[epoch][freq] = PSD in µV²/Hz
///
/// Extension: 1 second on each side of the epoch is included in the window,
/// matching the Python extension_epoch_s = [1, 1] default.
({List<List<double>> power, List<double> freqs}) computeSpectrogram(
  List<List<double>> channelSamples,
  double srate,
  int epochSeconds,
  int channelIndex,
) {
  if (channelSamples.isEmpty || channelIndex >= channelSamples.length) {
    return (power: [], freqs: []);
  }
  final signal = channelSamples[channelIndex];
  final totalSamples = signal.length;
  final epochSamples = (epochSeconds * srate).round();
  final extensionSamples = srate.round(); // 1 second extension each side
  final nEpochs = (totalSamples / epochSamples).ceil();

  final allPower = <List<double>>[];
  List<double>? freqs;

  for (var epoch = 0; epoch < nEpochs; epoch++) {
    final start = math.max(0, epoch * epochSamples - extensionSamples);
    final end = math.min(totalSamples, (epoch + 1) * epochSamples + extensionSamples);
    final slice = signal.sublist(start, end);
    final (psd, f) = welchPsd(slice, srate);
    freqs ??= f;
    allPower.add(psd);
  }

  return (power: allPower, freqs: freqs ?? []);
}

// ─────────────────────────────────────────────────────────────────────────────
// 4.  SWA  (Slow-Wave Activity, 0.5–4 Hz mean power)
// ─────────────────────────────────────────────────────────────────────────────

/// Per-epoch mean PSD in the 0.5–4 Hz band.
List<double> computeSwa(List<List<double>> power, List<double> freqs) {
  final mask = <int>[];
  for (var i = 0; i < freqs.length; i++) {
    if (freqs[i] >= 0.5 && freqs[i] <= 4.0) mask.add(i);
  }
  if (mask.isEmpty) return List.filled(power.length, 0.0);

  return [
    for (final row in power)
      () {
        double s = 0;
        for (final i in mask) s += row[i];
        return s / mask.length;
      }(),
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
// 5.  PER-EPOCH PERIODOGRAM  (pre-computed for all epochs)
// ─────────────────────────────────────────────────────────────────────────────

/// Pre-compute a single Welch PSD for every epoch of [channelSamples[channel]].
/// This is the data shown in the RectanglePower panel.
///
/// The display mode "1/f removed" is computed in the painter.
List<List<double>> precomputeEpochPeriodograms(
  List<List<double>> channelSamples,
  double srate,
  int epochSeconds,
  int channelIndex,
) {
  if (channelSamples.isEmpty || channelIndex >= channelSamples.length) return [];
  final signal = channelSamples[channelIndex];
  final epochSamples = (epochSeconds * srate).round();
  final nEpochs = (signal.length / epochSamples).ceil();
  final result = <List<double>>[];
  for (var epoch = 0; epoch < nEpochs; epoch++) {
    final start = epoch * epochSamples;
    final end = math.min(signal.length, start + epochSamples);
    final (psd, _) = welchPsd(signal.sublist(start, end), srate);
    result.add(psd);
  }
  return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// 6.  TF NORMALISATION STATS  (night-wide median + IQR per frequency)
// ─────────────────────────────────────────────────────────────────────────────

/// Compute robust z-score normalisation parameters from the full-night spectrogram.
/// Returns ({median, iqr}) each of length [freqs.length].
({List<double> median, List<double> iqr}) computeTfNormStats(
  List<List<double>> power,
  List<double> spectrogramFreqs,
  List<double> tfFreqs,
) {
  if (power.isEmpty || spectrogramFreqs.isEmpty) {
    return (
      median: List.filled(tfFreqs.length, 0.0),
      iqr: List.filled(tfFreqs.length, 1.0),
    );
  }

  final nFreqs = spectrogramFreqs.length;
  final nEpochs = power.length;

  // log10 power per frequency column
  final logPowerByFreq = List.generate(nFreqs, (_) => <double>[]);
  for (var e = 0; e < nEpochs; e++) {
    for (var f = 0; f < nFreqs; f++) {
      logPowerByFreq[f].add(math.log(math.max(power[e][f], 1e-30)) / math.ln10);
    }
  }

  // Median + IQR per spectrogram freq
  final medianSpec = Float64List(nFreqs);
  final iqrSpec = Float64List(nFreqs);
  for (var f = 0; f < nFreqs; f++) {
    final col = logPowerByFreq[f]..sort();
    medianSpec[f] = _percentile(col, 50);
    iqrSpec[f] = math.max(1e-6, _percentile(col, 75) - _percentile(col, 25));
  }

  // Interpolate onto TF geomspace frequency grid
  final medianTf = <double>[];
  final iqrTf = <double>[];
  for (final freq in tfFreqs) {
    medianTf.add(_interp(freq, spectrogramFreqs, medianSpec));
    iqrTf.add(_interp(freq, spectrogramFreqs, iqrSpec));
  }
  return (median: medianTf, iqr: iqrTf);
}

double _percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0.0;
  final idx = (p / 100.0) * (sorted.length - 1);
  final lo = idx.floor();
  final hi = idx.ceil();
  if (lo == hi) return sorted[lo];
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
}

double _interp(double x, List<double> xs, List<double> ys) {
  if (xs.isEmpty) return 0.0;
  if (x <= xs.first) return ys.first;
  if (x >= xs.last) return ys.last;
  for (var i = 1; i < xs.length; i++) {
    if (x <= xs[i]) {
      final t = (x - xs[i - 1]) / (xs[i] - xs[i - 1]);
      return ys[i - 1] + t * (ys[i] - ys[i - 1]);
    }
  }
  return ys.last;
}

// ─────────────────────────────────────────────────────────────────────────────
// 7.  GEOMSPACE  (logarithmically spaced frequency grid for TF)
// ─────────────────────────────────────────────────────────────────────────────

List<double> geomspace(double start, double stop, int num) {
  if (num <= 1) return [start];
  final logStart = math.log(start);
  final logStop = math.log(stop);
  return [
    for (var i = 0; i < num; i++)
      math.exp(logStart + (logStop - logStart) * i / (num - 1)),
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
// 8.  MORLET TIME-FREQUENCY  (FFT-based, per epoch)
// ─────────────────────────────────────────────────────────────────────────────

/// FFT-based complex Morlet wavelet TF power.
///
/// Port of compute_morlet_tf.py.
/// [signal]  : 1-D EEG for the extended epoch (30s + 1s each side)
/// [srate]   : sampling rate in Hz
/// [freqs]   : centre frequencies (e.g. geomspace 0.25–45 Hz, 120 points)
///
/// Returns power[freqIndex][timeIndex] — shape (nFreqs × nSamples)
List<List<double>> computeMorletTf(
  List<double> signal,
  double srate,
  List<double> freqs,
) {
  final nSamples = signal.length;
  final nfft = _nextPow2(nSamples);

  // Remove DC offset
  double mean = 0.0;
  for (final s in signal) mean += s;
  mean /= nSamples;

  // Compute FFT of the zero-mean signal
  final sigRe = Float64List(nfft);
  final sigIm = Float64List(nfft);
  for (var i = 0; i < nSamples; i++) sigRe[i] = signal[i] - mean;
  _fft(sigRe, sigIm);

  // FFT frequency bins
  final fftFreqs = Float64List(nfft);
  for (var i = 0; i < nfft; i++) {
    fftFreqs[i] = i < nfft ~/ 2 ? i * srate / nfft : (i - nfft) * srate / nfft;
  }

  final power = <List<double>>[];

  for (final freq in freqs) {
    // Number of cycles: max(3, freq/2)
    final nCycles = math.max(3.0, freq / 2.0);
    final sigmaF = freq / nCycles;

    // Gaussian in frequency domain centred at freq
    final waveRe = Float64List(nfft);
    for (var i = 0; i < nfft; i++) {
      final df = fftFreqs[i] - freq;
      waveRe[i] = math.exp(-0.5 * (df / sigmaF) * (df / sigmaF));
    }
    // Imaginary part of Gaussian is zero (real-valued in frequency domain)

    // Multiply signal FFT × wavelet
    final convRe = Float64List(nfft);
    final convIm = Float64List(nfft);
    for (var i = 0; i < nfft; i++) {
      convRe[i] = sigRe[i] * waveRe[i];
      convIm[i] = sigIm[i] * waveRe[i];
    }

    // IFFT → analytic signal
    _ifft(convRe, convIm);

    // Instantaneous power (|analytic|²), trimmed to original signal length
    final rowPower = List<double>.generate(
      nSamples,
      (i) => convRe[i] * convRe[i] + convIm[i] * convIm[i],
    );
    power.add(rowPower);
  }

  return power;
}

// ─────────────────────────────────────────────────────────────────────────────
// 9.  MEDIAN FILTER  (for SWA smoothing in hypnogram)
// ─────────────────────────────────────────────────────────────────────────────

/// Running median filter with [kernelSize] (must be odd).
List<double> medianFilter(List<double> data, int kernelSize) {
  if (kernelSize <= 1 || data.isEmpty) return List.from(data);
  final k = kernelSize % 2 == 0 ? kernelSize + 1 : kernelSize;
  final half = k ~/ 2;
  final result = List<double>.filled(data.length, 0.0);
  for (var i = 0; i < data.length; i++) {
    final start = math.max(0, i - half);
    final end = math.min(data.length - 1, i + half);
    final window = data.sublist(start, end + 1).toList()..sort();
    result[i] = window[window.length ~/ 2];
  }
  return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// 10. SWA DISPLAY SCALING  (normalised to fit hypnogram y-range)
// ─────────────────────────────────────────────────────────────────────────────

/// Scale SWA to fit the hypnogram y-range [-4, 1] after optional median filtering.
/// [kernelSize] controls smoothing (1 = none, 101 = maximum).
List<double> scaleSwaForDisplay(List<double> swa, {int kernelSize = 1}) {
  var smoothed = medianFilter(swa, kernelSize);

  // Handle NaN/Inf
  smoothed = smoothed.map((v) => v.isFinite ? v : 0.0).toList();

  final minVal = smoothed.reduce(math.min);
  final maxVal = smoothed.reduce(math.max);
  final range = maxVal - minVal;
  if (range < 1e-10) return List.filled(swa.length, -1.5);

  return smoothed.map((v) => 5.0 * (v - minVal) / range - 4.0).toList();
}

// ─────────────────────────────────────────────────────────────────────────────
// 11. Z-SCORE TF POWER  (for display)
// ─────────────────────────────────────────────────────────────────────────────

/// Apply robust z-score normalisation to Morlet power.
/// [power] : List<List<double>> shape (nFreqs × nSamples) — log10 power
/// [median] : per-frequency night-wide median of log10 power
/// [iqr]   : per-frequency night-wide IQR of log10 power
List<List<double>> zScoreTfPower(
  List<List<double>> power,
  List<double> median,
  List<double> iqr,
) {
  final result = <List<double>>[];
  for (var f = 0; f < power.length; f++) {
    final med = f < median.length ? median[f] : 0.0;
    final iq = f < iqr.length ? math.max(iqr[f], 1e-6) : 1.0;
    result.add([
      for (final v in power[f]) (v - med) / iq,
    ]);
  }
  return result;
}

/// Apply log10 transform to raw Morlet power array.
List<List<double>> log10TfPower(List<List<double>> power) {
  return [
    for (final row in power)
      [for (final v in row) math.log(math.max(v, 1e-30)) / math.ln10],
  ];
}
