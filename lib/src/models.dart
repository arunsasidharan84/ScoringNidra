// lib/src/models.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

/// Sleep stage codes matching the Python ScoringHero digit encoding:
///   Wake=1, REM=0, N1=-1, N2=-2, N3=-3, Inconclusive=2, None/unknown=null
enum SleepStage {
  wake('Wake', 1),
  rem('REM', 0),
  n1('N1', -1),
  n2('N2', -2),
  n3('N3', -3),
  inconclusive('Inconclusive', 2),
  unknown('?', -99); // unscored

  const SleepStage(this.label, this.code);

  final String label;
  final int code; // matches Python's digit encoding

  /// Return true if this epoch has been scored by a human.
  bool get isScored => this != SleepStage.unknown;

  /// Short display string for epoch label.
  String get shortLabel {
    switch (this) {
      case SleepStage.wake:
        return 'W';
      case SleepStage.rem:
        return 'REM';
      case SleepStage.n1:
        return 'N1';
      case SleepStage.n2:
        return 'N2';
      case SleepStage.n3:
        return 'N3';
      case SleepStage.inconclusive:
        return '?';
      case SleepStage.unknown:
        return '-';
    }
  }

  static SleepStage fromCode(int code) {
    return SleepStage.values.firstWhere(
      (s) => s.code == code,
      orElse: () => SleepStage.unknown,
    );
  }

