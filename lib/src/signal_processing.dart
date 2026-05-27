// lib/src/signal_processing.dart
//
// Pure-Dart port of the ScoringHero-0.2.4 signal_processing/ package.
// Provides: Welch spectrogram, SWA, per-epoch periodogram, Morlet TF, median filter.
// No external FFT dependency — uses a built-in Cooley-Tukey radix-2 FFT.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

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
  var winSamples = (winlenSec * srate).round();
  var stepSamples = (stepSec * srate).round();
  if (winSamples > signal.length) {
    winSamples = signal.length;
    stepSamples = winSamples ~/ 2;
  }
  if (winSamples < 4) {
    winSamples = 4;
    stepSamples = 2;
  }
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

// ─────────────────────────────────────────────────────────────────────────────
// 12. COLORMAPS FOR IMAGE GENERATION
// ─────────────────────────────────────────────────────────────────────────────

final List<ui.Color> cividis = _buildCividis();

List<ui.Color> _buildCividis() {
  const stops = <List<int>>[
    [0, 0, 32, 81],
    [32, 0, 62, 116],
    [64, 49, 91, 118],
    [96, 80, 112, 120],
    [128, 110, 133, 120],
    [160, 141, 155, 116],
    [192, 175, 179, 107],
    [224, 212, 206, 90],
    [255, 253, 231, 37],
  ];
  final out = <ui.Color>[];
  for (var i = 0; i < 256; i++) {
    int seg = 0;
    for (var s = stops.length - 1; s >= 0; s--) {
      if (i >= stops[s][0]) {
        seg = s;
        break;
      }
    }
    if (seg >= stops.length - 1) {
      out.add(ui.Color.fromARGB(255, stops.last[1], stops.last[2], stops.last[3]));
      continue;
    }
    final lo = stops[seg], hi = stops[seg + 1];
    final t = (i - lo[0]) / (hi[0] - lo[0]);
    final r = (lo[1] + t * (hi[1] - lo[1])).round().clamp(0, 255);
    final g = (lo[2] + t * (hi[2] - lo[2])).round().clamp(0, 255);
    final b = (lo[3] + t * (hi[3] - lo[3])).round().clamp(0, 255);
    out.add(ui.Color.fromARGB(255, r, g, b));
  }
  return out;
}

ui.Color cividisColor(double t) {
  final idx = (t.clamp(0.0, 1.0) * 255).round();
  return cividis[idx];
}

final List<ui.Color> spectral = _buildSpectral();

List<ui.Color> _buildSpectral() {
  const stops = <List<int>>[
    [0, 94, 79, 162],
    [51, 50, 136, 189],
    [102, 102, 194, 165],
    [128, 171, 221, 164],
    [153, 230, 245, 152],
    [178, 254, 254, 189],
    [204, 253, 174, 97],
    [229, 244, 109, 67],
    [255, 158, 1, 66],
  ];
  final out = <ui.Color>[];
  for (var i = 0; i < 256; i++) {
    int seg = 0;
    for (var s = stops.length - 1; s >= 0; s--) {
      if (i >= stops[s][0]) {
        seg = s;
        break;
      }
    }
    if (seg >= stops.length - 1) {
      out.add(ui.Color.fromARGB(255, stops.last[1], stops.last[2], stops.last[3]));
      continue;
    }
    final lo = stops[seg], hi = stops[seg + 1];
    final t = (i - lo[0]) / (hi[0] - lo[0]);
    final r = (lo[1] + t * (hi[1] - lo[1])).round().clamp(0, 255);
    final g = (lo[2] + t * (hi[2] - lo[2])).round().clamp(0, 255);
    final b = (lo[3] + t * (hi[3] - lo[3])).round().clamp(0, 255);
    out.add(ui.Color.fromARGB(255, r, g, b));
  }
  return out;
}

ui.Color spectralColor(double t) {
  final idx = (t.clamp(0.0, 1.0) * 255).round();
  return spectral[idx];
}

// ─────────────────────────────────────────────────────────────────────────────
// 13. BANDPASS FILTERING (BIQUAD BASED)
// ─────────────────────────────────────────────────────────────────────────────

List<double> applyRepeatedZeroPhaseBiquad(
  List<double> input,
  ({double b0, double b1, double b2, double a1, double a2}) coeff,
  int order,
) {
  var output = input;
  final sections = math.max(1, (order / 2).round());
  for (var i = 0; i < sections; i++) {
    output = applyBiquad(output, coeff);
    output = applyBiquad(
      output.reversed.toList(growable: false),
      coeff,
    ).reversed.toList(growable: false);
  }
  return output;
}

