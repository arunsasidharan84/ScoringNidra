// lib/src/eeg_backend.dart

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

import 'edf_loader.dart';
import 'mat_loader.dart';
import 'models.dart';
import 'signal_processing.dart' as sp;

// ─────────────────────────────────────────────────────────────────────────────
// Rust FFI bindings (optional — app works fully without the native library)
// ─────────────────────────────────────────────────────────────────────────────

typedef _LoadViewportNative =
    Pointer<_NativeViewport> Function(Pointer<Utf8> path);
typedef _LoadViewportDart =
    Pointer<_NativeViewport> Function(Pointer<Utf8> path);
typedef _FreeViewportNative = Void Function(Pointer<_NativeViewport> viewport);
typedef _FreeViewportDart = void Function(Pointer<_NativeViewport> viewport);

final class _SleepEegMorletResult extends Struct {
  external Pointer<Float> power;
  @Int32()
  external int powerLen;
  @Int32()
  external int nFreqs;
  @Int32()
  external int nSamples;
}

typedef _ComputeMorletNative =
    Pointer<_SleepEegMorletResult> Function(
      Pointer<Float> signal,
      Int32 nSamples,
      Float srate,
      Pointer<Float> freqs,
      Int32 nFreqs,
      Bool l2Normalize,
    );
typedef _ComputeMorletDart =
    Pointer<_SleepEegMorletResult> Function(
      Pointer<Float> signal,
      int nSamples,
      double srate,
      Pointer<Float> freqs,
      int nFreqs,
      bool l2Normalize,
    );

typedef _FreeMorletNative =
    Void Function(Pointer<_SleepEegMorletResult> result);
typedef _FreeMorletDart = void Function(Pointer<_SleepEegMorletResult> result);

final class _NativePoint extends Struct {
  @Float()
  external double x;
  @Float()
  external double y;
  @Int32()
  external int channel;
}

final class _NativeViewport extends Struct {
  @Float()
  external double sampleRateHz;
  @Int32()
  external int epochSeconds;
  @Int32()
  external int channelCount;
  @Int32()
  external int pointCount;
  external Pointer<_NativePoint> points;
}

// ─────────────────────────────────────────────────────────────────────────────

/// Configuration object passed around to control which channel drives
/// the spectrogram and other display panels.
class AppConfig {
  AppConfig({
    this.spectrogramChannelIndex = 0,
    this.periodogramChannelIndex = 0,
    this.tfChannelIndex = 0,
    this.amplitudeRangeUv = 75.0,
    this.tfFreqMin = 0.25,
    this.tfFreqMax = 45.0,
    this.spectrogramPowerMin = -1.0,
    this.spectrogramPowerMax = 3.0,
    this.tfEnabled = true,
  });

  int spectrogramChannelIndex;
  int periodogramChannelIndex;
  int tfChannelIndex;
  double amplitudeRangeUv;
  double tfFreqMin;
  double tfFreqMax;
  double spectrogramPowerMin;
  double spectrogramPowerMax;
  /// Whether the Morlet time-frequency panel is shown.
  /// Disabling this skips all wavelet computation for instant navigation.
  bool tfEnabled;

