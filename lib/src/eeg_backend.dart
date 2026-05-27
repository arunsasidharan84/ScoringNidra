// lib/src/eeg_backend.dart

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';

import 'edf_loader.dart';
import 'mat_loader.dart';
import 'r09_loader.dart' as r09;
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

final class _EdfSignal extends Struct {
  external Pointer<Utf8> label;
  external Pointer<Float> samples;
  @Int32()
  external int sampleCount;
}

final class _EdfFile extends Struct {
  @Float()
  external double sampleRateHz;
  @Int32()
  external int signalCount;
  external Pointer<_EdfSignal> signals;
  @Float()
  external double durationSeconds;
}

typedef _LoadEdfNative = Pointer<_EdfFile> Function(Pointer<Utf8> path, Bool scaleVolts);
typedef _LoadEdfDart = Pointer<_EdfFile> Function(Pointer<Utf8> path, bool scaleVolts);
typedef _FreeEdfNative = Void Function(Pointer<_EdfFile> edf);
typedef _FreeEdfDart = void Function(Pointer<_EdfFile> edf);

final class _SpectrogramResult extends Struct {
  external Pointer<Float> power;
  @Int32()
  external int powerLen;
  external Pointer<Float> freqs;
  @Int32()
  external int freqsLen;
  @Int32()
  external int nEpochs;
  @Int32()
  external int nFreqs;
}