List<double> applyBiquad(
  List<double> input,
  ({double b0, double b1, double b2, double a1, double a2}) c,
) {
  final out = List<double>.filled(input.length, 0.0, growable: false);
  double x1 = input.first;
  double x2 = input.first;
  double y1 = input.first;
  double y2 = input.first;
  for (var i = 0; i < input.length; i++) {
    final x0 = input[i];
    final y0 = c.b0 * x0 + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2;
    out[i] = y0;
    x2 = x1;
    x1 = x0;
    y2 = y1;
    y1 = y0;
  }
  return out;
}

({double b0, double b1, double b2, double a1, double a2}) biquadLowPass(
  double cutoff,
  double sampleRate,
) {
  final w0 = 2.0 * math.pi * cutoff / sampleRate;
  final cosW0 = math.cos(w0);
  final alpha = math.sin(w0) / (2.0 * math.sqrt1_2);
  var b0 = (1.0 - cosW0) / 2.0;
  var b1 = 1.0 - cosW0;
  var b2 = (1.0 - cosW0) / 2.0;
  final a0 = 1.0 + alpha;
  var a1 = -2.0 * cosW0;
  var a2 = 1.0 - alpha;
  b0 /= a0;
  b1 /= a0;
  b2 /= a0;
  a1 /= a0;
  a2 /= a0;
  return (b0: b0, b1: b1, b2: b2, a1: a1, a2: a2);
}

({double b0, double b1, double b2, double a1, double a2}) biquadHighPass(
  double cutoff,
  double sampleRate,
) {
  final w0 = 2.0 * math.pi * cutoff / sampleRate;
  final cosW0 = math.cos(w0);
  final alpha = math.sin(w0) / (2.0 * math.sqrt1_2);
  var b0 = (1.0 + cosW0) / 2.0;
  var b1 = -(1.0 + cosW0);
  var b2 = (1.0 + cosW0) / 2.0;
  final a0 = 1.0 + alpha;
  var a1 = -2.0 * cosW0;
  var a2 = 1.0 - alpha;
  b0 /= a0;
  b1 /= a0;
  b2 /= a0;
  a1 /= a0;
  a2 /= a0;
  return (b0: b0, b1: b1, b2: b2, a1: a1, a2: a2);
}