  Map<String, dynamic> toJson() {
    return {
      'spectrogramChannelIndex': spectrogramChannelIndex,
      'periodogramChannelIndex': periodogramChannelIndex,
      'tfChannelIndex': tfChannelIndex,
      'amplitudeRangeUv': amplitudeRangeUv,
      'tfFreqMin': tfFreqMin,
      'tfFreqMax': tfFreqMax,
      'spectrogramPowerMin': spectrogramPowerMin,
      'spectrogramPowerMax': spectrogramPowerMax,
      'tfEnabled': tfEnabled,
    };
  }

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    return AppConfig(
      spectrogramChannelIndex: json['spectrogramChannelIndex'] as int? ?? 0,
      periodogramChannelIndex: json['periodogramChannelIndex'] as int? ?? 0,
      tfChannelIndex: json['tfChannelIndex'] as int? ?? 0,
      amplitudeRangeUv: (json['amplitudeRangeUv'] as num?)?.toDouble() ?? 75.0,
      tfFreqMin: (json['tfFreqMin'] as num?)?.toDouble() ?? 0.25,
      tfFreqMax: (json['tfFreqMax'] as num?)?.toDouble() ?? 45.0,
      spectrogramPowerMin:
          (json['spectrogramPowerMin'] as num?)?.toDouble() ?? -1.0,
      spectrogramPowerMax:
          (json['spectrogramPowerMax'] as num?)?.toDouble() ?? 3.0,
      tfEnabled: json['tfEnabled'] as bool? ?? true,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class EegBackend {
  EegBackend() {
    try {
      final library = DynamicLibrary.open(_libraryName);
      _loadViewport = library
          .lookupFunction<_LoadViewportNative, _LoadViewportDart>(
            'sleep_eeg_load_viewport',
          );
      _freeViewport = library
          .lookupFunction<_FreeViewportNative, _FreeViewportDart>(
            'sleep_eeg_free_viewport',
          );
      _computeMorlet = library
          .lookupFunction<_ComputeMorletNative, _ComputeMorletDart>(
            'sleep_eeg_compute_morlet_tf',
          );
      _freeMorlet = library.lookupFunction<_FreeMorletNative, _FreeMorletDart>(
        'sleep_eeg_free_morlet_tf',
      );
      isNativeAvailable = true;
    } on Object {
      isNativeAvailable = false;
    }
  }

  late final bool isNativeAvailable;
  _LoadViewportDart? _loadViewport;
  _FreeViewportDart? _freeViewport;
  _ComputeMorletDart? _computeMorlet;
  _FreeMorletDart? _freeMorlet;

  final _displayPointCache = <String, List<DisplayPoint>>{};
  final _displayPointCacheOrder = <String>[];
  final _tfCache = <String, List<List<double>>>{};
  final _tfCacheOrder = <String>[];

  String get _libraryName {
    if (Platform.isMacOS) return 'librust_sleep_eeg.dylib';
    if (Platform.isWindows) return 'rust_sleep_eeg.dll';
    return 'librust_sleep_eeg.so';
  }

  // ─── Public loaders ────────────────────────────────────────────────────────

  LoadedEeg loadEdf(
    String path, {
    bool scaleVoltsToMicrovolts = false,
    AppConfig? config,
  }) {
    final raw = EdfLoader().load(
      path,
      scaleVoltsToMicrovolts: scaleVoltsToMicrovolts,
    );
    return computeNightProducts(raw, config ?? AppConfig());
  }

  LoadedEeg loadMat(String path, {AppConfig? config}) {
    final raw = MatLoader().load(path);
    return computeNightProducts(raw, config ?? AppConfig());
  }

  // ─── Signal processing pipeline (runs after every file load) ──────────────

  /// Compute the full-night spectrogram, SWA, epoch periodograms, and TF norms.
  /// Pre-computes Morlet TF for all epochs using a background isolate so
  /// epoch navigation becomes an O(1) cache lookup.
  Future<LoadedEeg> computeNightProducts(LoadedEeg raw, AppConfig config) async {
    if (raw.channelSamples.isEmpty) return raw;

    final srate = raw.sampleRateHz;
    const epochSeconds = 30;

    // Clamp channel index to valid range
    final spectCh = config.spectrogramChannelIndex.clamp(
      0,
      raw.channelSamples.length - 1,
    );
    final periodCh = config.periodogramChannelIndex.clamp(
      0,
      raw.channelSamples.length - 1,
    );

    // 1. Full-night Welch spectrogram
    final (:power, :freqs) = sp.computeSpectrogram(
      raw.channelSamples,
      srate,
      epochSeconds,
      spectCh,
    );

    // 2. SWA
    final swa = sp.computeSwa(power, freqs);

    // 3. Per-epoch Welch periodograms (for RectanglePower panel)
    final periodograms = sp.precomputeEpochPeriodograms(
      raw.channelSamples,
      srate,
      epochSeconds,
      periodCh,
    );

    // 4. TF frequency grid (linspace 0.25–45 Hz, 120 bins)
    final tfFreqMin = math.max(config.tfFreqMin, 0.25);
    final tfFreqMax = math.min(config.tfFreqMax, srate / 2 - 0.25);
    final tfFreqs = sp.linspaceList(tfFreqMin, tfFreqMax, 120);

    // 5. TF normalisation stats (night-wide median + IQR per TF freq)
    final (:median, :iqr) = sp.computeTfNormStats(power, freqs, tfFreqs);

    // 6. Pre-compute Morlet TF for ALL epochs so navigation is O(1).
    //    Skip if tfEnabled == false (user toggled off for faster scrolling).
    List<List<List<double>>> epochTfPower = const [];
    if (config.tfEnabled) {
      final totalDuration = raw.durationSeconds;
      final epochCount = math.max(1, (totalDuration / epochSeconds).ceil());
      final tfCh = config.tfChannelIndex.clamp(0, raw.channelSamples.length - 1);
      final signal = raw.channelSamples[tfCh];
      epochTfPower = await Isolate.run(
        () => _isolatePrecomputeAllTf(
          signal,
          srate,
          tfFreqs,
          epochCount,
          epochSeconds,
          median,
          iqr,
        ),
      );
    }

    return LoadedEeg(
      sampleRateHz: raw.sampleRateHz,
      channelLabels: raw.channelLabels,
      channelSamples: raw.channelSamples,
      sourceDescription: raw.sourceDescription,
      spectrogramPower: power,
      spectrogramFreqs: freqs,
      swaPerEpoch: swa,
      epochPeriodograms: periodograms,
      epochTfPower: epochTfPower,
      tfFreqs: tfFreqs,
      tfNormMedian: median,
      tfNormIqr: iqr,
      spectrogramChannelIndex: spectCh,
    );
  }

  // ─── Viewport construction ─────────────────────────────────────────────────

  Future<EegViewport> viewportFromEeg(
    LoadedEeg eeg, {
    required int currentEpoch,
    AppConfig? config,
    List<SleepStage>? existingStages,
  }) async {
    final cfg = config ?? AppConfig();
    const epochSeconds = 30;
    final totalDuration = eeg.durationSeconds;
    final epochCount = math.max(1, (totalDuration / epochSeconds).ceil());
    final safeEpoch = currentEpoch.clamp(0, epochCount - 1);
    final startSeconds = safeEpoch * epochSeconds.toDouble();

    // 5s contextual shading on both sides (40s total)
    final displayStartSec = startSeconds - 5.0;
    const displayDurationSec = 40.0;

    // EEG display points (normalised 0..1 across the 40s window)
    final points = _displayPointsForEpoch(
      eeg.channelSamples,
      eeg.sampleRateHz,
      displayStartSec,
      displayDurationSec,
      cfg,
    );

    // Per-epoch data for this epoch
    final (periodogram, periodogramFreqs) = _epochPeriodogramWithFreqs(
      eeg,
      safeEpoch,
      cfg,
    );

    final tfCh = cfg.tfChannelIndex.clamp(0, eeg.channelSamples.length - 1);
    final tfPower = await _timeFrequencyForEpoch(eeg, safeEpoch, cfg);

    return EegViewport(
      sampleRateHz: eeg.sampleRateHz,
      epochSeconds: epochSeconds,
      channelLabels: eeg.channelLabels,
      points: points,
      stages:
          existingStages ??
          [for (var i = 0; i < epochCount; i++) SleepStage.unknown],
      currentEpoch: safeEpoch,
      visibleStartSeconds: displayStartSec,
      visibleDurationSeconds: displayDurationSec,
      totalDurationSeconds: totalDuration,
      sourceDescription: eeg.sourceDescription,
      spectrogramPower: eeg.spectrogramPower,
      spectrogramFreqs: eeg.spectrogramFreqs,
      swaPerEpoch: eeg.swaPerEpoch,
      tfFreqs: eeg.tfFreqs,
      tfNormMedian: eeg.tfNormMedian,
      tfNormIqr: eeg.tfNormIqr,
      spectrogramChannelIndex: eeg.spectrogramChannelIndex,
      currentEpochPeriodogram: periodogram,
      periodogramFreqs: periodogramFreqs,
      tfPower: tfPower,
      tfChannelIndex: tfCh,
      amplitudeRangeUv: cfg.amplitudeRangeUv,
    );
  }

  Future<EegViewport> rebuildViewportForEpoch(
    EegViewport old,
    LoadedEeg eeg,
    int epoch, {
    AppConfig? config,
    bool includeTimeFrequency = true,
  }) async {
    final cfg = config ?? AppConfig();
    const epochSeconds = 30;
    final safeEpoch = epoch.clamp(0, old.epochCount - 1);
    final startSeconds = safeEpoch * epochSeconds.toDouble();

    final displayStartSec = startSeconds - 5.0;
    const displayDurationSec = 40.0;

    final points = _displayPointsForEpoch(
      eeg.channelSamples,
      eeg.sampleRateHz,
      displayStartSec,
      displayDurationSec,
      cfg,
    );

    final (periodogram, periodogramFreqs) = _epochPeriodogramWithFreqs(
      eeg,
      safeEpoch,
      cfg,
    );

    final tfCh = cfg.tfChannelIndex.clamp(0, eeg.channelSamples.length - 1);
    List<List<double>> tfPower;
    if (!includeTimeFrequency || !cfg.tfEnabled) {
      // TF disabled: keep existing (or empty)
      tfPower = old.tfPower;
    } else if (eeg.epochTfPower.isNotEmpty &&
        safeEpoch < eeg.epochTfPower.length) {
      // O(1) pre-computed cache lookup — this is the fast path
      tfPower = eeg.epochTfPower[safeEpoch];
    } else {
      // Fallback: compute on demand (slow, only if pre-cache failed)
      tfPower = await _timeFrequencyForEpoch(eeg, safeEpoch, cfg);
    }

    return old.copyWith(
      currentEpoch: safeEpoch,
      points: points,
      visibleStartSeconds: displayStartSec,
      visibleDurationSeconds: displayDurationSec,
      currentEpochPeriodogram: periodogram,
      periodogramFreqs: periodogramFreqs,
      tfPower: tfPower,
      tfChannelIndex: tfCh,
      amplitudeRangeUv: cfg.amplitudeRangeUv,
      clearSelection: true, // clear any selection when moving epoch
    );
  }

  Future<EegViewport> refreshTimeFrequencyForEpoch(
    EegViewport old,
    LoadedEeg eeg, {
    AppConfig? config,
  }) async {
    final cfg = config ?? AppConfig();
    final tfCh = cfg.tfChannelIndex.clamp(0, eeg.channelSamples.length - 1);
    final tfPower = await _timeFrequencyForEpoch(eeg, old.currentEpoch, cfg);
    return old.copyWith(tfPower: tfPower, tfChannelIndex: tfCh);
  }

  // ─── Selection updating ───────────────────────────────────────────────────

  Future<EegViewport> updateSelection(
    EegViewport old,
    LoadedEeg eeg,
    double? startSec,
    double? endSec, {
    AppConfig? config,
  }) async {
    final cfg = config ?? AppConfig();

    if (startSec == null || endSec == null) {
      final (periodogram, freqs) = _epochPeriodogramWithFreqs(
        eeg,
        old.currentEpoch,
        cfg,
      );
      return old.copyWith(
        currentEpochPeriodogram: periodogram,
        periodogramFreqs: freqs,
        clearSelection: true,
      );
    }

    final srate = eeg.sampleRateHz;
    final chIdx = cfg.periodogramChannelIndex.clamp(
      0,
      eeg.channelSamples.length - 1,
    );
    final signal = eeg.channelSamples[chIdx];

    final s1 = (startSec * srate).round().clamp(0, signal.length);
    final s2 = (endSec * srate).round().clamp(0, signal.length);
    final startSamp = math.min(s1, s2);
    final endSamp = math.max(s1, s2);

    // Require at least 0.5s of data for a meaningful periodogram
    if (endSamp - startSamp < srate * 0.5) return old;

    final slice = signal.sublist(startSamp, endSamp);

    // We can do this synchronously since it's just a subset of an epoch
    final (psd, freqs) = sp.welchPsd(slice, srate);
    final logPsd = psd
        .map((p) => p > 0 ? 10 * (math.log(p) / math.ln10) : 0.0)
        .toList();

    return old.copyWith(
      selectionStartSec: startSec,
      selectionEndSec: endSec,
      currentEpochPeriodogram: logPsd,
      periodogramFreqs: freqs,
    );
  }

  // ─── Display points generation ────────────────────────────────────────────────────────

  (List<double>, List<double>) _epochPeriodogramWithFreqs(
    LoadedEeg eeg,
    int epoch,
    AppConfig cfg,
  ) {
    final periodCh = cfg.periodogramChannelIndex.clamp(
      0,
      eeg.channelSamples.length - 1,
    );
    if (eeg.epochPeriodograms.isNotEmpty &&
        epoch < eeg.epochPeriodograms.length) {
      // Clamp to configured frequency limit (default 0–45 Hz)
      final freqs = eeg.spectrogramFreqs;
      final psd = eeg.epochPeriodograms[epoch];
      final maxFreq = math.min(45.0, eeg.sampleRateHz / 2);
      final filtered = <double>[];
      final filteredFreqs = <double>[];
      for (var i = 0; i < freqs.length && i < psd.length; i++) {
        if (freqs[i] <= maxFreq) {
          filteredFreqs.add(freqs[i]);
          filtered.add(psd[i]);
        }
      }
      return (filtered, filteredFreqs);
    }
    // Fallback: compute on-the-fly
    final signal = eeg.channelSamples[periodCh];
    const epochSeconds = 30;
    final srate = eeg.sampleRateHz;
    final start = epoch * (epochSeconds * srate).round();
    final end = math.min(signal.length, start + (epochSeconds * srate).round());
    if (start >= signal.length) return ([], []);
    final (psd, freqs) = sp.welchPsd(signal.sublist(start, end), srate);
    return (psd, freqs);
  }

  /// Compute Morlet TF power for one epoch. Returns z-scored log10 power
  /// shape: List<List<double>> (nFreqs × nSamples).
  // Removed instance _computeEpochTf, now using top-level _isolateComputeMorletTf

  // ─── EEG display point generation ─────────────────────────────────────────

  List<DisplayPoint> _displayPointsForEpoch(
    List<List<double>> channels,
    double sampleRate,
    double startSeconds,
    double durationSeconds,
    AppConfig cfg,
  ) {
    final cacheKey = [
      identityHashCode(channels),
      sampleRate.toStringAsFixed(3),
      startSeconds.toStringAsFixed(3),
      durationSeconds.toStringAsFixed(3),
      cfg.amplitudeRangeUv.toStringAsFixed(3),
    ].join(':');
    final cached = _displayPointCache[cacheKey];
    if (cached != null) {
      _touchCacheKey(_displayPointCacheOrder, cacheKey);
      return cached;
    }

    final points = <DisplayPoint>[];
    if (channels.isEmpty || sampleRate <= 0) return points;

    const maxPointsPerChannel = 2400;
    final rawStart = (startSeconds * sampleRate).floor();
    final start = math.max(0, rawStart);
    final end = math.min(
      channels.first.length,
      ((startSeconds + durationSeconds) * sampleRate).ceil(),
    );
    final count = math.max(0, end - start);
    if (count == 0) return points;
    final visibleSampleCount = math.max(
      1,
      (durationSeconds * sampleRate).round(),
    );
    final stride = math.max(1, (count / maxPointsPerChannel).ceil());
    final channelHeight = 1.0 / channels.length;

    for (var channel = 0; channel < channels.length; channel++) {
      final samples = channels[channel];
      final safeEnd = math.min(end, samples.length);
      if (safeEnd <= start) continue;
      final slice = samples.sublist(start, safeEnd);
      final mean = slice.reduce((a, b) => a + b) / slice.length;

      final maxAbs = cfg.amplitudeRangeUv;
      final baseline = channelHeight * (channel + 0.5);
      for (var sample = start; sample < safeEnd; sample += stride) {
        final t = (sample - rawStart) / visibleSampleCount;
        final normalized = ((samples[sample] - mean) / maxAbs).clamp(-1.0, 1.0);
        points.add(
          DisplayPoint(
            x: t,
            y: baseline - normalized * channelHeight * 0.42,
            channel: channel,
          ),
        );
      }
    }
    _rememberCacheValue(
      _displayPointCache,
      _displayPointCacheOrder,
      cacheKey,
      points,
      15,
    );
    return points;
  }

  Future<List<List<double>>> _timeFrequencyForEpoch(
    LoadedEeg eeg,
    int epoch,
    AppConfig cfg,
  ) async {
    if (eeg.channelSamples.isEmpty || eeg.tfFreqs.isEmpty) return const [];

    const epochSeconds = 30;
    const extensionSec = 1.0;
    final safeEpoch = epoch.clamp(
      0,
      math.max(0, (eeg.durationSeconds / epochSeconds).ceil() - 1),
    );
    final tfCh = cfg.tfChannelIndex.clamp(0, eeg.channelSamples.length - 1);
    final signal = eeg.channelSamples[tfCh];
    final srate = eeg.sampleRateHz;
    final cacheKey = [
      identityHashCode(eeg),
      safeEpoch,
      tfCh,
      srate.toStringAsFixed(3),
      eeg.tfFreqs.length,
      eeg.tfFreqs.first.toStringAsFixed(3),
      eeg.tfFreqs.last.toStringAsFixed(3),
    ].join(':');
    final cached = _tfCache[cacheKey];
    if (cached != null) {
      _touchCacheKey(_tfCacheOrder, cacheKey);
      return cached;
    }

    final startSamples = math.max(
      0,
      (safeEpoch * epochSeconds * srate - extensionSec * srate).round(),
    );
    final endSamples = math.min(
      signal.length,
      ((safeEpoch + 1) * epochSeconds * srate + extensionSec * srate).round(),
    );
    if (startSamples >= endSamples) return const [];

    final slice = signal.sublist(startSamples, endSamples);
    final rawPower = await Isolate.run(
      () => _isolateComputeMorletTf(slice, srate, eeg.tfFreqs),
    );
    final logPower = sp.log10TfPower(rawPower);
    final tfPower = sp.zScoreTfPower(logPower, eeg.tfNormMedian, eeg.tfNormIqr);
    _rememberCacheValue(_tfCache, _tfCacheOrder, cacheKey, tfPower, 5);
    return tfPower;
  }

  void _touchCacheKey(List<String> order, String key) {
    order.remove(key);
    order.add(key);
  }

  void _rememberCacheValue<T>(
    Map<String, T> cache,
    List<String> order,
    String key,
    T value,
    int maxEntries,
  ) {
    cache[key] = value;
    _touchCacheKey(order, key);
    while (order.length > maxEntries) {
      cache.remove(order.removeAt(0));
    }
  }

  // ─── Demo viewport ─────────────────────────────────────────────────────────

  EegViewport loadDemoViewport() {
    const channels = ['EEG L', 'EEG R', 'EOG', 'EMG', 'Acc'];
    const samplesPerChannel = 1800;
    final channelHeight = 1.0 / channels.length;
    final points = <DisplayPoint>[];

    for (var channel = 0; channel < channels.length; channel++) {
      final baseline = channelHeight * (channel + 0.5);
      final freq = 2.0 + channel * 0.8;
      for (var index = 0; index < samplesPerChannel; index++) {
        final t = index / (samplesPerChannel - 1);
        final wave = math.sin(t * math.pi * 2 * freq);
        final spindle = math.sin(t * math.pi * 2 * 13.5) * 0.18;
        final drift = math.sin(t * math.pi * 2 * 0.18 + channel) * 0.08;
        points.add(
          DisplayPoint(
            x: t,
            y: baseline + (wave * 0.10 + spindle + drift) * channelHeight,
            channel: channel,
          ),
        );
      }
    }

    return EegViewport(
      sampleRateHz: 256,
      epochSeconds: 30,
      channelLabels: channels,
      points: points,
      stages: const [
        SleepStage.unknown,
        SleepStage.wake,
        SleepStage.n1,
        SleepStage.n2,
        SleepStage.n2,
        SleepStage.n3,
        SleepStage.n3,
        SleepStage.n2,
        SleepStage.rem,
        SleepStage.rem,
        SleepStage.wake,
      ],
      currentEpoch: 3,
      visibleStartSeconds: 90,
      visibleDurationSeconds: 30,
      totalDurationSeconds: 330,
      sourceDescription: 'Generated demo trace — load an EDF to begin scoring',
    );
  }

  EegViewport _fromNative(_NativeViewport native) {
    final points = <DisplayPoint>[];
    for (var index = 0; index < native.pointCount; index++) {
      final point = (native.points + index).ref;
      points.add(DisplayPoint(x: point.x, y: point.y, channel: point.channel));
    }
    return EegViewport(
      sampleRateHz: native.sampleRateHz,
      epochSeconds: native.epochSeconds,
      channelLabels: [
        for (var i = 0; i < native.channelCount; i++) 'Ch ${i + 1}',
      ],
      points: points,
      stages: const [
        SleepStage.wake,
        SleepStage.n1,
        SleepStage.n2,
        SleepStage.n3,
        SleepStage.rem,
      ],
      currentEpoch: 0,
      visibleStartSeconds: 0,
      visibleDurationSeconds: 30,
      totalDurationSeconds: 150,
      sourceDescription: 'Rust FFI viewport',
    );
  }
}
// ─── Top-Level Isolate Functions ─────────────────────────────────────────────

List<List<double>> _isolateComputeMorletTf(
  List<double> slice,
  double srate,
  List<double> freqs,
) {
  String getLibraryName() {
    if (Platform.isMacOS) return 'librust_sleep_eeg.dylib';
    if (Platform.isWindows) return 'rust_sleep_eeg.dll';
    return 'librust_sleep_eeg.so';
  }

  _ComputeMorletDart? computeMorlet;
  _FreeMorletDart? freeMorlet;

  try {
    final library = DynamicLibrary.open(getLibraryName());
    computeMorlet = library
        .lookupFunction<_ComputeMorletNative, _ComputeMorletDart>(
          'sleep_eeg_compute_morlet_tf',
        );
    freeMorlet = library.lookupFunction<_FreeMorletNative, _FreeMorletDart>(
      'sleep_eeg_free_morlet_tf',
    );
  } catch (_) {
    // Fallback to Dart
  }

  if (computeMorlet != null && freeMorlet != null) {
    final signalPtr = calloc<Float>(slice.length);
    for (var i = 0; i < slice.length; i++) {
      signalPtr[i] = slice[i];
    }
    final freqsPtr = calloc<Float>(freqs.length);
    for (var i = 0; i < freqs.length; i++) {
      freqsPtr[i] = freqs[i];
    }

    final resultPtr = computeMorlet(
      signalPtr,
      slice.length,
      srate,
      freqsPtr,
      freqs.length,
      true,
    );

    calloc.free(signalPtr);
    calloc.free(freqsPtr);

    if (resultPtr != nullptr) {
      final res = resultPtr.ref;
      final rawPower = List.generate(res.nFreqs, (i) {
        final row = <double>[];
        for (var j = 0; j < res.nSamples; j++) {
          row.add(res.power[i * res.nSamples + j]);
        }
        return row;
      });
      freeMorlet(resultPtr);
      return rawPower;
    }
  }

  return sp.computeMorletTf(slice, srate, freqs);
}

// ─── Pre-compute ALL epochs' Morlet TF in one isolate pass ───────────────────
//
// Called once at file load time. Returns a list indexed by epoch, where each
// element is nFreqs × nSamples z-scored log10 Morlet power.
// This runs entirely in an isolate so the UI remains responsive during loading.

List<List<List<double>>> _isolatePrecomputeAllTf(
  List<double> signal,
  double srate,
  List<double> freqs,
  int epochCount,
  int epochSeconds,
  List<double> normMedian,
  List<double> normIqr,
) {
  // Resolve native library inside the isolate (cannot share DynamicLibrary)
  String libName() {
    if (Platform.isMacOS) return 'librust_sleep_eeg.dylib';
    if (Platform.isWindows) return 'rust_sleep_eeg.dll';
    return 'librust_sleep_eeg.so';
  }

  _ComputeMorletDart? computeMorlet;
  _FreeMorletDart? freeMorlet;
  try {
    final lib = DynamicLibrary.open(libName());
    computeMorlet = lib.lookupFunction<_ComputeMorletNative, _ComputeMorletDart>(
      'sleep_eeg_compute_morlet_tf',
    );
    freeMorlet = lib.lookupFunction<_FreeMorletNative, _FreeMorletDart>(
      'sleep_eeg_free_morlet_tf',
    );
  } catch (_) {/* fall back to pure Dart */}

  // Allocate freq pointer once and reuse
  final freqsPtr = calloc<Float>(freqs.length);
  for (var i = 0; i < freqs.length; i++) freqsPtr[i] = freqs[i];

  final result = <List<List<double>>>[];

  const extensionSec = 1.0;
  final samplesPerEpoch = (epochSeconds * srate).round();
  final extensionSamples = (extensionSec * srate).round();

  for (var ep = 0; ep < epochCount; ep++) {
    final startSamp = math.max(0, ep * samplesPerEpoch - extensionSamples);
    final endSamp = math.min(signal.length, (ep + 1) * samplesPerEpoch + extensionSamples);
    if (startSamp >= endSamp) { result.add(const []); continue; }

    final slice = signal.sublist(startSamp, endSamp);
    List<List<double>> rawPower;

    if (computeMorlet != null && freeMorlet != null) {
      final sigPtr = calloc<Float>(slice.length);
      for (var i = 0; i < slice.length; i++) sigPtr[i] = slice[i];
      final res = computeMorlet(sigPtr, slice.length, srate, freqsPtr, freqs.length, true);
      calloc.free(sigPtr);
      if (res != nullptr) {
        final r = res.ref;
        rawPower = List.generate(r.nFreqs, (fi) {
          final row = <double>[];
          for (var t = 0; t < r.nSamples; t++) row.add(r.power[fi * r.nSamples + t]);
          return row;
        });
        freeMorlet(res);
      } else {
        rawPower = sp.computeMorletTf(slice, srate, freqs);
      }
    } else {
      rawPower = sp.computeMorletTf(slice, srate, freqs);
    }

    // log10 + z-score normalisation
    final logPow = sp.log10TfPower(rawPower);
    final zPow = sp.zScoreTfPower(logPow, normMedian, normIqr);
    result.add(zPow);
  }

  calloc.free(freqsPtr);
  return result;
}