typedef _ComputeSpectrogramNative = Pointer<_SpectrogramResult> Function(
  Pointer<Float> signal,
  Int32 signalLen,
  Float srate,
  Int32 epochSeconds,
  Int32 extensionSeconds,
);
typedef _ComputeSpectrogramDart = Pointer<_SpectrogramResult> Function(
  Pointer<Float> signal,
  int signalLen,
  double srate,
  int epochSeconds,
  int extensionSeconds,
);
typedef _FreeSpectrogramNative = Void Function(Pointer<_SpectrogramResult> result);
typedef _FreeSpectrogramDart = void Function(Pointer<_SpectrogramResult> result);


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
    this.spectrogramFreqMin = 0.0,
    this.spectrogramFreqMax = 45.0,
    this.periodogramFreqMin = 4.0,
    this.periodogramFreqMax = 45.0,
    this.spectrogramPowerMin = -1.0,
    this.spectrogramPowerMax = 3.0,
    this.tfEnabled = true,
    this.tfDisplayMode = 'dB (median baseline)',
    this.tfFrequencyScale = 'Linear',
    this.tfShowRidge = false,
    this.tfPowerMin = 0.0,
    this.tfPowerMax = 20.0,
    this.stackChannels = false,
    this.robustZStandardize = false,
    this.periodogramDisplayMode = '1/f Removed',
    this.eegPanelTimeUnit = 'Seconds',
    this.distanceBetweenChannelsUv = 25.0,
    this.referenceAmplitudeLineUv = 37.5,
    this.channels = const [],
  });

  int spectrogramChannelIndex;
  int periodogramChannelIndex;
  int tfChannelIndex;
  double amplitudeRangeUv;
  double tfFreqMin;
  double tfFreqMax;
  double spectrogramFreqMin;
  double spectrogramFreqMax;
  double periodogramFreqMin;
  double periodogramFreqMax;
  double spectrogramPowerMin;
  double spectrogramPowerMax;

  /// Whether the Morlet time-frequency panel is shown.
  /// Disabling this skips all wavelet computation for instant navigation.
  bool tfEnabled;

  String tfDisplayMode;
  String tfFrequencyScale;
  bool tfShowRidge;
  double tfPowerMin;
  double tfPowerMax;

  bool stackChannels;
  bool robustZStandardize;
  String periodogramDisplayMode;
  String eegPanelTimeUnit;
  double distanceBetweenChannelsUv;
  double referenceAmplitudeLineUv;
  List<ChannelConfig> channels;

  Map<String, dynamic> toJson() {
    return {
      'spectrogramChannelIndex': spectrogramChannelIndex,
      'periodogramChannelIndex': periodogramChannelIndex,
      'tfChannelIndex': tfChannelIndex,
      'amplitudeRangeUv': amplitudeRangeUv,
      'tfFreqMin': tfFreqMin,
      'tfFreqMax': tfFreqMax,
      'spectrogramFreqMin': spectrogramFreqMin,
      'spectrogramFreqMax': spectrogramFreqMax,
      'periodogramFreqMin': periodogramFreqMin,
      'periodogramFreqMax': periodogramFreqMax,
      'spectrogramPowerMin': spectrogramPowerMin,
      'spectrogramPowerMax': spectrogramPowerMax,
      'tfEnabled': tfEnabled,
      'tfDisplayMode': tfDisplayMode,
      'tfFrequencyScale': tfFrequencyScale,
      'tfShowRidge': tfShowRidge,
      'tfPowerMin': tfPowerMin,
      'tfPowerMax': tfPowerMax,
      'stackChannels': stackChannels,
      'robustZStandardize': robustZStandardize,
      'periodogramDisplayMode': periodogramDisplayMode,
      'eegPanelTimeUnit': eegPanelTimeUnit,
      'distanceBetweenChannelsUv': distanceBetweenChannelsUv,
      'referenceAmplitudeLineUv': referenceAmplitudeLineUv,
      'channels': channels.map((c) => c.toJson()).toList(),
    };
  }

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    int safeInt(dynamic v, int def) {
      if (v == null) return def;
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? def;
      return def;
    }

    bool safeBool(dynamic v, bool def) {
      if (v == null) return def;
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final l = v.toLowerCase();
        return l == 'true' || l == '1' || l == 'yes';
      }
      return def;
    }

    return AppConfig(
      spectrogramChannelIndex: safeInt(json['spectrogramChannelIndex'], 0),
      periodogramChannelIndex: safeInt(json['periodogramChannelIndex'], 0),
      tfChannelIndex: safeInt(json['tfChannelIndex'], 0),
      amplitudeRangeUv: (json['amplitudeRangeUv'] as num?)?.toDouble() ?? 75.0,
      tfFreqMin: (json['tfFreqMin'] as num?)?.toDouble() ?? 0.25,
      tfFreqMax: (json['tfFreqMax'] as num?)?.toDouble() ?? 45.0,
      spectrogramFreqMin:
          (json['spectrogramFreqMin'] as num?)?.toDouble() ?? 0.0,
      spectrogramFreqMax:
          (json['spectrogramFreqMax'] as num?)?.toDouble() ?? 45.0,
      periodogramFreqMin:
          (json['periodogramFreqMin'] as num?)?.toDouble() ?? 4.0,
      periodogramFreqMax:
          (json['periodogramFreqMax'] as num?)?.toDouble() ?? 45.0,
      spectrogramPowerMin:
          (json['spectrogramPowerMin'] as num?)?.toDouble() ?? -1.0,
      spectrogramPowerMax:
          (json['spectrogramPowerMax'] as num?)?.toDouble() ?? 3.0,
      tfEnabled: safeBool(json['tfEnabled'], true),
      tfDisplayMode: json['tfDisplayMode'] as String? ?? 'dB (median baseline)',
      tfFrequencyScale: json['tfFrequencyScale'] as String? ?? 'Linear',
      tfShowRidge: safeBool(json['tfShowRidge'], false),
      tfPowerMin: (json['tfPowerMin'] as num?)?.toDouble() ?? 0.0,
      tfPowerMax: (json['tfPowerMax'] as num?)?.toDouble() ?? 20.0,
      stackChannels: safeBool(json['stackChannels'], false),
      robustZStandardize: safeBool(json['robustZStandardize'], false),
      periodogramDisplayMode:
          json['periodogramDisplayMode'] as String? ?? '1/f Removed',
      eegPanelTimeUnit: json['eegPanelTimeUnit'] as String? ?? 'Seconds',
      distanceBetweenChannelsUv:
          (json['distanceBetweenChannelsUv'] as num?)?.toDouble() ?? 25.0,
      referenceAmplitudeLineUv:
          (json['referenceAmplitudeLineUv'] as num?)?.toDouble() ?? 37.5,
      channels: (json['channels'] as List<dynamic>?)
              ?.map((c) => ChannelConfig.fromJson(Map<String, dynamic>.from(c as Map)))
              .toList() ??
          const [],
    );
  }

  List<dynamic> toPythonJson() {
    final global = {
      'Channel_for_spectogram':
          channels.isNotEmpty && spectrogramChannelIndex < channels.length
          ? channels[spectrogramChannelIndex].name
          : '',
      'Periodogram_channel':
          channels.isNotEmpty && periodogramChannelIndex < channels.length
          ? channels[periodogramChannelIndex].name
          : '',
      'Wavelet_channel': channels.isNotEmpty && tfChannelIndex < channels.length
          ? channels[tfChannelIndex].name
          : '',
      'Reference_amplitude_line_muV': referenceAmplitudeLineUv,
      'Amplitude_range_muV': amplitudeRangeUv,
      'Wavelet_frequency_limits_hz': [tfFreqMin, tfFreqMax],
      'Wavelet_frequency_scale': tfFrequencyScale,
      'Spectrogram_power_limits': [spectrogramPowerMin, spectrogramPowerMax],
      'Spectogram_limit_hz': [spectrogramFreqMin, spectrogramFreqMax],
      'Periodogram_limit_hz': [periodogramFreqMin, periodogramFreqMax],
      'Periodogram_display_mode': periodogramDisplayMode,
      'Wavelet_panel_visible': tfEnabled,
      'Wavelet_show_ridge': tfShowRidge,
      'Wavelet_display_mode': tfDisplayMode,
      'Wavelet_power_limits': {
        tfDisplayMode: [tfPowerMin, tfPowerMax],
      },
      'Stack_channels': stackChannels,
      'Robust_z_standardize': robustZStandardize,
      'Distance_between_channels_muV': distanceBetweenChannelsUv,
      'EEG_panel_time_unit': eegPanelTimeUnit,
      'Epoch_length_s': 30,
      'Sampling_rate_hz': 256.0,
      'Extension_epoch_s': [5.0, 5.0],
    };
    final channelsList = channels.map((c) => c.toJson()).toList();
    return [global, channelsList];
  }

  factory AppConfig.fromPythonJson(dynamic json, List<String> loadedLabels) {
    if (json is List && json.length >= 2) {
      final global = json[0] as Map<String, dynamic>;
      final channelsList = json[1] as List<dynamic>;

      final channels = channelsList
          .map((c) => ChannelConfig.fromJson(Map<String, dynamic>.from(c as Map)))
          .toList();
      final channelNames = channels.map((c) => c.name).toList();

      int indexOfChannel(String? name) {
        if (name == null) return 0;
        final idx = channelNames.indexOf(name);
        return idx >= 0 ? idx : 0;
      }

      final specCh = global['Channel_for_spectogram'] as String?;
      final periodCh = global['Periodogram_channel'] as String?;
      final tfCh = global['Wavelet_channel'] as String?;
      final amp = global['Reference_amplitude_line_muV'] as num?;
      final tfDisplay =
          global['Wavelet_display_mode'] as String? ?? 'dB (median baseline)';
      final tfVis = _boolValue(global['Wavelet_panel_visible'], fallback: true);
      final tfScale = global['Wavelet_frequency_scale'] as String? ?? 'Linear';
      final tfRidge = _boolValue(global['Wavelet_show_ridge']);
      final stack = _boolValue(global['Stack_channels']);
      final robust = _boolValue(global['Robust_z_standardize']);
      final periodogramMode =
          global['Periodogram_display_mode'] as String? ?? '1/f Removed';
      final eegPanelTimeUnit =
          global['EEG_panel_time_unit'] as String? ?? 'Seconds';
      final dist =
          (global['Distance_between_channels_muV'] as num?)?.toDouble() ?? 25.0;

      final specLimits = global['Spectrogram_power_limits'] as List<dynamic>?;
      final specFreqLimits = global['Spectogram_limit_hz'] as List<dynamic>?;
      final periodFreqLimits = global['Periodogram_limit_hz'] as List<dynamic>?;
      final tfPowerLimitsMap =
          global['Wavelet_power_limits'] as Map<String, dynamic>?;

      double tfMin = 0.0;
      double tfMax = 20.0;
      if (tfPowerLimitsMap != null && tfPowerLimitsMap.containsKey(tfDisplay)) {
        final limits = tfPowerLimitsMap[tfDisplay] as List<dynamic>?;
        if (limits != null && limits.length >= 2) {
          tfMin = (limits[0] as num).toDouble();
          tfMax = (limits[1] as num).toDouble();
        }
      }

      final tfFreqLimits =
          global['Wavelet_frequency_limits_hz'] as List<dynamic>?;
      double tfFreqMin = 0.25;
      double tfFreqMax = 45.0;
      if (tfFreqLimits != null && tfFreqLimits.length >= 2) {
        tfFreqMin = (tfFreqLimits[0] as num).toDouble();
        tfFreqMax = (tfFreqLimits[1] as num).toDouble();
      }

      return AppConfig(
        spectrogramChannelIndex: indexOfChannel(specCh),
        periodogramChannelIndex: indexOfChannel(periodCh),
        tfChannelIndex: indexOfChannel(tfCh),
        amplitudeRangeUv: (global['Amplitude_range_muV'] as num?)?.toDouble() ?? 75.0,
        referenceAmplitudeLineUv: amp?.toDouble() ?? 37.5,
        tfEnabled: tfVis,
        tfDisplayMode: tfDisplay,
        tfFrequencyScale: tfScale,
        tfShowRidge: tfRidge,
        tfPowerMin: tfMin,
        tfPowerMax: tfMax,
        tfFreqMin: tfFreqMin,
        tfFreqMax: tfFreqMax,
        spectrogramFreqMin: specFreqLimits != null && specFreqLimits.isNotEmpty
            ? (specFreqLimits[0] as num).toDouble()
            : 0.0,
        spectrogramFreqMax: specFreqLimits != null && specFreqLimits.length >= 2
            ? (specFreqLimits[1] as num).toDouble()
            : 45.0,
        periodogramFreqMin:
            periodFreqLimits != null && periodFreqLimits.isNotEmpty
            ? (periodFreqLimits[0] as num).toDouble()
            : 4.0,
        periodogramFreqMax:
            periodFreqLimits != null && periodFreqLimits.length >= 2
            ? (periodFreqLimits[1] as num).toDouble()
            : 45.0,
        spectrogramPowerMin: specLimits != null && specLimits.isNotEmpty
            ? (specLimits[0] as num).toDouble()
            : -1.0,
        spectrogramPowerMax: specLimits != null && specLimits.length >= 2
            ? (specLimits[1] as num).toDouble()
            : 3.0,
        stackChannels: stack,
        robustZStandardize: robust,
        periodogramDisplayMode: periodogramMode,
        eegPanelTimeUnit: eegPanelTimeUnit,
        distanceBetweenChannelsUv: dist,
        channels: channels,
      );
    }

    final defaultChannels = loadedLabels
        .asMap()
        .entries
        .map(
          (entry) => _defaultChannelConfig(
            entry.value,
            entry.key,
            loadedLabels.length,
          ),
        )
        .toList();
    return AppConfig(channels: defaultChannels);
  }

  static AppConfig defaultsForChannels(
    List<String> labels, {
    required double sampleRateHz,
  }) {
    return AppConfig(
      spectrogramChannelIndex: 0,
      periodogramChannelIndex: 0,
      tfChannelIndex: 0,
      amplitudeRangeUv: 75.0,
      distanceBetweenChannelsUv: 25.0,
      referenceAmplitudeLineUv: 37.5,
      channels: labels.asMap().entries.map((entry) {
        return _defaultChannelConfig(entry.value, entry.key, labels.length);
      }).toList(),
    );
  }

  static ChannelConfig _defaultChannelConfig(
    String name,
    int index,
    int channelCount,
  ) {
    final upper = name.toUpperCase();
    var color = 'Black';
    if (upper.contains('EOG')) {
      color = 'Blue';
    } else if (upper.contains('ECG')) {
      color = 'Magenta';
    } else if (upper.contains('EMG')) {
      color = 'Orange';
    }
    var display = index < 9;
    if (channelCount == 9 && (index == 1 || index == 3 || index == 5)) {
      display = false;
    }
    return ChannelConfig(
      name: name,
      sourceIndex: index,
      color: color,
      displayOnScreen: display,
    );
  }

  void bindLoadedChannels(List<String> loadedLabels) {
    if (channels.isEmpty) {
      channels = defaultsForChannels(
        loadedLabels,
        sampleRateHz: 256.0,
      ).channels;
      return;
    }

    final rawNameToIndex = <String, int>{};
    for (var i = 0; i < loadedLabels.length; i++) {
      rawNameToIndex[loadedLabels[i]] = i;
    }

    for (var i = 0; i < channels.length; i++) {
      final channel = channels[i];
      if (channel.sourceIndex != null &&
          channel.sourceIndex! >= 0 &&
          channel.sourceIndex! < loadedLabels.length) {
        continue;
      }

      final sourceName = channel.derived
          ? (channel.sourceChannel ?? channel.name)
          : channel.name;
      final byName = rawNameToIndex[sourceName];
      final fallback = i < loadedLabels.length ? i : null;
      channel.sourceIndex = byName ?? fallback;
    }

    if (channels.isNotEmpty) {
      spectrogramChannelIndex = spectrogramChannelIndex.clamp(
        0,
        channels.length - 1,
      );
      periodogramChannelIndex = periodogramChannelIndex.clamp(
        0,
        channels.length - 1,
      );
      tfChannelIndex = tfChannelIndex.clamp(0, channels.length - 1);
    }
  }

  static bool _boolValue(Object? value, {bool fallback = false}) {
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final lower = value.toLowerCase();
      if (lower == 'true' || lower == '1' || lower == 'yes') return true;
      if (lower == 'false' || lower == '0' || lower == 'no') return false;
    }
    return fallback;
  }
}

// ─────────────────────────────────────────────────────────────────────────────

DynamicLibrary _openDynamicLibrary() {
  String name;
  if (Platform.isMacOS) {
    name = 'librust_sleep_eeg.dylib';
  } else if (Platform.isWindows) {
    name = 'rust_sleep_eeg.dll';
  } else {
    name = 'librust_sleep_eeg.so';
  }

  final paths = [
    name,
    '${Directory.current.path}/rust_backend/target/release/$name',
    '${Directory.current.path}/rust_backend/target/debug/$name',
    '${File(Platform.resolvedExecutable).parent.path}/$name',
    '${File(Platform.resolvedExecutable).parent.path}/../Frameworks/$name',
  ];

  for (final path in paths) {
    try {
      return DynamicLibrary.open(path);
    } catch (_) {}
  }
  throw OSError('Could not open library: $name');
}