List<double> bandpassFilter(
  List<double> signal,
  double sampleRate, {
  double low = 0.3,
  double high = 35.0,
  int order = 4,
}) {
  if (signal.length < 8 || sampleRate <= 0) return List.from(signal);
  var result = List<double>.from(signal);
  final nyquist = sampleRate / 2.0;
  if (low > 0 && low < nyquist) {
    result = applyRepeatedZeroPhaseBiquad(
      result,
      biquadHighPass(low, sampleRate),
      order,
    );
  }
  if (high > 0 && high < nyquist) {
    result = applyRepeatedZeroPhaseBiquad(
      result,
      biquadLowPass(high, sampleRate),
      order,
    );
  }
  return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// 14. HILBERT ENVELOPE
// ─────────────────────────────────────────────────────────────────────────────

Float64List hilbertEnvelope(List<double> x) {
  final n = x.length;
  final nfft = _nextPow2(n);

  final re = Float64List(nfft);
  final im = Float64List(nfft);
  for (var i = 0; i < n; i++) {
    re[i] = x[i];
  }

  _fft(re, im);

  final half = nfft ~/ 2;
  for (var i = 1; i < half; i++) {
    re[i] *= 2.0;
    im[i] *= 2.0;
  }
  for (var i = half + 1; i < nfft; i++) {
    re[i] = 0.0;
    im[i] = 0.0;
  }

  _ifft(re, im);

  final envelope = Float64List(n);
  for (var i = 0; i < n; i++) {
    envelope[i] = math.sqrt(re[i] * re[i] + im[i] * im[i]);
  }
  return envelope;
}

// ─────────────────────────────────────────────────────────────────────────────
// 15. DPSS AND MULTITAPER SPECTROGRAM
// ─────────────────────────────────────────────────────────────────────────────

int countEigenvaluesLessThan(double lambda, Float64List d, Float64List e) {
  int count = 0;
  double q = d[0] - lambda;
  if (q < 0) count++;
  for (var i = 1; i < d.length; i++) {
    if (q == 0.0) q = 1e-12;
    q = (d[i] - lambda) - e[i - 1] * e[i - 1] / q;
    if (q < 0) count++;
  }
  return count;
}

double findEigenvalue(
  int targetCount,
  Float64List d,
  Float64List e,
  double low,
  double high,
) {
  double left = low;
  double right = high;
  for (var iter = 0; iter < 64; iter++) {
    final mid = 0.5 * (left + right);
    final count = countEigenvaluesLessThan(mid, d, e);
    if (count <= targetCount) {
      left = mid;
    } else {
      right = mid;
    }
  }
  return 0.5 * (left + right);
}

void solveTridiagonal(
  Float64List d,
  Float64List e,
  double lambda,
  Float64List x,
  Float64List y,
) {
  final n = d.length;
  final cp = Float64List(n);
  final dp = Float64List(n);

  double denom = d[0] - lambda;
  if (denom == 0.0) denom = 1e-12;
  cp[0] = e[0] / denom;
  dp[0] = x[0] / denom;

  for (var i = 1; i < n; i++) {
    final prevE = e[i - 1];
    denom = (d[i] - lambda) - prevE * cp[i - 1];
    if (denom == 0.0) denom = 1e-12;
    if (i < n - 1) {
      cp[i] = e[i] / denom;
    }
    dp[i] = (x[i] - prevE * dp[i - 1]) / denom;
  }

  y[n - 1] = dp[n - 1];
  for (var i = n - 2; i >= 0; i--) {
    y[i] = dp[i] - cp[i] * y[i + 1];
  }
}

Float64List getEigenvector(Float64List d, Float64List e, double lambda) {
  final n = d.length;
  var x = Float64List(n);
  for (var i = 0; i < n; i++) {
    x[i] = math.sin((i + 1) * math.pi / (n + 1));
  }

  final y = Float64List(n);
  for (var iter = 0; iter < 4; iter++) {
    solveTridiagonal(d, e, lambda, x, y);
    double norm = 0.0;
    for (var i = 0; i < n; i++) norm += y[i] * y[i];
    norm = math.sqrt(norm);
    if (norm < 1e-12) norm = 1e-12;
    for (var i = 0; i < n; i++) x[i] = y[i] / norm;
  }
  return x;
}

List<Float64List> dpss(int N, double NW, int K) {
  final d = Float64List(N);
  final e = Float64List(N - 1);
  final W = NW / N;
  final cos2piW = math.cos(2.0 * math.pi * W);
  for (var i = 0; i < N; i++) {
    final val = (N - 1.0) / 2.0 - i;
    d[i] = val * val * cos2piW;
  }
  for (var i = 0; i < N - 1; i++) {
    e[i] = 0.5 * (i + 1) * (N - 1 - i);
  }

  double minVal = d[0] - e[0].abs();
  double maxVal = d[0] + e[0].abs();
  for (var i = 1; i < N; i++) {
    final sumOff = (e[i - 1]).abs() + (i < N - 1 ? e[i].abs() : 0.0);
    if (d[i] - sumOff < minVal) minVal = d[i] - sumOff;
    if (d[i] + sumOff > maxVal) maxVal = d[i] + sumOff;
  }

  final tapers = <Float64List>[];
  for (var k = 0; k < K; k++) {
    final targetCount = N - 1 - k;
    final lambda = findEigenvalue(targetCount, d, e, minVal, maxVal);
    final v = getEigenvector(d, e, lambda);

    double sum = 0.0;
    for (var i = 0; i < N; i++) sum += v[i];
    if (sum < 0.0) {
      for (var i = 0; i < N; i++) v[i] = -v[i];
    }

    tapers.add(v);
  }
  return tapers;
}

List<List<double>> computeMultitaperSpectrogram(
  List<double> x,
  double sfreq,
  int L,
  int delta_j,
  double delta_f,
) {
  final N = x.length;
  final TW = (L * delta_f) / (2.0 * sfreq);
  int K = (2 * TW).toInt() - 1;
  if (K < 1) K = 1;

  final tapers = dpss(L, TW, K);
  final R = _nextPow2(L);
  final J = (N / delta_j).ceil();
  final half = R ~/ 2 + 1;

  final SG = List.generate(half, (_) => Float64List(J));

  // Pre-allocate structures to avoid allocations in loops
  final seg = Float64List(L);
  final re = Float64List(R);
  final im = Float64List(R);
  final SW = Float64List(half);

  final scale = 1.0 / (sfreq * K);
  final ln10 = math.ln10;

  for (var j = 0; j < J; j++) {
    final start = j * delta_j;
    final avail = math.min(L, N - start);
    
    seg.fillRange(0, L, 0.0);
    if (avail > 0) {
      for (var i = 0; i < avail; i++) {
        seg[i] = x[start + i];
      }
    }

    SW.fillRange(0, half, 0.0);

    for (var k = 0; k < K; k++) {
      final taper = tapers[k];
      
      re.fillRange(0, R, 0.0);
      im.fillRange(0, R, 0.0);
      for (var i = 0; i < L; i++) {
        re[i] = taper[i] * seg[i];
      }
      _fft(re, im);

      SW[0] += (re[0] * re[0] + im[0] * im[0]) * scale;
      for (var f = 1; f < half - 1; f++) {
        SW[f] += (re[f] * re[f] + im[f] * im[f]) * scale;
      }
      SW[half - 1] += (re[half - 1] * re[half - 1] + im[half - 1] * im[half - 1]) * scale;
    }

    for (var f = 0; f < half; f++) {
      SG[f][j] = 10.0 * math.log(SW[f] + 1.0) / ln10;
    }
  }

  return SG;
}

// ─────────────────────────────────────────────────────────────────────────────
// 16. MOVING AVERAGES & STATS
// ─────────────────────────────────────────────────────────────────────────────

Float64List _cma(Float64List x, int window) {
  final n = x.length;
  final out = Float64List(n);
  final w = math.max(1, window);
  final half = w ~/ 2;

  double currentSum = 0.0;
  for (var i = -half; i < -half + w; i++) {
    final idx = i.clamp(0, n - 1);
    currentSum += x[idx];
  }
  out[0] = currentSum / w;

  for (var i = 1; i < n; i++) {
    final oldIdx = (i - 1 - half).clamp(0, n - 1);
    final newIdx = (i - half + w - 1).clamp(0, n - 1);
    currentSum = currentSum - x[oldIdx] + x[newIdx];
    out[i] = currentSum / w;
  }
  return out;
}

Float64List _cmsd(Float64List x, int window) {
  final n = x.length;
  final xSq = Float64List(n);
  for (var i = 0; i < n; i++) {
    xSq[i] = x[i] * x[i];
  }
  final mean = _cma(x, window);
  final meanSq = _cma(xSq, window);
  final out = Float64List(n);
  for (var i = 0; i < n; i++) {
    out[i] = math.sqrt(math.max(0.0, meanSq[i] - mean[i] * mean[i]));
  }
  return out;
}

double percentile(Float64List values, double q) {
  if (values.isEmpty) return 0.0;
  final sorted = Float64List.fromList(values)..sort();
  final idx = (q / 100.0) * (sorted.length - 1);
  final lo = idx.floor();
  final hi = idx.ceil();
  if (lo == hi) return sorted[lo];
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
}

double ptp(Float64List x, int start, int end) {
  if (start >= end) return 0.0;
  double minVal = x[start];
  double maxVal = x[start];
  for (var i = start + 1; i <= end; i++) {
    final v = x[i];
    if (v < minVal) minVal = v;
    if (v > maxVal) maxVal = v;
  }
  return maxVal - minVal;
}

// ─────────────────────────────────────────────────────────────────────────────
// 17. EVENT DETECTORS (MT-KCD and MT-Spindle)
// ─────────────────────────────────────────────────────────────────────────────

List<(double, double)> detectKComplex(
  List<double> signal,
  double sfreq, {
  double amin = 125.0,
  double dmax_s = 2.0,
  double q = 90.0,
  double fmax = 3.0,
}) {
  final N = signal.length;
  if (N < 8 || sfreq <= 0) return const [];

  final L = math.max(2, sfreq.round());
  final delta_j = math.max(1, (0.05 * sfreq).round());
  final delta_f = 4.0;
  final Ishort = math.max(1, (0.5 * sfreq / delta_j).round());
  final Ibackg = 10 * Ishort;
  final Lsmth = math.max(1, (0.15 * sfreq).round());
  final Lbackg = delta_j * Ibackg;
  final Dmax = (dmax_s * sfreq).round();

  // 1. Bandpass filter 0.3 - 35 Hz
  final xBP = Float64List.fromList(
    bandpassFilter(signal, sfreq, low: 0.3, high: 35.0, order: 4),
  );

  // 2. Multitaper spectrogram
  final SG = computeMultitaperSpectrogram(xBP, sfreq, L, delta_j, delta_f);
  final J = SG[0].length;
  final R = _nextPow2(L);

  // 3. Sum delta-band power
  final freqs = List<double>.generate(SG.length, (i) => i * sfreq / R);
  final deltaMask = <int>[];
  for (var i = 0; i < freqs.length; i++) {
    if (freqs[i] <= fmax) deltaMask.add(i);
  }
  if (deltaMask.isEmpty) return const [];

  final C = Float64List(J);
  for (var j = 0; j < J; j++) {
    double sum = 0.0;
    for (final f in deltaMask) {
      sum += SG[f][j];
    }
    C[j] = sum;
  }

  // Short vs background averages
  final Cshort = _cma(C, Ishort);
  final Cbackg = _cma(C, Ibackg);
  final Cdiff = Float64List(J);
  for (var j = 0; j < J; j++) {
    Cdiff[j] = Cshort[j] - Cbackg[j];
  }

  final thresh = percentile(Cdiff, q);
  final regions = <(int, int)>[];
  var inRegion = false;
  var j1 = 0;
  for (var j = 0; j < J; j++) {
    final above = Cdiff[j] >= thresh;
    if (above && !inRegion) {
      j1 = j;
      inRegion = true;
    } else if (!above && inRegion) {
      regions.add((j1, j - 1));
      inRegion = false;
    }
  }
  if (inRegion) {
    regions.add((j1, J - 1));
  }

  if (regions.isEmpty) return const [];

  // 4. Candidate KC marking
  final x_smth = _cma(xBP, Lsmth);
  final x_backg = _cma(xBP, Lbackg);
  final sigma = _cmsd(xBP, Lbackg);

  final A_inf = Float64List(N);
  final A_sup = Float64List(N);
  for (var i = 0; i < N; i++) {
    A_inf[i] = x_backg[i] - sigma[i];
    A_sup[i] = x_backg[i] + sigma[i];
  }

  // Transition points: where x_smth >= x_backg at i but < at i+1
  final transitions = <int>[];
  for (var i = 0; i < N - 1; i++) {
    if (x_smth[i] >= x_backg[i] && x_smth[i + 1] < x_backg[i + 1]) {
      transitions.add(i);
    }
  }

  final KCcand = <(int, int)>[];
  for (var i = 0; i < transitions.length - 1; i++) {
    final n1 = transitions[i];
    final n2 = transitions[i + 1];

    var inCandRegion = false;
    for (final r in regions) {
      if (r.$1 * delta_j <= n1 && n1 <= r.$2 * delta_j) {
        inCandRegion = true;
        break;
      }
    }
    if (!inCandRegion) continue;

    var dipped = false;
    var risen = false;
    for (var idx = n1; idx <= n2; idx++) {
      if (x_smth[idx] <= A_inf[idx]) dipped = true;
      if (x_smth[idx] >= A_sup[idx]) risen = true;
    }
    if (dipped && risen) {
      KCcand.add((n1, n2));
    }
  }

  if (KCcand.isEmpty) return const [];

  // 5. Elimination
  final KCmax = <(int, int)>[];
  for (final r in regions) {
    final rStart = r.$1 * delta_j;
    final rEnd = r.$2 * delta_j;

    (int, int)? best;
    double bestPtp = -1.0;
    for (final cand in KCcand) {
      if (cand.$1 >= rStart && cand.$1 <= rEnd) {
        final val = ptp(xBP, cand.$1, cand.$2);
        if (val > bestPtp) {
          bestPtp = val;
          best = cand;
        }
      }
    }
    if (best != null) {
      KCmax.add(best);
    }
  }

  final events = <(double, double)>[];
  for (final cand in KCmax) {
    final val = ptp(xBP, cand.$1, cand.$2);
    final dur = cand.$2 - cand.$1;
    if (val >= amin && dur < Dmax) {
      events.add((cand.$1 / sfreq, cand.$2 / sfreq));
    }
  }
  return events;
}

List<(double, double)> detectSpindles(
  List<double> signal,
  double sfreq, {
  double fmin = 11.0,
  double fmax = 16.0,
  double amin = 10.0,
  double dmin_s = 0.5,
  double dmax_s = 2.0,
  double q = 95.0,
}) {
  final N = signal.length;
  if (N < 8 || sfreq <= 0) return const [];

  final L = math.max(2, sfreq.round());
  final delta_j = math.max(1, (0.05 * sfreq).round());
  final delta_f = 4.0;
  final Ishort = math.max(1, (0.5 * sfreq / delta_j).round());
  final Ibackg = 10 * Ishort;
  final Lsmth = math.max(1, (0.15 * sfreq).round());
  final Lbackg = delta_j * Ibackg;
  final Dmin = (dmin_s * sfreq).round();
  final Dmax = (dmax_s * sfreq).round();

  // 1. Broadband bandpass 0.3 - 35 Hz
  final xBroad = Float64List.fromList(
    bandpassFilter(signal, sfreq, low: 0.3, high: 35.0, order: 4),
  );

  // 2. Multitaper spectrogram
  final SG = computeMultitaperSpectrogram(xBroad, sfreq, L, delta_j, delta_f);
  final J = SG[0].length;
  final R = _nextPow2(L);

  // 3. Sum median-normalized sigma-band power
  final freqs = List<double>.generate(SG.length, (i) => i * sfreq / R);
  final sigmaMask = <int>[];
  for (var i = 0; i < freqs.length; i++) {
    if (freqs[i] >= fmin && freqs[i] <= fmax) sigmaMask.add(i);
  }
  if (sigmaMask.isEmpty) return const [];

  final SG_norm = List.generate(SG.length, (_) => Float64List(J));
  for (var f = 0; f < SG.length; f++) {
    final row = Float64List.fromList(SG[f]);
    final sorted = Float64List.fromList(row)..sort();
    final rowMedian = percentile(sorted, 50.0);
    for (var j = 0; j < J; j++) {
      SG_norm[f][j] = SG[f][j] - rowMedian;
    }
  }

  final C = Float64List(J);
  for (var j = 0; j < J; j++) {
    double sum = 0.0;
    for (final f in sigmaMask) {
      sum += SG_norm[f][j];
    }
    C[j] = sum;
  }

  final Cshort = _cma(C, Ishort);
  final Cbackg = _cma(C, Ibackg);
  final Cdiff = Float64List(J);
  for (var j = 0; j < J; j++) {
    Cdiff[j] = Cshort[j] - Cbackg[j];
  }

  final thresh = percentile(Cdiff, q);
  final regions = <(int, int)>[];
  var inRegion = false;
  var j1 = 0;
  for (var j = 0; j < J; j++) {
    final above = Cdiff[j] >= thresh;
    if (above && !inRegion) {
      j1 = j;
      inRegion = true;
    } else if (!above && inRegion) {
      regions.add((j1, j - 1));
      inRegion = false;
    }
  }
  if (inRegion) {
    regions.add((j1, J - 1));
  }

  if (regions.isEmpty) return const [];

  // 4. Sigma-band envelope via Hilbert transform
  final xSigma = bandpassFilter(signal, sfreq, low: fmin, high: fmax, order: 4);
  final envelope = Float64List.fromList(hilbertEnvelope(xSigma));
  final envSmooth = _cma(envelope, Lsmth);
  final envBackg = _cma(envSmooth, Lbackg);

  // 5. Find spindle boundaries within candidate regions
  final spindles = <(int, int)>[];
  for (final r in regions) {
    final nStart = math.max(0, r.$1 * delta_j);
    final nEnd = math.min(N, r.$2 * delta_j + Dmax);
    final len = nEnd - nStart;
    if (len <= 0) continue;

    final aboveBg = List<bool>.generate(len, (i) {
      return envSmooth[nStart + i] > envBackg[nStart + i];
    });

    final diff = Int8List(len + 1);
    diff[0] = aboveBg[0] ? 1 : 0;
    for (var i = 1; i < len; i++) {
      final cur = aboveBg[i] ? 1 : 0;
      final prev = aboveBg[i - 1] ? 1 : 0;
      diff[i] = cur - prev;
    }
    diff[len] = aboveBg[len - 1] ? -1 : 0;

    final startsLocal = <int>[];
    final endsLocal = <int>[];
    for (var i = 0; i <= len; i++) {
      if (diff[i] == 1) startsLocal.add(i);
      if (diff[i] == -1) endsLocal.add(i);
    }

    final minCount = math.min(startsLocal.length, endsLocal.length);
    for (var i = 0; i < minCount; i++) {
      final s = startsLocal[i];
      final e = endsLocal[i];
      final n1 = nStart + s;
      final n2 = nStart + e;
      final dur = n2 - n1;

      double peak = 0.0;
      if (n2 > n1) {
        peak = envSmooth[n1];
        for (var idx = n1 + 1; idx < n2; idx++) {
          if (envSmooth[idx] > peak) peak = envSmooth[idx];
        }
      }

      if (dur >= Dmin && dur < Dmax && peak >= amin) {
        spindles.add((n1, n2));
      }
    }
  }

  return spindles.map((s) => (s.$1 / sfreq, s.$2 / sfreq)).toList();
}

// ─────────────────────────────────────────────────────────────────────────────
// Chebyshev Type II Filter Design
// ─────────────────────────────────────────────────────────────────────────────

class BiquadSection {
  final double b0;
  final double b1;
  final double b2;
  final double a1;
  final double a2;

  const BiquadSection({
    required this.b0,
    required this.b1,
    required this.b2,
    required this.a1,
    required this.a2,
  });

  @override
  String toString() =>
      'BiquadSection(b0: $b0, b1: $b1, b2: $b2, a1: $a1, a2: $a2)';
}

List<BiquadSection> designCheby2SOS({
  required int order,
  required double rs, // stopband attenuation (e.g. 60.0)
  required double cutoff,
  required double sampleRate,
  required String btype, // 'lowpass' | 'highpass' | 'bandstop'
}) {
  final epsilon = 1.0 / math.sqrt(math.pow(10.0, rs / 10.0) - 1.0);
  final v = (1.0 / order) *
      math.log(
        1.0 / epsilon + math.sqrt(1.0 / (epsilon * epsilon) + 1.0),
      );
  final sinhV = (math.exp(v) - math.exp(-v)) / 2.0;
  final coshV = (math.exp(v) + math.exp(-v)) / 2.0;

  final List<BiquadSection> sections = [];

  if (btype == 'lowpass' || btype == 'highpass') {
    final omega0 = math.tan(math.pi * cutoff / sampleRate);

    for (var k = 1; k <= (order / 2).floor(); k++) {
      final mu = (2.0 * k - 1.0) * math.pi / (2.0 * order);
      final sinMu = math.sin(mu);
      final cosMu = math.cos(mu);

      final p1Real = -sinhV * sinMu;
      final p1Imag = coshV * cosMu;

      final denom = p1Real * p1Real + p1Imag * p1Imag;
      final pReal = p1Real / denom;
      final pImag = -p1Imag / denom;

      final zImag = 1.0 / cosMu;

      if (btype == 'lowpass') {
        final poleReal = pReal * omega0;
        final poleImag = pImag * omega0;
        final zeroImag = zImag * omega0;

        final A = -2.0 * poleReal;
        final B = poleReal * poleReal + poleImag * poleImag;
        final C = zeroImag * zeroImag;

        final D = 1.0 + A + B;
        var b0 = (1.0 + C) / D;
        var b1 = 2.0 * (C - 1.0) / D;
        var b2 = (1.0 + C) / D;
        final a1 = 2.0 * (B - 1.0) / D;
        final a2 = (1.0 - A + B) / D;

        final numAtDC = b0 + b1 + b2;
        final denAtDC = 1.0 + a1 + a2;
        if (numAtDC.abs() > 1e-12) {
          final scale = denAtDC / numAtDC;
          b0 *= scale;
          b1 *= scale;
          b2 *= scale;
        }

        sections.add(BiquadSection(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2));
      } else {
        final pDenom = pReal * pReal + pImag * pImag;
        final poleReal = (pReal / pDenom) * omega0;
        final poleImag = (-pImag / pDenom) * omega0;

        final zeroImag = omega0 / zImag;

        final A = -2.0 * poleReal;
        final B = poleReal * poleReal + poleImag * poleImag;
        final C = zeroImag * zeroImag;

        final D = 1.0 + A + B;
        var b0 = (1.0 + C) / D;
        var b1 = 2.0 * (C - 1.0) / D;
        var b2 = (1.0 + C) / D;
        final a1 = 2.0 * (B - 1.0) / D;
        final a2 = (1.0 - A + B) / D;

        final numAtNyquist = b0 - b1 + b2;
        final denAtNyquist = 1.0 - a1 + a2;
        if (numAtNyquist.abs() > 1e-12) {
          final scale = denAtNyquist / numAtNyquist;
          b0 *= scale;
          b1 *= scale;
          b2 *= scale;
        }

        sections.add(BiquadSection(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2));
      }
    }

    if (order % 2 != 0) {
      final p1Real = -sinhV;
      final pReal = 1.0 / p1Real;

      if (btype == 'lowpass') {
        final poleReal = pReal * omega0;
        final D = 1.0 - poleReal;
        var b0 = -poleReal / D;
        var b1 = -poleReal / D;
        final a1 = -(1.0 + poleReal) / D;

        final numAtDC = b0 + b1;
        final denAtDC = 1.0 + a1;
        if (numAtDC.abs() > 1e-12) {
          final scale = denAtDC / numAtDC;
          b0 *= scale;
          b1 *= scale;
        }

        sections.add(BiquadSection(b0: b0, b1: b1, b2: 0.0, a1: a1, a2: 0.0));
      } else {
        final poleReal = (1.0 / pReal) * omega0;
        final D = 1.0 - poleReal;
        var b0 = 1.0 / D;
        var b1 = -1.0 / D;
        final a1 = -(1.0 + poleReal) / D;

        final numAtNyquist = b0 - b1;
        final denAtNyquist = 1.0 - a1;
        if (numAtNyquist.abs() > 1e-12) {
          final scale = denAtNyquist / numAtNyquist;
          b0 *= scale;
          b1 *= scale;
        }

        sections.add(BiquadSection(b0: b0, b1: b1, b2: 0.0, a1: a1, a2: 0.0));
      }
    }
  } else if (btype == 'bandstop') {
    final lowCutoff = cutoff - 1.0;
    final highCutoff = cutoff + 1.0;

    final omega1 = math.tan(math.pi * lowCutoff / sampleRate);
    final omega2 = math.tan(math.pi * highCutoff / sampleRate);
    final omega0Sq = omega1 * omega2;
    final B_bw = omega2 - omega1;

    for (var k = 1; k <= (order / 2).floor(); k++) {
      final mu = (2.0 * k - 1.0) * math.pi / (2.0 * order);
      final sinMu = math.sin(mu);
      final cosMu = math.cos(mu);

      final p1Real = -sinhV * sinMu;
      final p1Imag = coshV * cosMu;

      final denom = p1Real * p1Real + p1Imag * p1Imag;
      final pReal = p1Real / denom;
      final pImag = -p1Imag / denom;

      final zImag = 1.0 / cosMu;

      final pDenom = pReal * pReal + pImag * pImag;
      final cReal = (B_bw * pReal) / pDenom;
      final cImag = (-B_bw * pImag) / pDenom;

      final cSqReal = cReal * cReal - cImag * cImag;
      final cSqImag = 2.0 * cReal * cImag;
      final dReal = cSqReal - 4.0 * omega0Sq;
      final dImag = cSqImag;

      final dist = math.sqrt(dReal * dReal + dImag * dImag);
      final rootReal = math.sqrt((dist + dReal) / 2.0);
      final rootImag = (dImag >= 0 ? 1.0 : -1.0) *
          math.sqrt((dist - dReal) / 2.0);

      final s1Real = (cReal + rootReal) / 2.0;
      final s1Imag = (cImag + rootImag) / 2.0;
      final s2Real = (cReal - rootReal) / 2.0;
      final s2Imag = (cImag - rootImag) / 2.0;

      final b_coef = B_bw / zImag;
      final disc = math.sqrt(b_coef * b_coef + 4.0 * omega0Sq);
      final omegaZ1 = (-b_coef + disc) / 2.0;
      final omegaZ2 = (-b_coef - disc) / 2.0;

      {
        final A = -2.0 * s1Real;
        final B = s1Real * s1Real + s1Imag * s1Imag;
        final C = omegaZ1 * omegaZ1;

        final D = 1.0 + A + B;
        var b0 = (1.0 + C) / D;
        var b1 = 2.0 * (C - 1.0) / D;
        var b2 = (1.0 + C) / D;
        final a1 = 2.0 * (B - 1.0) / D;
        final a2 = (1.0 - A + B) / D;

        final numAtDC = b0 + b1 + b2;
        final denAtDC = 1.0 + a1 + a2;
        if (numAtDC.abs() > 1e-12) {
          final scale = denAtDC / numAtDC;
          b0 *= scale;
          b1 *= scale;
          b2 *= scale;
        }
        sections.add(BiquadSection(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2));
      }

      {
        final A = -2.0 * s2Real;
        final B = s2Real * s2Real + s2Imag * s2Imag;
        final C = omegaZ2 * omegaZ2;

        final D = 1.0 + A + B;
        var b0 = (1.0 + C) / D;
        var b1 = 2.0 * (C - 1.0) / D;
        var b2 = (1.0 + C) / D;
        final a1 = 2.0 * (B - 1.0) / D;
        final a2 = (1.0 - A + B) / D;

        final numAtDC = b0 + b1 + b2;
        final denAtDC = 1.0 + a1 + a2;
        if (numAtDC.abs() > 1e-12) {
          final scale = denAtDC / numAtDC;
          b0 *= scale;
          b1 *= scale;
          b2 *= scale;
        }
        sections.add(BiquadSection(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2));
      }
    }

    if (order % 2 != 0) {
      final p1Real = -sinhV;
      final pReal = 1.0 / p1Real;

      final cReal = B_bw / pReal;
      final dReal = cReal * cReal - 4.0 * omega0Sq;

      double sReal1, sImag1, sReal2, sImag2;
      if (dReal < 0) {
        sReal1 = cReal / 2.0;
        sImag1 = math.sqrt(-dReal) / 2.0;
        sReal2 = cReal / 2.0;
        sImag2 = -math.sqrt(-dReal) / 2.0;
      } else {
        sReal1 = (cReal + math.sqrt(dReal)) / 2.0;
        sImag1 = 0.0;
        sReal2 = (cReal - math.sqrt(dReal)) / 2.0;
        sImag2 = 0.0;
      }

      final A = -(sReal1 + sReal2);
      final B = sReal1 * sReal2 + sImag1 * sImag2;
      final C = omega0Sq;

      final D = 1.0 + A + B;
      var b0 = (1.0 + C) / D;
      var b1 = 2.0 * (C - 1.0) / D;
      var b2 = (1.0 + C) / D;
      final a1 = 2.0 * (B - 1.0) / D;
      final a2 = (1.0 - A + B) / D;

      final numAtDC = b0 + b1 + b2;
      final denAtDC = 1.0 + a1 + a2;
      if (numAtDC.abs() > 1e-12) {
        final scale = denAtDC / numAtDC;
        b0 *= scale;
        b1 *= scale;
        b2 *= scale;
      }
      sections.add(BiquadSection(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2));
    }
  }

  return sections;
}