  /// Parse from ScoringHero JSON "stage" string field.
  static SleepStage fromLabel(String? label) {
    switch (label) {
      case 'Wake':
        return SleepStage.wake;
      case 'N1':
        return SleepStage.n1;
      case 'N2':
        return SleepStage.n2;
      case 'N3':
        return SleepStage.n3;
      case 'REM':
        return SleepStage.rem;
      case 'Inconclusive':
        return SleepStage.inconclusive;
      default:
        return SleepStage.unknown;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class DisplayPoint {
  const DisplayPoint({required this.x, required this.y, required this.channel});
  final double x; // normalised 0..1 within visible window
  final double y; // normalised 0..1 within panel height
  final int channel;
}

// ─────────────────────────────────────────────────────────────────────────────

class EventSelection {
  const EventSelection({
    required this.startSec,
    required this.endSec,
    required this.channel,
    required this.startUv,
    required this.endUv,
    required this.peakToPeakUv,
  });

  final double startSec;
  final double endSec;
  final int channel;
  final double startUv;
  final double endUv;
  final double peakToPeakUv;

  double get durationSeconds => (endSec - startSec).abs();
}

// ─────────────────────────────────────────────────────────────────────────────

class ScoredEvent {
  const ScoredEvent({
    required this.digit,
    required this.key,
    required this.label,
    required this.startSec,
    required this.endSec,
  });

  final int digit;
  final String key;
  final String label;
  final double startSec;
  final double endSec;

  double get durationSeconds => (endSec - startSec).abs();

  List<int> epochs(int epochSeconds, int epochCount) {
    final s = startSec < endSec ? startSec : endSec;
    final e = startSec < endSec ? endSec : startSec;
    final first = (s / epochSeconds).floor().clamp(0, epochCount - 1);
    final last = ((e - 1e-9) / epochSeconds).floor().clamp(0, epochCount - 1);
    return [for (var i = first; i <= last; i++) i];
  }
}

// ─────────────────────────────────────────────────────────────────────────────

/// All night-level data cached after EDF/MAT load.
/// Heavy arrays (spectrogram, periodograms) live here so they are computed
/// once and referenced (not copied) by each [EegViewport].
class LoadedEeg {
  const LoadedEeg({
    required this.sampleRateHz,
    required this.channelLabels,
    required this.channelSamples,
    required this.sourceDescription,
    // Night-level signal processing products
    this.spectrogramPower = const [],
    this.spectrogramFreqs = const [],
    this.swaPerEpoch = const [],
    this.epochPeriodograms = const [],
    this.epochTfPower = const [],
    this.tfFreqs = const [],
    this.tfNormMedian = const [],
    this.tfNormIqr = const [],
    this.spectrogramChannelIndex = 0,
    this.spectrogramImage,
  });

  final double sampleRateHz;
  final List<String> channelLabels;
  final List<List<double>> channelSamples;
  final String sourceDescription;

  // ─── Night-level spectrogram (epochs × freqs) ───────────────────────────
  final List<List<double>>
  spectrogramPower; // log10 power displayed in spectrogram
  final List<double> spectrogramFreqs; // frequency bins (Hz)
  final List<double> swaPerEpoch; // mean 0.5–4 Hz power per epoch
  final List<List<double>>
  epochPeriodograms; // per-epoch Welch PSD (power spectrum panel)
  final int spectrogramChannelIndex; // which channel drives the spectrogram
  final ui.Image? spectrogramImage;

  // ─── Pre-computed Morlet TF (all epochs at load time) ───────────────────
  /// Shape: epochCount × nFreqs × nSamples (z-scored log10 power).
  /// Pre-computed at load time so navigation is O(1). Empty until loaded.
  final List<List<List<double>>> epochTfPower;

  // ─── TF normalisation stats (per TF frequency bin) ──────────────────────
  final List<double> tfFreqs; // geomspace 0.25–45 Hz, 120 points
  final List<double> tfNormMedian; // night-wide log10 power median per TF freq
  final List<double> tfNormIqr; // night-wide log10 power IQR per TF freq

  double get durationSeconds {
    if (channelSamples.isEmpty || sampleRateHz <= 0) return 0;
    return channelSamples.first.length / sampleRateHz;
  }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Per-epoch display viewport — immutable value object passed to all painters.
class EegViewport {
  const EegViewport({
    required this.sampleRateHz,
    required this.epochSeconds,
    required this.channelLabels,
    required this.points,
    required this.stages,
    this.stagesUncertain = const [],
    required this.currentEpoch,
    required this.visibleStartSeconds,
    required this.visibleDurationSeconds,
    required this.totalDurationSeconds,
    required this.sourceDescription,
    // Night-level data (references, not copies)
    this.spectrogramPower = const [],
    this.spectrogramFreqs = const [],
    this.swaPerEpoch = const [],
    this.tfFreqs = const [],
    this.tfNormMedian = const [],
    this.tfNormIqr = const [],
    this.spectrogramChannelIndex = 0,
    this.spectrogramImage,
    // Per-epoch data
    this.currentEpochPeriodogram = const [],
    this.periodogramFreqs = const [],
    this.tfPower = const [], // nFreqs × nSamples Morlet power (log10, z-scored)
    this.tfImage,
    this.periodogramChannelIndex = 0,
    this.tfChannelIndex = 0,
    this.amplitudeRangeUv = 75.0,
    this.referenceAmplitudeLineUv = 37.5,
    this.selectionStartSec,
    this.selectionEndSec,
    this.selectionChannel,
    this.selectionStartUv,
    this.selectionEndUv,
    this.selectionPeakToPeakUv,
    this.eventSelections = const [],
    this.scoredEvents = const [],
    this.visibleChannelLabels = const [],
    this.visibleChannelSourceIndices = const [],
    this.visibleChannelColors = const [],
    this.tfDisplayMode = 'dB (median baseline)',
    this.tfPowerMin = 0.0,
    this.tfPowerMax = 20.0,
    this.periodogramFreqMin = 4.0,
    this.periodogramFreqMax = 45.0,
    this.periodogramDisplayMode = '1/f Removed',
  });

  final double sampleRateHz;
  final int epochSeconds;
  final List<String> channelLabels;
  final List<Float32List> points;
  final List<SleepStage> stages;
  final List<bool> stagesUncertain;
  final int currentEpoch;
  final double visibleStartSeconds;
  final double visibleDurationSeconds;
  final double totalDurationSeconds;
  final String sourceDescription;

  // Night-level references
  final List<List<double>> spectrogramPower;
  final List<double> spectrogramFreqs;
  final List<double> swaPerEpoch;
  final List<double> tfFreqs;
  final List<double> tfNormMedian;
  final List<double> tfNormIqr;
  final int spectrogramChannelIndex;
  final ui.Image? spectrogramImage;

  // Per-epoch computed data
  final List<double> currentEpochPeriodogram;
  final List<double> periodogramFreqs;
  final List<List<double>> tfPower; // shape: nFreqs × nSamples, z-scored log10
  final ui.Image? tfImage;
  final int periodogramChannelIndex;
  final int tfChannelIndex;
  final double amplitudeRangeUv;
  final double referenceAmplitudeLineUv;
  final String tfDisplayMode;
  final double tfPowerMin;
  final double tfPowerMax;
  final double periodogramFreqMin;
  final double periodogramFreqMax;
  final String periodogramDisplayMode;

  // Selection
  final double? selectionStartSec;
  final double? selectionEndSec;
  final int? selectionChannel;
  final double? selectionStartUv;
  final double? selectionEndUv;
  final double? selectionPeakToPeakUv;
  final List<EventSelection> eventSelections;
  final List<ScoredEvent> scoredEvents;
  final List<String> visibleChannelLabels;
  final List<int> visibleChannelSourceIndices;
  final List<String> visibleChannelColors;

  int get epochCount => stages.length;
  List<String> get signalChannelLabels =>
      visibleChannelLabels.isNotEmpty ? visibleChannelLabels : channelLabels;
  List<int> get signalChannelSourceIndices =>
      visibleChannelSourceIndices.isNotEmpty
      ? visibleChannelSourceIndices
      : [for (var i = 0; i < channelLabels.length; i++) i];
  List<String> get signalChannelColors => visibleChannelColors.isNotEmpty
      ? visibleChannelColors
      : [for (var i = 0; i < signalChannelLabels.length; i++) 'Black'];
  int get channelCount => signalChannelLabels.length;

  SleepStage get currentStage =>
      currentEpoch < stages.length ? stages[currentEpoch] : SleepStage.unknown;

  EegViewport copyWith({
    List<SleepStage>? stages,
    List<bool>? stagesUncertain,
    int? currentEpoch,
    List<Float32List>? points,
    double? visibleStartSeconds,
    double? visibleDurationSeconds,
    List<double>? currentEpochPeriodogram,
    List<double>? periodogramFreqs,
    List<List<double>>? tfPower,
    ui.Image? tfImage,
    int? periodogramChannelIndex,
    int? tfChannelIndex,
    double? amplitudeRangeUv,
    double? referenceAmplitudeLineUv,
    double? selectionStartSec,
    double? selectionEndSec,
    int? selectionChannel,
    double? selectionStartUv,
    double? selectionEndUv,
    double? selectionPeakToPeakUv,
    List<EventSelection>? eventSelections,
    List<ScoredEvent>? scoredEvents,
    List<String>? visibleChannelLabels,
    List<int>? visibleChannelSourceIndices,
    List<String>? visibleChannelColors,
    bool clearSelection = false,
    bool clearEventSelections = false,
    String? tfDisplayMode,
    double? tfPowerMin,
    double? tfPowerMax,
    double? periodogramFreqMin,
    double? periodogramFreqMax,
    String? periodogramDisplayMode,
    ui.Image? spectrogramImage,
    bool clearSpectrogramImage = false,
    bool clearTfImage = false,
  }) {
    return EegViewport(
      sampleRateHz: sampleRateHz,
      epochSeconds: epochSeconds,
      channelLabels: channelLabels,
      points: points ?? this.points,
      stages: stages ?? this.stages,
      stagesUncertain: stagesUncertain ?? this.stagesUncertain,
      currentEpoch: currentEpoch ?? this.currentEpoch,
      visibleStartSeconds: visibleStartSeconds ?? this.visibleStartSeconds,
      visibleDurationSeconds:
          visibleDurationSeconds ?? this.visibleDurationSeconds,
      totalDurationSeconds: totalDurationSeconds,
      sourceDescription: sourceDescription,
      spectrogramPower: spectrogramPower,
      spectrogramFreqs: spectrogramFreqs,
      swaPerEpoch: swaPerEpoch,
      tfFreqs: tfFreqs,
      tfNormMedian: tfNormMedian,
      tfNormIqr: tfNormIqr,
      spectrogramChannelIndex: spectrogramChannelIndex,
      spectrogramImage: clearSpectrogramImage
          ? null
          : (spectrogramImage ?? this.spectrogramImage),
      currentEpochPeriodogram:
          currentEpochPeriodogram ?? this.currentEpochPeriodogram,
      periodogramFreqs: periodogramFreqs ?? this.periodogramFreqs,
      tfPower: tfPower ?? this.tfPower,
      tfImage: clearTfImage ? null : (tfImage ?? this.tfImage),
      periodogramChannelIndex:
          periodogramChannelIndex ?? this.periodogramChannelIndex,
      tfChannelIndex: tfChannelIndex ?? this.tfChannelIndex,
      amplitudeRangeUv: amplitudeRangeUv ?? this.amplitudeRangeUv,
      referenceAmplitudeLineUv:
          referenceAmplitudeLineUv ?? this.referenceAmplitudeLineUv,
      selectionStartSec: clearSelection
          ? null
          : (selectionStartSec ?? this.selectionStartSec),
      selectionEndSec: clearSelection
          ? null
          : (selectionEndSec ?? this.selectionEndSec),
      selectionChannel: clearSelection
          ? null
          : (selectionChannel ?? this.selectionChannel),
      selectionStartUv: clearSelection
          ? null
          : (selectionStartUv ?? this.selectionStartUv),
      selectionEndUv: clearSelection
          ? null
          : (selectionEndUv ?? this.selectionEndUv),
      selectionPeakToPeakUv: clearSelection
          ? null
          : (selectionPeakToPeakUv ?? this.selectionPeakToPeakUv),
      eventSelections: clearEventSelections
          ? const []
          : (eventSelections ?? this.eventSelections),
      scoredEvents: scoredEvents ?? this.scoredEvents,
      visibleChannelLabels: visibleChannelLabels ?? this.visibleChannelLabels,
      visibleChannelSourceIndices:
          visibleChannelSourceIndices ?? this.visibleChannelSourceIndices,
      visibleChannelColors: visibleChannelColors ?? this.visibleChannelColors,
      tfDisplayMode: tfDisplayMode ?? this.tfDisplayMode,
      tfPowerMin: tfPowerMin ?? this.tfPowerMin,
      tfPowerMax: tfPowerMax ?? this.tfPowerMax,
      periodogramFreqMin: periodogramFreqMin ?? this.periodogramFreqMin,
      periodogramFreqMax: periodogramFreqMax ?? this.periodogramFreqMax,
      periodogramDisplayMode:
          periodogramDisplayMode ?? this.periodogramDisplayMode,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class ChannelConfig {
  ChannelConfig({
    required this.name,
    this.sourceIndex,
    this.derived = false,
    this.sourceChannel,
    this.color = 'Black',
    this.displayOnScreen = true,
    this.scalingFactor = 100.0,
    this.verticalShift = 0.0,
    this.reReference = 'None',
    this.flipPolarity = false,
    this.filterHpEnabled = false,
    this.filterHpCutoff = 0.3,
    this.filterHpOrder = 4,
    this.filterLpEnabled = false,
    this.filterLpCutoff = 50.0,
    this.filterLpOrder = 4,
    this.filterNotchEnabled = false,
    this.filterNotchCutoff = 50.0,
    this.filterNotchOrder = 4,
  });

  String name;
  int? sourceIndex;
  bool derived;
  String? sourceChannel;
  String color;
  bool displayOnScreen;
  double scalingFactor;
  double verticalShift;
  String reReference;
  bool flipPolarity;
  bool filterHpEnabled;
  double filterHpCutoff;
  int filterHpOrder;
  bool filterLpEnabled;
  double filterLpCutoff;
  int filterLpOrder;
  bool filterNotchEnabled;
  double filterNotchCutoff;
  int filterNotchOrder;

  Map<String, dynamic> toJson() {
    return {
      'Channel_name': name,
      if (sourceIndex != null) 'sourceIndex': sourceIndex,
      if (derived) 'derived': true,
      if (sourceChannel != null && sourceChannel!.isNotEmpty)
        'source_channel': sourceChannel,
      'Channel_color': color,
      'Display_on_screen': displayOnScreen,
      'Scaling_factor': scalingFactor,
      'Vertical_shift': verticalShift,
      'Re_reference': reReference,
      'Flip_polarity': flipPolarity,
      'Filter_hp_enabled': filterHpEnabled,
      'Filter_hp_cutoff': filterHpCutoff,
      'Filter_hp_order': filterHpOrder,
      'Filter_lp_enabled': filterLpEnabled,
      'Filter_lp_cutoff': filterLpCutoff,
      'Filter_lp_order': filterLpOrder,
      'Filter_notch_enabled': filterNotchEnabled,
      'Filter_notch_cutoff': filterNotchCutoff,
      'Filter_notch_order': filterNotchOrder,
    };
  }

  factory ChannelConfig.fromJson(Map<String, dynamic> json) {
    return ChannelConfig(
      name: json['Channel_name'] as String? ?? '',
      sourceIndex: (json['sourceIndex'] as num?)?.toInt(),
      derived: _boolValue(json['derived']),
      sourceChannel: json['source_channel'] as String?,
      color: json['Channel_color'] as String? ?? 'Black',
      displayOnScreen: json.containsKey('Display_on_screen')
          ? _boolValue(json['Display_on_screen'])
          : true,
      scalingFactor: (json['Scaling_factor'] as num?)?.toDouble() ?? 100.0,
      verticalShift: (json['Vertical_shift'] as num?)?.toDouble() ?? 0.0,
      reReference: json['Re_reference'] as String? ?? 'None',
      flipPolarity: _boolValue(json['Flip_polarity']),
      filterHpEnabled: _boolValue(json['Filter_hp_enabled']),
      filterHpCutoff: (json['Filter_hp_cutoff'] as num?)?.toDouble() ?? 0.3,
      filterHpOrder: (json['Filter_hp_order'] as num?)?.toInt() ?? 4,
      filterLpEnabled: _boolValue(json['Filter_lp_enabled']),
      filterLpCutoff: (json['Filter_lp_cutoff'] as num?)?.toDouble() ?? 50.0,
      filterLpOrder: (json['Filter_lp_order'] as num?)?.toInt() ?? 4,
      filterNotchEnabled: _boolValue(json['Filter_notch_enabled']),
      filterNotchCutoff:
          (json['Filter_notch_cutoff'] as num?)?.toDouble() ?? 50.0,
      filterNotchOrder: (json['Filter_notch_order'] as num?)?.toInt() ?? 4,
    );
  }

  ChannelConfig copy() {
    return ChannelConfig(
      name: name,
      sourceIndex: sourceIndex,
      derived: derived,
      sourceChannel: sourceChannel,
      color: color,
      displayOnScreen: displayOnScreen,
      scalingFactor: scalingFactor,
      verticalShift: verticalShift,
      reReference: reReference,
      flipPolarity: flipPolarity,
      filterHpEnabled: filterHpEnabled,
      filterHpCutoff: filterHpCutoff,
      filterHpOrder: filterHpOrder,
      filterLpEnabled: filterLpEnabled,
      filterLpCutoff: filterLpCutoff,
      filterLpOrder: filterLpOrder,
      filterNotchEnabled: filterNotchEnabled,
      filterNotchCutoff: filterNotchCutoff,
      filterNotchOrder: filterNotchOrder,
    );
  }

  static bool _boolValue(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final lower = value.toLowerCase();
      return lower == 'true' || lower == '1' || lower == 'yes';
    }
    return false;
  }
}