// ─────────────────────────────────────────────────────────────────────────────

class EegBackend {
  EegBackend() {
    try {
      final library = _openDynamicLibrary();
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
      try {
        _loadEdf = library.lookupFunction<_LoadEdfNative, _LoadEdfDart>(
          'sleep_eeg_load_edf',
        );
        _freeEdf = library.lookupFunction<_FreeEdfNative, _FreeEdfDart>(
          'sleep_eeg_free_edf',
        );
      } catch (_) {}
      try {
        _computeSpectrogramNative = library.lookupFunction<
            _ComputeSpectrogramNative, _ComputeSpectrogramDart>(
          'sleep_eeg_compute_welch_spectrogram',
        );
        _freeSpectrogramNative = library.lookupFunction<
            _FreeSpectrogramNative, _FreeSpectrogramDart>(
          'sleep_eeg_free_spectrogram',
        );
      } catch (_) {}
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
  _LoadEdfDart? _loadEdf;
  _FreeEdfDart? _freeEdf;
  _ComputeSpectrogramDart? _computeSpectrogramNative;
  _FreeSpectrogramDart? _freeSpectrogramNative;

  final _displayPointCache = <String, List<Float32List>>{};
  final _displayPointCacheOrder = <String>[];
  final _tfCache = <String, List<List<double>>>{};
  final _tfCacheOrder = <String>[];
  final _tfImageCache = <String, ui.Image>{};
  final _tfImageCacheOrder = <String>[];

  /// Clears the waveform display point cache. Call this when filter or
  /// channel display settings change to ensure stale cached waveforms
  /// are not shown.
  void clearDisplayCache() {
    _displayPointCache.clear();
    _displayPointCacheOrder.clear();
  }

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
    if (_loadEdf != null && _freeEdf != null) {
      final pathPtr = path.toNativeUtf8();
      try {
        final edfPtr = _loadEdf!(pathPtr, scaleVoltsToMicrovolts);
        if (edfPtr != nullptr) {
          final edf = edfPtr.ref;
          final channelLabels = <String>[];
          final channelSamples = <List<double>>[];
          
          for (var i = 0; i < edf.signalCount; i++) {
            final sig = edf.signals[i];
            channelLabels.add(sig.label.toDartString());
            
            final count = sig.sampleCount;
            final samples = Float64List(count);
            for (var j = 0; j < count; j++) {
              samples[j] = sig.samples[j];
            }
            channelSamples.add(samples);
          }
          
          final sampleRate = edf.sampleRateHz;
          final durationSec = edf.durationSeconds;
          
          _freeEdf!(edfPtr);
          
          return LoadedEeg(
            sampleRateHz: sampleRate,
            channelLabels: channelLabels,
            channelSamples: channelSamples,
            sourceDescription:
                '${channelLabels.length} channels, ${sampleRate.toStringAsFixed(1)} Hz, ${(durationSec / 60).toStringAsFixed(1)} min (native)',
          );
        }
      } catch (_) {
        // Fallback to Dart
      } finally {
        calloc.free(pathPtr);
      }
    }
    return EdfLoader().load(
      path,
      scaleVoltsToMicrovolts: scaleVoltsToMicrovolts,
    );
  }

  LoadedEeg loadMat(String path, {AppConfig? config}) {
    return MatLoader().load(path);
  }

  LoadedEeg loadR09(String path, {AppConfig? config}) {
    return r09.loadR09(path);
  }

  // ─── Signal processing pipeline (runs after every file load) ──────────────

  /// Compute the full-night spectrogram, SWA, epoch periodograms, and TF norms.
  /// Morlet TF is intentionally computed per viewed epoch, not for the whole
  /// night at load time. Full-night TF precompute makes large EDF opens feel
  /// frozen and uses too much memory.
  Future<LoadedEeg> computeNightProducts(
    LoadedEeg raw,
    AppConfig config,
  ) async {
    if (raw.channelSamples.isEmpty) return raw;

    final srate = raw.sampleRateHz;
    const epochSeconds = 30;

    final spectConfigIndex = _clampConfigIndex(
      config.spectrogramChannelIndex,
      config,
    );
    final periodConfigIndex = _clampConfigIndex(
      config.periodogramChannelIndex,
      config,
    );
    final spectSignal = _fullSignalForConfig(
      raw.channelSamples,
      config,
      spectConfigIndex,
    );
    final periodSignal = _fullSignalForConfig(
      raw.channelSamples,
      config,
      periodConfigIndex,
    );
    final spectSource = _sourceIndexForConfig(
      _configAt(config, spectConfigIndex, raw.channelSamples.length),
      config,
      spectConfigIndex,
      raw.channelSamples.length,
    );

    // 1. Full-night Welch spectrogram
    final spectResult = await Isolate.run(
      () => _isolateComputeSpectrogram(spectSignal, srate, epochSeconds, 1),
    );
    final power = spectResult.power;
    final freqs = spectResult.freqs;

    // 2. SWA
    final swa = sp.computeSwa(power, freqs);

    // 3. Per-epoch Welch periodograms (for RectanglePower panel)
    final periodResult = await Isolate.run(
      () => _isolateComputeSpectrogram(periodSignal, srate, epochSeconds, 0),
    );
    final periodograms = periodResult.power;

    // 4. TF frequency grid (linspace 0.25–45 Hz, 120 bins)
    final tfFreqMin = math.max(config.tfFreqMin, 0.25);
    final tfFreqMax = math.min(config.tfFreqMax, srate / 2 - 0.25);
    final tfFreqs = config.tfFrequencyScale == 'Logarithmic'
        ? sp.geomspace(math.max(tfFreqMin, 0.1), tfFreqMax, 120)
        : sp.linspaceList(tfFreqMin, tfFreqMax, 120);

    // 5. TF normalisation stats (night-wide median + IQR per TF freq)
    final (:median, :iqr) = sp.computeTfNormStats(power, freqs, tfFreqs);

    final spectrogramImage = await _spectrogramPowerToImage(
      power,
      freqs,
      config.spectrogramPowerMin,
      config.spectrogramPowerMax,
    );

    return LoadedEeg(
      sampleRateHz: raw.sampleRateHz,
      channelLabels: raw.channelLabels,
      channelSamples: raw.channelSamples,
      sourceDescription: raw.sourceDescription,
      spectrogramPower: power,
      spectrogramFreqs: freqs,
      swaPerEpoch: swa,
      epochPeriodograms: periodograms,
      epochTfPower: const [],
      tfFreqs: tfFreqs,
      tfNormMedian: median,
      tfNormIqr: iqr,
      spectrogramChannelIndex: spectSource >= 0 ? spectSource : 0,
      spectrogramImage: spectrogramImage,
    );
  }
  // ─── Viewport construction ─────────────────────────────────────────────────

  Future<EegViewport> viewportFromEeg(
    LoadedEeg eeg, {
    required int currentEpoch,
    AppConfig? config,
    List<SleepStage>? existingStages,
    List<bool>? existingStagesUncertain,
    bool includeTimeFrequency = true,
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
    final visibleChannels = _visibleChannelProjection(eeg, cfg);

    // EEG display points (normalised 0..1 across the 40s window)
    final points = _displayPointsForEpoch(
      eeg.channelSamples,
      eeg.sampleRateHz,
      displayStartSec,
      displayDurationSec,
      cfg,
      visibleChannels.indices,
      visibleChannels.configs,
    );

    // Per-epoch data for this epoch
    final (periodogram, periodogramFreqs) = _epochPeriodogramWithFreqs(
      eeg,
      safeEpoch,
      cfg,
    );

    final tfCh = _tfSourceIndex(eeg, cfg);
    final tfPower = !includeTimeFrequency || !cfg.tfEnabled
        ? const <List<double>>[]
        : eeg.epochTfPower.isNotEmpty && safeEpoch < eeg.epochTfPower.length
        ? eeg.epochTfPower[safeEpoch]
        : await _timeFrequencyForEpoch(eeg, safeEpoch, cfg);

    ui.Image? tfImage;
    if (tfPower.isNotEmpty) {
      final imageKey = [
        identityHashCode(eeg),
        safeEpoch,
        tfCh,
        eeg.sampleRateHz.toStringAsFixed(3),
        eeg.tfFreqs.length,
        eeg.tfFreqs.first.toStringAsFixed(3),
        eeg.tfFreqs.last.toStringAsFixed(3),
        cfg.tfDisplayMode,
        cfg.tfFrequencyScale,
        cfg.tfPowerMin.toStringAsFixed(2),
        cfg.tfPowerMax.toStringAsFixed(2),
      ].join(':');

      tfImage = _tfImageCache[imageKey];
      if (tfImage == null) {
        tfImage = await _tfPowerToImage(
          tfPower,
          cfg.tfPowerMin,
          cfg.tfPowerMax,
        );
        _rememberCacheValue(
          _tfImageCache,
          _tfImageCacheOrder,
          imageKey,
          tfImage,
          50,
        );
      }
    }

    return EegViewport(
      sampleRateHz: eeg.sampleRateHz,
      epochSeconds: epochSeconds,
      channelLabels: eeg.channelLabels,
      points: points,
      stages:
          existingStages ??
          [for (var i = 0; i < epochCount; i++) SleepStage.unknown],
      stagesUncertain:
          existingStagesUncertain ??
          [for (var i = 0; i < epochCount; i++) false],
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
      spectrogramChannelIndex: cfg.spectrogramChannelIndex,
      spectrogramImage: eeg.spectrogramImage,
      currentEpochPeriodogram: periodogram,
      periodogramFreqs: periodogramFreqs,
      tfPower: tfPower,
      tfImage: tfImage,
      tfChannelIndex: cfg.tfChannelIndex,
      periodogramChannelIndex: cfg.periodogramChannelIndex,
      amplitudeRangeUv: cfg.amplitudeRangeUv,
      referenceAmplitudeLineUv: cfg.referenceAmplitudeLineUv,
      visibleChannelLabels: visibleChannels.labels,
      visibleChannelSourceIndices: visibleChannels.indices,
      visibleChannelColors: visibleChannels.colors,
      tfDisplayMode: cfg.tfDisplayMode,
      tfPowerMin: cfg.tfPowerMin,
      tfPowerMax: cfg.tfPowerMax,
      periodogramFreqMin: cfg.periodogramFreqMin,
      periodogramFreqMax: cfg.periodogramFreqMax,
      periodogramDisplayMode: cfg.periodogramDisplayMode,
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
    final visibleChannels = _visibleChannelProjection(eeg, cfg);

    final points = _displayPointsForEpoch(
      eeg.channelSamples,
      eeg.sampleRateHz,
      displayStartSec,
      displayDurationSec,
      cfg,
      visibleChannels.indices,
      visibleChannels.configs,
    );

    final (periodogram, periodogramFreqs) = _epochPeriodogramWithFreqs(
      eeg,
      safeEpoch,
      cfg,
    );

    final tfCh = _tfSourceIndex(eeg, cfg);
    List<List<double>> tfPower;
    if (!includeTimeFrequency || !cfg.tfEnabled) {
      tfPower = old.currentEpoch == safeEpoch ? old.tfPower : const [];
    } else if (eeg.epochTfPower.isNotEmpty &&
        safeEpoch < eeg.epochTfPower.length) {
      // O(1) pre-computed cache lookup — this is the fast path
      tfPower = eeg.epochTfPower[safeEpoch];
    } else {
      // Fallback: compute on demand (slow, only if pre-cache failed)
      tfPower = await _timeFrequencyForEpoch(eeg, safeEpoch, cfg);
    }

    ui.Image? tfImage;
    if (tfPower.isNotEmpty) {
      final imageKey = [
        identityHashCode(eeg),
        safeEpoch,
        tfCh,
        eeg.sampleRateHz.toStringAsFixed(3),
        eeg.tfFreqs.length,
        eeg.tfFreqs.first.toStringAsFixed(3),
        eeg.tfFreqs.last.toStringAsFixed(3),
        cfg.tfDisplayMode,
        cfg.tfFrequencyScale,
        cfg.tfPowerMin.toStringAsFixed(2),
        cfg.tfPowerMax.toStringAsFixed(2),
      ].join(':');

      tfImage = _tfImageCache[imageKey];
      if (tfImage == null) {
        tfImage = await _tfPowerToImage(
          tfPower,
          cfg.tfPowerMin,
          cfg.tfPowerMax,
        );
        _rememberCacheValue(
          _tfImageCache,
          _tfImageCacheOrder,
          imageKey,
          tfImage,
          50,
        );
      }
    }

    return old.copyWith(
      currentEpoch: safeEpoch,
      points: points,
      visibleStartSeconds: displayStartSec,
      visibleDurationSeconds: displayDurationSec,
      currentEpochPeriodogram: periodogram,
      periodogramFreqs: periodogramFreqs,
      tfPower: tfPower,
      tfImage: tfImage,
      clearTfImage: tfImage == null,
      tfChannelIndex: tfCh,
      amplitudeRangeUv: cfg.amplitudeRangeUv,
      visibleChannelLabels: visibleChannels.labels,
      visibleChannelSourceIndices: visibleChannels.indices,
      visibleChannelColors: visibleChannels.colors,
      clearSelection: true, // clear any selection when moving epoch
      clearEventSelections: old.currentEpoch != safeEpoch,
      tfDisplayMode: cfg.tfDisplayMode,
      tfPowerMin: cfg.tfPowerMin,
      tfPowerMax: cfg.tfPowerMax,
      periodogramFreqMin: cfg.periodogramFreqMin,
      periodogramFreqMax: cfg.periodogramFreqMax,
      periodogramDisplayMode: cfg.periodogramDisplayMode,
      spectrogramImage: eeg.spectrogramImage,
    );
  }

  EegViewport rebuildViewportForEpochSync(
    EegViewport old,
    LoadedEeg eeg,
    int epoch, {
    AppConfig? config,
  }) {
    final cfg = config ?? AppConfig();
    const epochSeconds = 30;
    final safeEpoch = epoch.clamp(0, old.epochCount - 1);
    final startSeconds = safeEpoch * epochSeconds.toDouble();

    final displayStartSec = startSeconds - 5.0;
    const displayDurationSec = 40.0;
    final visibleChannels = _visibleChannelProjection(eeg, cfg);

    final points = _displayPointsForEpoch(
      eeg.channelSamples,
      eeg.sampleRateHz,
      displayStartSec,
      displayDurationSec,
      cfg,
      visibleChannels.indices,
      visibleChannels.configs,
    );

    final (periodogram, periodogramFreqs) = _epochPeriodogramWithFreqs(
      eeg,
      safeEpoch,
      cfg,
    );

    final tfCh = _tfSourceIndex(eeg, cfg);
    List<List<double>> tfPower;
    if (eeg.epochTfPower.isNotEmpty && safeEpoch < eeg.epochTfPower.length) {
      tfPower = eeg.epochTfPower[safeEpoch];
    } else {
      final tfConfigIndex = cfg.tfChannelIndex.clamp(0, eeg.channelSamples.length - 1);
      final tfCfg = _configAt(cfg, tfConfigIndex, eeg.channelSamples.length);
      final cacheKey = [
        identityHashCode(eeg),
        safeEpoch,
        tfCh,
        eeg.sampleRateHz.toStringAsFixed(3),
        eeg.tfFreqs.length,
        eeg.tfFreqs.first.toStringAsFixed(3),
        eeg.tfFreqs.last.toStringAsFixed(3),
        cfg.tfDisplayMode,
        cfg.tfFrequencyScale,
        _channelConfigSignature(tfCfg),
      ].join(':');
      final cached = _tfCache[cacheKey];
      if (cached != null) {
        tfPower = cached;
      } else {
        tfPower = old.currentEpoch == safeEpoch ? old.tfPower : const [];
      }
    }

    ui.Image? tfImage;
    if (tfPower.isNotEmpty) {
      final imageKey = [
        identityHashCode(eeg),
        safeEpoch,
        tfCh,
        eeg.sampleRateHz.toStringAsFixed(3),
        eeg.tfFreqs.length,
        eeg.tfFreqs.first.toStringAsFixed(3),
        eeg.tfFreqs.last.toStringAsFixed(3),
        cfg.tfDisplayMode,
        cfg.tfFrequencyScale,
        cfg.tfPowerMin.toStringAsFixed(2),
        cfg.tfPowerMax.toStringAsFixed(2),
      ].join(':');
      tfImage = _tfImageCache[imageKey] ?? (old.currentEpoch == safeEpoch ? old.tfImage : null);
    }

    return old.copyWith(
      currentEpoch: safeEpoch,
      points: points,
      visibleStartSeconds: displayStartSec,
      visibleDurationSeconds: displayDurationSec,
      currentEpochPeriodogram: periodogram,
      periodogramFreqs: periodogramFreqs,
      tfPower: tfPower,
      tfImage: tfImage,
      clearTfImage: tfImage == null,
      tfChannelIndex: tfCh,
      amplitudeRangeUv: cfg.amplitudeRangeUv,
      visibleChannelLabels: visibleChannels.labels,
      visibleChannelSourceIndices: visibleChannels.indices,
      visibleChannelColors: visibleChannels.colors,
      clearSelection: true,
      clearEventSelections: old.currentEpoch != safeEpoch,
      tfDisplayMode: cfg.tfDisplayMode,
      tfPowerMin: cfg.tfPowerMin,
      tfPowerMax: cfg.tfPowerMax,
      periodogramFreqMin: cfg.periodogramFreqMin,
      periodogramFreqMax: cfg.periodogramFreqMax,
      periodogramDisplayMode: cfg.periodogramDisplayMode,
      spectrogramImage: eeg.spectrogramImage,
    );
  }

  Future<EegViewport> refreshTimeFrequencyForEpoch(
    EegViewport old,
    LoadedEeg eeg, {
    AppConfig? config,
  }) async {
    final cfg = config ?? AppConfig();
    if (!cfg.tfEnabled) {
      return old.copyWith(
        tfPower: const [],
        tfChannelIndex: _tfSourceIndex(eeg, cfg),
        tfDisplayMode: cfg.tfDisplayMode,
        tfPowerMin: cfg.tfPowerMin,
        tfPowerMax: cfg.tfPowerMax,
        clearTfImage: true,
        spectrogramImage: eeg.spectrogramImage,
      );
    }
    final tfCh = _tfSourceIndex(eeg, cfg);
    final tfPower =
        eeg.epochTfPower.isNotEmpty &&
            old.currentEpoch < eeg.epochTfPower.length
        ? eeg.epochTfPower[old.currentEpoch]
        : await _timeFrequencyForEpoch(eeg, old.currentEpoch, cfg);

    ui.Image? tfImage;
    if (tfPower.isNotEmpty) {
      final imageKey = [
        identityHashCode(eeg),
        old.currentEpoch,
        tfCh,
        eeg.sampleRateHz.toStringAsFixed(3),
        eeg.tfFreqs.length,
        eeg.tfFreqs.first.toStringAsFixed(3),
        eeg.tfFreqs.last.toStringAsFixed(3),
        cfg.tfDisplayMode,
        cfg.tfFrequencyScale,
        cfg.tfPowerMin.toStringAsFixed(2),
        cfg.tfPowerMax.toStringAsFixed(2),
      ].join(':');

      tfImage = _tfImageCache[imageKey];
      if (tfImage == null) {
        tfImage = await _tfPowerToImage(
          tfPower,
          cfg.tfPowerMin,
          cfg.tfPowerMax,
        );
        _rememberCacheValue(
          _tfImageCache,
          _tfImageCacheOrder,
          imageKey,
          tfImage,
          50,
        );
      }
    }

    return old.copyWith(
      tfPower: tfPower,
      tfImage: tfImage,
      clearTfImage: tfImage == null,
      tfChannelIndex: tfCh,
      tfDisplayMode: cfg.tfDisplayMode,
      tfPowerMin: cfg.tfPowerMin,
      tfPowerMax: cfg.tfPowerMax,
      spectrogramImage: eeg.spectrogramImage,
    );
  }

  // ─── Selection updating ───────────────────────────────────────────────────

  Future<EegViewport> updateSelection(
    EegViewport old,
    LoadedEeg eeg,
    double? startSec,
    double? endSec, {
    int? channel,
    double? startUv,
    double? endUv,
    AppConfig? config,
  }) async {
    final cfg = config ?? AppConfig();

    if (startSec == null || endSec == null || channel == null) {
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
    final signalChannelIndices = old.signalChannelSourceIndices;
    final chIdx = channel >= 0 && channel < signalChannelIndices.length
        ? signalChannelIndices[channel]
              .clamp(0, eeg.channelSamples.length - 1)
              .toInt()
        : channel.clamp(0, eeg.channelSamples.length - 1).toInt();
    final visibleLabels = old.signalChannelLabels;
    final selectedLabel = channel >= 0 && channel < visibleLabels.length
        ? visibleLabels[channel]
        : null;
    final configIndex = selectedLabel == null
        ? -1
        : cfg.channels.indexWhere((c) => c.name == selectedLabel);
    final selectedConfig = configIndex >= 0
        ? cfg.channels[configIndex]
        : _configForRawChannel(chIdx, cfg, eeg.channelSamples.length);
    final signal = eeg.channelSamples[chIdx];

    final isClick = (endSec - startSec).abs() < 0.1 &&
        startUv != null &&
        endUv != null &&
        (endUv - startUv).abs() < 2.0;

    if (isClick) {
      // 1. Check if click falls inside an existing selection box
      EventSelection? clickedSelection;
      for (final sel in old.eventSelections) {
        if (sel.channel == channel) {
          final tMin = math.min(sel.startSec, sel.endSec);
          final tMax = math.max(sel.startSec, sel.endSec);
          final uvMin = math.min(sel.startUv, sel.endUv);
          final uvMax = math.max(sel.startUv, sel.endUv);
          if (startSec >= tMin && startSec <= tMax &&
              startUv >= uvMin && startUv <= uvMax) {
            clickedSelection = sel;
            break;
          }
        }
      }

      if (clickedSelection != null) {
        final newSelections = old.eventSelections.where((s) => s != clickedSelection).toList();
        if (newSelections.isNotEmpty) {
          final lastSel = newSelections.last;
          final lastCh = lastSel.channel;
          final lastChIdx = lastCh >= 0 && lastCh < signalChannelIndices.length
              ? signalChannelIndices[lastCh].clamp(0, eeg.channelSamples.length - 1).toInt()
              : lastCh.clamp(0, eeg.channelSamples.length - 1).toInt();
          final lastSignal = eeg.channelSamples[lastChIdx];
          final lastLabel = lastCh >= 0 && lastCh < visibleLabels.length ? visibleLabels[lastCh] : null;
          final lastCfgIndex = lastLabel == null ? -1 : cfg.channels.indexWhere((c) => c.name == lastLabel);
          final lastCfg = lastCfgIndex >= 0 ? cfg.channels[lastCfgIndex] : _configForRawChannel(lastChIdx, cfg, eeg.channelSamples.length);
          
          final ls1 = (lastSel.startSec * srate).round().clamp(0, lastSignal.length);
          final ls2 = (lastSel.endSec * srate).round().clamp(0, lastSignal.length);
          final lStart = math.min(ls1, ls2);
          final lEnd = math.max(ls1, ls2);
          if (lEnd - lStart >= 4) {
            final slice = _displaySegmentForChannel(
              eeg.channelSamples,
              srate,
              lStart,
              lEnd,
              lastCfg,
              cfg,
              applyFilters: true,
            );
            if (slice.length >= 4) {
              final (psd, freqs) = sp.welchPsd(slice, srate);
              return old.copyWith(
                eventSelections: newSelections,
                currentEpochPeriodogram: psd,
                periodogramFreqs: freqs,
                periodogramChannelIndex: lastChIdx,
                selectionStartSec: lastSel.startSec,
                selectionEndSec: lastSel.endSec,
                selectionChannel: lastSel.channel,
                selectionStartUv: lastSel.startUv,
                selectionEndUv: lastSel.endUv,
                selectionPeakToPeakUv: lastSel.peakToPeakUv,
              );
            }
          }
        }
        
        final (periodogram, freqs) = _epochPeriodogramWithFreqs(
          eeg,
          old.currentEpoch,
          cfg,
        );
        return old.copyWith(
          eventSelections: newSelections,
          currentEpochPeriodogram: periodogram,
          periodogramFreqs: freqs,
          clearSelection: true,
        );
      }

      // 2. Check if click falls inside a marked event
      ScoredEvent? clickedEvent;
      for (final ev in old.scoredEvents) {
        final tMin = math.min(ev.startSec, ev.endSec);
        final tMax = math.max(ev.startSec, ev.endSec);
        if (startSec >= tMin && startSec <= tMax) {
          clickedEvent = ev;
          break;
        }
      }

      if (clickedEvent != null) {
        final newEvents = old.scoredEvents.where((e) => e != clickedEvent).toList();
        return old.copyWith(
          scoredEvents: newEvents,
        );
      }

      // 3. Otherwise, click outside -> clear all selections!
      final (periodogram, freqs) = _epochPeriodogramWithFreqs(
        eeg,
        old.currentEpoch,
        cfg,
      );
      return old.copyWith(
        eventSelections: const [],
        currentEpochPeriodogram: periodogram,
        periodogramFreqs: freqs,
        clearSelection: true,
      );
    }

    final s1 = (startSec * srate).round().clamp(0, signal.length);
    final s2 = (endSec * srate).round().clamp(0, signal.length);
    final startSamp = math.min(s1, s2);
    final endSamp = math.max(s1, s2);

    if (endSamp - startSamp < 4) return old;

    final slice = _displaySegmentForChannel(
      eeg.channelSamples,
      srate,
      startSamp,
      endSamp,
      selectedConfig,
      cfg,
      applyFilters: true,
    );
    if (slice.length < 4) return old;

    // We can do this synchronously since it's just a subset of an epoch
    final (psd, freqs) = sp.welchPsd(slice, srate);

    // Calculate peak-to-peak amplitude
    double minVal = slice[0];
    double maxVal = slice[0];
    for (var i = 1; i < slice.length; i++) {
      final v = slice[i];
      if (v < minVal) minVal = v;
      if (v > maxVal) maxVal = v;
    }
    final peakToPeak = maxVal - minVal;

    final selection = EventSelection(
      startSec: startSec,
      endSec: endSec,
      channel: channel,
      startUv: startUv ?? 0.0,
      endUv: endUv ?? 0.0,
      peakToPeakUv: peakToPeak,
    );

    return old.copyWith(
      selectionStartSec: startSec,
      selectionEndSec: endSec,
      selectionChannel: channel,
      selectionStartUv: startUv,
      selectionEndUv: endUv,
      selectionPeakToPeakUv: peakToPeak,
      eventSelections: [...old.eventSelections, selection],
      currentEpochPeriodogram: psd,
      periodogramFreqs: freqs,
      periodogramChannelIndex: chIdx,
    );
  }

  // ─── Display points generation ────────────────────────────────────────────────────────

  (List<double>, List<double>) _epochPeriodogramWithFreqs(
    LoadedEeg eeg,
    int epoch,
    AppConfig cfg,
  ) {
    if (eeg.epochPeriodograms.isNotEmpty &&
        epoch < eeg.epochPeriodograms.length) {
      // Clamp to configured frequency limit (default 0–45 Hz)
      final freqs = eeg.spectrogramFreqs;
      final psd = eeg.epochPeriodograms[epoch];
      final minFreq = math.max(0.0, cfg.periodogramFreqMin);
      final maxFreq = math.min(cfg.periodogramFreqMax, eeg.sampleRateHz / 2);
      final filtered = <double>[];
      final filteredFreqs = <double>[];
      for (var i = 0; i < freqs.length && i < psd.length; i++) {
        if (freqs[i] >= minFreq && freqs[i] <= maxFreq) {
          filteredFreqs.add(freqs[i]);
          filtered.add(psd[i]);
        }
      }
      return (filtered, filteredFreqs);
    }
    // Fallback: compute on-the-fly
    final periodConfigIndex = _clampConfigIndex(
      cfg.periodogramChannelIndex,
      cfg,
    );
    final signal = _fullSignalForConfig(
      eeg.channelSamples,
      cfg,
      periodConfigIndex,
    );
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

  List<Float32List> _displayPointsForEpoch(
    List<List<double>> channels,
    double sampleRate,
    double startSeconds,
    double durationSeconds,
    AppConfig cfg,
    List<int> visibleIndices,
    List<ChannelConfig> visibleConfigs,
  ) {
    final cacheKey = [
      identityHashCode(channels),
      sampleRate.toStringAsFixed(3),
      startSeconds.toStringAsFixed(3),
      durationSeconds.toStringAsFixed(3),
      cfg.amplitudeRangeUv.toStringAsFixed(3),
      visibleIndices.join(','),
      cfg.stackChannels,
      cfg.robustZStandardize,
      for (final ch in visibleConfigs) _channelConfigSignature(ch),
    ].join(':');
    final cached = _displayPointCache[cacheKey];
    if (cached != null) {
      _touchCacheKey(_displayPointCacheOrder, cacheKey);
      return cached;
    }

    final waves = <Float32List>[];
    if (channels.isEmpty || sampleRate <= 0) return waves;

    final rawStart = (startSeconds * sampleRate).floor();
    final start = math.max(0, rawStart);
    final end = math.min(
      channels.first.length,
      ((startSeconds + durationSeconds) * sampleRate).ceil(),
    );
    final count = math.max(0, end - start);
    if (count == 0) return waves;

    final displayIndices = visibleIndices.isEmpty
        ? [for (var i = 0; i < channels.length; i++) i]
        : visibleIndices.where((i) => i >= 0 && i < channels.length).toList();
    if (displayIndices.isEmpty) return waves;
    final channelHeight = 1.0 / displayIndices.length;

    for (
      var displayIndex = 0;
      displayIndex < displayIndices.length;
      displayIndex++
    ) {
      final channel = displayIndices[displayIndex];
      final channelCfg = displayIndex < visibleConfigs.length
          ? visibleConfigs[displayIndex]
          : _configForRawChannel(channel, cfg, channels.length);
      final sourceSamples = channels[channel];
      final safeEnd = math.min(end, sourceSamples.length);
      final segment = _displaySegmentForChannel(
        channels,
        sampleRate,
        start,
        safeEnd,
        channelCfg,
        cfg,
        applyFilters: true,
      );
      if (segment.isEmpty) {
        waves.add(Float32List(0));
        continue;
      }

      var displayData = segment;
      const targetPoints = 3000;
      if (segment.length > targetPoints) {
        displayData = _minMaxDownsample(segment, targetPoints);
      }

      double sum = 0.0;
      var meanCount = 0;
      for (var i = 0; i < displayData.length; i += 32) {
        sum += displayData[i];
        meanCount++;
      }
      final mean = meanCount > 0 ? sum / meanCount : 0.0;

      final maxAbs = math.max(cfg.amplitudeRangeUv, 1e-6);
      final baseline = cfg.stackChannels
          ? 0.5
          : channelHeight * (displayIndex + 0.5);
      final scale = channelCfg.scalingFactor / 100.0;
      final shift = channelCfg.verticalShift;
      final robustStats = cfg.robustZStandardize
          ? _robustStats(displayData, 0, displayData.length)
          : null;

      final yValues = Float32List(displayData.length);
      for (var sample = 0; sample < displayData.length; sample++) {
        final rawValue = robustStats == null
            ? displayData[sample] - mean
            : ((displayData[sample] - robustStats.median) / robustStats.iqr) *
                  cfg.referenceAmplitudeLineUv;
        final sampleUv = (rawValue * scale) + shift;
        final normalized = sampleUv / maxAbs;
        yValues[sample] = baseline - normalized * channelHeight * 0.42;
      }
      waves.add(yValues);
    }
    _rememberCacheValue(
      _displayPointCache,
      _displayPointCacheOrder,
      cacheKey,
      waves,
      15,
    );
    return waves;
  }

  List<double> _minMaxDownsample(List<double> data, int targetPoints) {
    final count = data.length;
    if (count <= targetPoints) {
      return data;
    }
    final numBins = targetPoints ~/ 2;
    if (numBins <= 0) return data;
    final binSize = count / numBins;
    final result = List<double>.filled(numBins * 2, 0.0);
    var writeIdx = 0;

    for (var bin = 0; bin < numBins; bin++) {
      final startIdx = (bin * binSize).round();
      var endIdx = ((bin + 1) * binSize).round();
      if (endIdx > count) endIdx = count;
      if (startIdx >= endIdx) continue;

      var minVal = data[startIdx];
      var maxVal = data[startIdx];
      var minPos = startIdx;
      var maxPos = startIdx;

      for (var i = startIdx + 1; i < endIdx; i++) {
        final val = data[i];
        if (val < minVal) {
          minVal = val;
          minPos = i;
        }
        if (val > maxVal) {
          maxVal = val;
          maxPos = i;
        }
      }

      if (minPos < maxPos) {
        result[writeIdx++] = minVal;
        result[writeIdx++] = maxVal;
      } else {
        result[writeIdx++] = maxVal;
        result[writeIdx++] = minVal;
      }
    }

    if (writeIdx < result.length) {
      return result.sublist(0, writeIdx);
    }
    return result;
  }

  int _clampConfigIndex(int index, AppConfig cfg) {
    if (cfg.channels.isEmpty) return math.max(0, index);
    return index.clamp(0, cfg.channels.length - 1).toInt();
  }

  ChannelConfig _configAt(AppConfig cfg, int index, int channelCount) {
    if (index >= 0 && index < cfg.channels.length) return cfg.channels[index];
    return ChannelConfig(
      name: 'Channel ${index + 1}',
      sourceIndex: index.clamp(0, math.max(0, channelCount - 1)).toInt(),
    );
  }

  int _tfSourceIndex(LoadedEeg eeg, AppConfig cfg) {
    if (eeg.channelSamples.isEmpty) return 0;
    final tfConfigIndex = _clampConfigIndex(cfg.tfChannelIndex, cfg);
    final tfCfg = _configAt(cfg, tfConfigIndex, eeg.channelSamples.length);
    final source = _sourceIndexForConfig(
      tfCfg,
      cfg,
      tfConfigIndex,
      eeg.channelSamples.length,
    );
    return source >= 0 ? source : 0;
  }

  List<double> _fullSignalForConfig(
    List<List<double>> channels,
    AppConfig cfg,
    int configIndex,
  ) {
    if (channels.isEmpty) return const [];
    final channelCfg = _configAt(cfg, configIndex, channels.length);
    final sourceIdx = _sourceIndexForConfig(
      channelCfg,
      cfg,
      configIndex,
      channels.length,
    );
    if (sourceIdx < 0 || sourceIdx >= channels.length) return const [];
    final refIdx = _referenceIndexForConfig(channelCfg, cfg, channels.length);
    if (refIdx == null && !channelCfg.flipPolarity) {
      return channels[sourceIdx];
    }
    return _displaySegmentForChannel(
      channels,
      1.0,
      0,
      channels[sourceIdx].length,
      channelCfg,
      cfg,
      applyFilters: false,
    );
  }

  ({
    List<int> indices,
    List<String> labels,
    List<String> colors,
    List<ChannelConfig> configs,
  })
  _visibleChannelProjection(LoadedEeg eeg, AppConfig cfg) {
    final indices = <int>[];
    final labels = <String>[];
    final colors = <String>[];
    final configs = <ChannelConfig>[];
    final channelConfigs = cfg.channels.isEmpty
        ? [
            for (var i = 0; i < eeg.channelSamples.length; i++)
              AppConfig._defaultChannelConfig(
                eeg.channelLabels[i],
                i,
                eeg.channelSamples.length,
              ),
          ]
        : cfg.channels;

    for (var i = 0; i < channelConfigs.length; i++) {
      final channelCfg = channelConfigs[i];
      if (!channelCfg.displayOnScreen) continue;
      final sourceIdx = _sourceIndexForConfig(
        channelCfg,
        cfg,
        i,
        eeg.channelSamples.length,
      );
      if (sourceIdx < 0 || sourceIdx >= eeg.channelSamples.length) continue;
      indices.add(sourceIdx);
      labels.add(
        channelCfg.name.isNotEmpty
            ? channelCfg.name
            : eeg.channelLabels[sourceIdx],
      );
      colors.add(
        channelCfg.color.isNotEmpty
            ? channelCfg.color
            : _defaultChannelColorName(eeg.channelLabels[sourceIdx]),
      );
      configs.add(channelCfg);
    }
    if (indices.isEmpty && eeg.channelSamples.isNotEmpty) {
      final fallback = channelConfigs.isNotEmpty
          ? channelConfigs.first
          : AppConfig._defaultChannelConfig(
              eeg.channelLabels.first,
              0,
              eeg.channelSamples.length,
            );
      indices.add(0);
      labels.add(
        fallback.name.isNotEmpty ? fallback.name : eeg.channelLabels.first,
      );
      colors.add(fallback.color);
      configs.add(fallback);
    }
    return (indices: indices, labels: labels, colors: colors, configs: configs);
  }

  ChannelConfig _configForRawChannel(
    int rawIndex,
    AppConfig cfg,
    int channelCount,
  ) {
    for (final channel in cfg.channels) {
      if (channel.sourceIndex == rawIndex) return channel;
    }
    if (rawIndex >= 0 && rawIndex < cfg.channels.length) {
      return cfg.channels[rawIndex];
    }
    return ChannelConfig(
      name: 'Channel ${rawIndex + 1}',
      sourceIndex: rawIndex.clamp(0, math.max(0, channelCount - 1)).toInt(),
    );
  }

  int _sourceIndexForConfig(
    ChannelConfig channelCfg,
    AppConfig cfg,
    int fallbackIndex,
    int channelCount,
  ) {
    final explicit = channelCfg.sourceIndex;
    if (explicit != null && explicit >= 0 && explicit < channelCount) {
      return explicit;
    }
    final sourceName = channelCfg.derived
        ? (channelCfg.sourceChannel ?? channelCfg.name)
        : channelCfg.name;
    final byName = cfg.channels.indexWhere((c) => c.name == sourceName);
    if (byName >= 0) {
      final mapped = cfg.channels[byName].sourceIndex;
      if (mapped != null && mapped >= 0 && mapped < channelCount) return mapped;
      if (byName < channelCount) return byName;
    }
    return fallbackIndex < channelCount ? fallbackIndex : -1;
  }

  int? _referenceIndexForConfig(
    ChannelConfig channelCfg,
    AppConfig cfg,
    int channelCount,
  ) {
    final refName = channelCfg.reReference;
    if (refName == 'None' || refName.isEmpty) return null;
    final refConfigIndex = cfg.channels.indexWhere((c) => c.name == refName);
    if (refConfigIndex < 0) return null;
    final refCfg = cfg.channels[refConfigIndex];
    final sourceIdx = _sourceIndexForConfig(
      refCfg,
      cfg,
      refConfigIndex,
      channelCount,
    );
    return sourceIdx >= 0 && sourceIdx < channelCount ? sourceIdx : null;
  }

  String _channelConfigSignature(ChannelConfig c) {
    return [
      c.name,
      c.sourceIndex,
      c.derived,
      c.sourceChannel,
      c.color,
      c.scalingFactor.toStringAsFixed(2),
      c.verticalShift.toStringAsFixed(2),
      c.flipPolarity,
      c.displayOnScreen,
      c.reReference,
      c.filterHpEnabled,
      c.filterHpCutoff.toStringAsFixed(2),
      c.filterHpOrder,
      c.filterLpEnabled,
      c.filterLpCutoff.toStringAsFixed(2),
      c.filterLpOrder,
      c.filterNotchEnabled,
      c.filterNotchCutoff.toStringAsFixed(2),
      c.filterNotchOrder,
    ].join(',');
  }

  List<double> _displaySegmentForChannel(
    List<List<double>> channels,
    double sampleRate,
    int start,
    int end,
    ChannelConfig channelCfg,
    AppConfig cfg, {
    required bool applyFilters,
  }) {
    if (channels.isEmpty || start >= end) return const [];
    final sourceIdx = _sourceIndexForConfig(
      channelCfg,
      cfg,
      channelCfg.sourceIndex ?? 0,
      channels.length,
    );
    if (sourceIdx < 0 || sourceIdx >= channels.length) return const [];
    final source = channels[sourceIdx];
    final safeEnd = math.min(end, source.length);
    if (start >= safeEnd) return const [];
    final refIdx = _referenceIndexForConfig(channelCfg, cfg, channels.length);
    final ref = refIdx == null ? null : channels[refIdx];
    final segment = List<double>.generate(safeEnd - start, (offset) {
      final idx = start + offset;
      var value = source[idx];
      if (ref != null && idx < ref.length) {
        value -= ref[idx];
      }
      if (channelCfg.flipPolarity) value = -value;
      return value;
    }, growable: false);
    if (!applyFilters || !_hasDisplayFilter(channelCfg)) return segment;
    return _applyDisplayFilters(segment, sampleRate, channelCfg);
  }

  bool _hasDisplayFilter(ChannelConfig cfg) {
    return cfg.filterHpEnabled || cfg.filterLpEnabled || cfg.filterNotchEnabled;
  }

  List<double> _applyDisplayFilters(
    List<double> signal,
    double sampleRate,
    ChannelConfig cfg,
  ) {
    if (signal.length < 8 || sampleRate <= 0) return signal;
    final nyquist = sampleRate / 2.0;

    final List<sp.BiquadSection> sos = [];

    if (cfg.filterHpEnabled &&
        cfg.filterHpCutoff > 0 &&
        cfg.filterHpCutoff < nyquist) {
      sos.addAll(
        sp.designCheby2SOS(
          order: cfg.filterHpOrder,
          rs: 60.0,
          cutoff: cfg.filterHpCutoff,
          sampleRate: sampleRate,
          btype: 'highpass',
        ),
      );
    }

    if (cfg.filterLpEnabled &&
        cfg.filterLpCutoff > 0 &&
        cfg.filterLpCutoff < nyquist) {
      sos.addAll(
        sp.designCheby2SOS(
          order: cfg.filterLpOrder,
          rs: 60.0,
          cutoff: cfg.filterLpCutoff,
          sampleRate: sampleRate,
          btype: 'lowpass',
        ),
      );
    }

    if (cfg.filterNotchEnabled &&
        cfg.filterNotchCutoff > 1.0 &&
        cfg.filterNotchCutoff < nyquist - 1.0) {
      sos.addAll(
        sp.designCheby2SOS(
          order: cfg.filterNotchOrder,
          rs: 60.0,
          cutoff: cfg.filterNotchCutoff,
          sampleRate: sampleRate,
          btype: 'bandstop',
        ),
      );
    }

    if (sos.isEmpty) return signal;
    return _applyZeroPhaseSOS(signal, sos);
  }

  List<double> _applyZeroPhaseSOS(
    List<double> input,
    List<sp.BiquadSection> sos,
  ) {
    var output = List<double>.from(input);
    for (final section in sos) {
      output = _applyBiquadSection(output, section);
    }
    output = output.reversed.toList(growable: false);
    for (final section in sos) {
      output = _applyBiquadSection(output, section);
    }
    return output.reversed.toList(growable: false);
  }

  List<double> _applyBiquadSection(List<double> input, sp.BiquadSection c) {
    final out = List<double>.filled(input.length, 0.0, growable: false);
    final x0 = input.first;
    final num = c.b0 + c.b1 + c.b2;
    final den = 1.0 + c.a1 + c.a2;
    final G = den.abs() > 1e-12 ? (num / den) : 0.0;

    double s1 = (G - c.b0) * x0;
    double s2 = (c.b2 - c.a2 * G) * x0;

    for (var i = 0; i < input.length; i++) {
      final x = input[i];
      final y = c.b0 * x + s1;
      out[i] = y;
      s1 = c.b1 * x - c.a1 * y + s2;
      s2 = c.b2 * x - c.a2 * y;
    }
    return out;
  }

  ({double median, double iqr}) _robustStats(
    List<double> values,
    int start,
    int end,
  ) {
    if (start >= end) return (median: 0.0, iqr: 1.0);
    final sampled = <double>[];
    final step = math.max(1, ((end - start) / 512).floor());
    for (var i = start; i < end; i += step) {
      sampled.add(values[i]);
    }
    sampled.sort();
    final q1 =
        sampled[(sampled.length * 0.25).floor().clamp(0, sampled.length - 1)];
    final med =
        sampled[(sampled.length * 0.50).floor().clamp(0, sampled.length - 1)];
    final q3 =
        sampled[(sampled.length * 0.75).floor().clamp(0, sampled.length - 1)];
    final iqr = math.max(q3 - q1, 1e-6);
    return (median: med, iqr: iqr);
  }

  String _defaultChannelColorName(String label) {
    final upper = label.toUpperCase();
    if (upper.contains('EOG')) return 'Blue';
    if (upper.contains('ECG')) return 'Magenta';
    if (upper.contains('EMG')) return 'Orange';
    return 'Black';
  }

  Future<List<List<double>>> _timeFrequencyForEpoch(
    LoadedEeg eeg,
    int epoch,
    AppConfig cfg,
  ) async {
    if (eeg.channelSamples.isEmpty || eeg.tfFreqs.isEmpty) return const [];

    const epochSeconds = 30;
    const extensionSec = 5.0;
    final safeEpoch = epoch.clamp(
      0,
      math.max(0, (eeg.durationSeconds / epochSeconds).ceil() - 1),
    );
    final tfConfigIndex = _clampConfigIndex(cfg.tfChannelIndex, cfg);
    final tfCh = _tfSourceIndex(eeg, cfg);
    final tfCfg = _configAt(cfg, tfConfigIndex, eeg.channelSamples.length);
    final signal = _fullSignalForConfig(eeg.channelSamples, cfg, tfConfigIndex);
    final srate = eeg.sampleRateHz;
    final cacheKey = [
      identityHashCode(eeg),
      safeEpoch,
      tfCh,
      srate.toStringAsFixed(3),
      eeg.tfFreqs.length,
      eeg.tfFreqs.first.toStringAsFixed(3),
      eeg.tfFreqs.last.toStringAsFixed(3),
      cfg.tfDisplayMode,
      cfg.tfFrequencyScale,
      _channelConfigSignature(tfCfg),
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
    final tfFreqs = List<double>.from(eeg.tfFreqs, growable: false);
    final rawPower = await Isolate.run(
      () => _isolateComputeMorletTf(slice, srate, tfFreqs),
    );
    final logPower = sp.log10TfPower(rawPower);

    List<List<double>> tfPower;
    if (cfg.tfDisplayMode == 'Raw Power' ||
        cfg.tfDisplayMode == 'L2-Normalized Power') {
      tfPower = logPower;
    } else if (cfg.tfDisplayMode == 'dB (median baseline)') {
      tfPower = <List<double>>[];
      for (var f = 0; f < logPower.length; f++) {
        final med = f < eeg.tfNormMedian.length ? eeg.tfNormMedian[f] : 0.0;
        tfPower.add([for (final v in logPower[f]) 10.0 * (v - med)]);
      }
    } else {
      // Z-Standardized Power
      tfPower = sp.zScoreTfPower(logPower, eeg.tfNormMedian, eeg.tfNormIqr);
    }

    _rememberCacheValue(_tfCache, _tfCacheOrder, cacheKey, tfPower, 30);
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
    return EegViewport(
      sampleRateHz: 256,
      epochSeconds: 30,
      channelLabels: const [],
      points: const [],
      stages: const [],
      stagesUncertain: const [],
      currentEpoch: 0,
      visibleStartSeconds: 0,
      visibleDurationSeconds: 30,
      totalDurationSeconds: 30,
      sourceDescription: 'No EDF file loaded',
    );
  }

  EegViewport _fromNative(_NativeViewport native) {
    final channelWaves = List.generate(native.channelCount, (_) => <double>[]);
    for (var index = 0; index < native.pointCount; index++) {
      final point = (native.points + index).ref;
      channelWaves[point.channel.clamp(0, native.channelCount - 1)].add(
        point.y,
      );
    }
    final pointsList = channelWaves
        .map((l) => Float32List.fromList(l))
        .toList();
    return EegViewport(
      sampleRateHz: native.sampleRateHz,
      epochSeconds: native.epochSeconds,
      channelLabels: [
        for (var i = 0; i < native.channelCount; i++) 'Ch ${i + 1}',
      ],
      points: pointsList,
      stages: const [
        SleepStage.wake,
        SleepStage.n1,
        SleepStage.n2,
        SleepStage.n3,
        SleepStage.rem,
      ],
      stagesUncertain: List<bool>.filled(5, false),
      currentEpoch: 0,
      visibleStartSeconds: 0,
      visibleDurationSeconds: 30,
      totalDurationSeconds: 150,
      sourceDescription: 'Rust FFI viewport',
    );
  }

  Future<ui.Image> _tfPowerToImage(
    List<List<double>> tfPower,
    double minVal,
    double maxVal,
  ) {
    final nFreqs = tfPower.length;
    final nTimes = tfPower.isNotEmpty ? tfPower[0].length : 0;
    if (nFreqs == 0 || nTimes == 0) {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        Uint8List.fromList([0, 0, 0, 0]),
        1,
        1,
        ui.PixelFormat.rgba8888,
        (ui.Image img) => completer.complete(img),
      );
      return completer.future;
    }

    final pixels = Uint8List(nFreqs * nTimes * 4);
    var pixelIdx = 0;

    for (var f = 0; f < nFreqs; f++) {
      final flipF = nFreqs - 1 - f;
      final row = tfPower[flipF];
      for (var t = 0; t < nTimes; t++) {
        final val = row[t];
        final norm = ((val - minVal) / (maxVal - minVal)).clamp(0.0, 1.0);
        final idx = (norm * 255).round();
        final color = sp.spectral[idx];
        final argb = color.toARGB32();
        pixels[pixelIdx++] = (argb >> 16) & 0xFF;
        pixels[pixelIdx++] = (argb >> 8) & 0xFF;
        pixels[pixelIdx++] = argb & 0xFF;
        pixels[pixelIdx++] = 255;
      }
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      nTimes,
      nFreqs,
      ui.PixelFormat.rgba8888,
      (ui.Image img) => completer.complete(img),
    );
    return completer.future;
  }

  Future<ui.Image> _spectrogramPowerToImage(
    List<List<double>> power,
    List<double> freqs,
    double colorMin,
    double colorMax,
  ) {
    final nEpochs = power.length;
    const maxDisplayHz = 45.0;
    int nFreqDisplay = freqs.length;
    for (var i = 0; i < freqs.length; i++) {
      if (freqs[i] > maxDisplayHz) {
        nFreqDisplay = i;
        break;
      }
    }
    if (nFreqDisplay == 0) nFreqDisplay = freqs.length;

    if (nEpochs == 0 || nFreqDisplay == 0) {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        Uint8List.fromList([0, 0, 0, 0]),
        1,
        1,
        ui.PixelFormat.rgba8888,
        (ui.Image img) => completer.complete(img),
      );
      return completer.future;
    }

    final pixels = Uint8List(nFreqDisplay * nEpochs * 4);
    var pixelIdx = 0;

    for (var r = 0; r < nFreqDisplay; r++) {
      final f = nFreqDisplay - 1 - r;
      for (var e = 0; e < nEpochs; e++) {
        final rawPsd = power[e][f];
        final logPsd = rawPsd > 0 ? math.log(rawPsd) / math.ln10 : colorMin;
        final t = ((logPsd - colorMin) / (colorMax - colorMin)).clamp(0.0, 1.0);
        final idx = (t * 255).round();
        final color = sp.cividis[idx];
        final argb = color.toARGB32();
        pixels[pixelIdx++] = (argb >> 16) & 0xFF;
        pixels[pixelIdx++] = (argb >> 8) & 0xFF;
        pixels[pixelIdx++] = argb & 0xFF;
        pixels[pixelIdx++] = 255;
      }
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      nEpochs,
      nFreqDisplay,
      ui.PixelFormat.rgba8888,
      (ui.Image img) => completer.complete(img),
    );
    return completer.future;
  }
}

// ─── Top-Level Isolate Functions ─────────────────────────────────────────────

List<List<double>> _isolateComputeMorletTf(
  List<double> slice,
  double srate,
  List<double> freqs,
) {
  _ComputeMorletDart? computeMorlet;
  _FreeMorletDart? freeMorlet;

  try {
    final library = _openDynamicLibrary();
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

class _SpectrogramResultData {
  _SpectrogramResultData(this.power, this.freqs);
  final List<List<double>> power;
  final List<double> freqs;
}

_SpectrogramResultData _isolateComputeSpectrogram(
  List<double> signal,
  double srate,
  int epochSeconds,
  int extensionSeconds,
) {
  _ComputeSpectrogramDart? computeSpectrogram;
  _FreeSpectrogramDart? freeSpectrogram;

  try {
    final library = _openDynamicLibrary();
    computeSpectrogram = library.lookupFunction<
        _ComputeSpectrogramNative, _ComputeSpectrogramDart>(
      'sleep_eeg_compute_welch_spectrogram',
    );
    freeSpectrogram = library.lookupFunction<
        _FreeSpectrogramNative, _FreeSpectrogramDart>(
      'sleep_eeg_free_spectrogram',
    );
  } catch (_) {
    // Fallback to Dart
  }

  if (computeSpectrogram != null && freeSpectrogram != null) {
    final signalPtr = calloc<Float>(signal.length);
    for (var i = 0; i < signal.length; i++) {
      signalPtr[i] = signal[i];
    }

    final resultPtr = computeSpectrogram(
      signalPtr,
      signal.length,
      srate,
      epochSeconds,
      extensionSeconds,
    );

    calloc.free(signalPtr);

    if (resultPtr != nullptr) {
      final res = resultPtr.ref;
      final power = List.generate(res.nEpochs, (i) {
        final row = <double>[];
        for (var j = 0; j < res.nFreqs; j++) {
          row.add(res.power[i * res.nFreqs + j]);
        }
        return row;
      });

      final freqs = <double>[];
      for (var i = 0; i < res.nFreqs; i++) {
        freqs.add(res.freqs[i]);
      }

      freeSpectrogram(resultPtr);
      return _SpectrogramResultData(power, freqs);
    }
  }

  if (extensionSeconds > 0) {
    final (:power, :freqs) = sp.computeSpectrogram([signal], srate, epochSeconds, 0);
    return _SpectrogramResultData(power, freqs);
  } else {
    final power = sp.precomputeEpochPeriodograms([signal], srate, epochSeconds, 0);
    final slice = signal.sublist(0, math.min(signal.length, (epochSeconds * srate).round()));
    final (_, freqs) = sp.welchPsd(slice, srate);
    return _SpectrogramResultData(power, freqs);
  }
}

