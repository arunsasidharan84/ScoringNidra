// lib/src/models.dart

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
  });

  final double sampleRateHz;
  final List<String> channelLabels;
  final List<List<double>> channelSamples;
  final String sourceDescription;

  // ─── Night-level spectrogram (epochs × freqs) ───────────────────────────
  final List<List<double>> spectrogramPower; // log10 power displayed in spectrogram
  final List<double> spectrogramFreqs;       // frequency bins (Hz)
  final List<double> swaPerEpoch;            // mean 0.5–4 Hz power per epoch
  final List<List<double>> epochPeriodograms; // per-epoch Welch PSD (power spectrum panel)
  final int spectrogramChannelIndex;         // which channel drives the spectrogram

  // ─── Pre-computed Morlet TF (all epochs at load time) ───────────────────
  /// Shape: epochCount × nFreqs × nSamples (z-scored log10 power).
  /// Pre-computed at load time so navigation is O(1). Empty until loaded.
  final List<List<List<double>>> epochTfPower;

  // ─── TF normalisation stats (per TF frequency bin) ──────────────────────
  final List<double> tfFreqs;      // geomspace 0.25–45 Hz, 120 points
  final List<double> tfNormMedian; // night-wide log10 power median per TF freq
  final List<double> tfNormIqr;    // night-wide log10 power IQR per TF freq

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
    // Per-epoch data
    this.currentEpochPeriodogram = const [],
    this.periodogramFreqs = const [],
    this.tfPower = const [], // nFreqs × nSamples Morlet power (log10, z-scored)
    this.periodogramChannelIndex = 0,
    this.tfChannelIndex = 0,
    this.amplitudeRangeUv = 75.0,
    this.selectionStartSec,
    this.selectionEndSec,
  });

  final double sampleRateHz;
  final int epochSeconds;
  final List<String> channelLabels;
  final List<DisplayPoint> points;
  final List<SleepStage> stages;
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

  // Per-epoch computed data
  final List<double> currentEpochPeriodogram;
  final List<double> periodogramFreqs;
  final List<List<double>> tfPower; // shape: nFreqs × nSamples, z-scored log10
  final int periodogramChannelIndex;
  final int tfChannelIndex;
  final double amplitudeRangeUv;
  
  // Selection
  final double? selectionStartSec;
  final double? selectionEndSec;

  int get epochCount => stages.length;
  int get channelCount => channelLabels.length;

  SleepStage get currentStage =>
      currentEpoch < stages.length ? stages[currentEpoch] : SleepStage.unknown;

  EegViewport copyWith({
    List<SleepStage>? stages,
    int? currentEpoch,
    List<DisplayPoint>? points,
    double? visibleStartSeconds,
    double? visibleDurationSeconds,
    List<double>? currentEpochPeriodogram,
    List<double>? periodogramFreqs,
    List<List<double>>? tfPower,
    int? periodogramChannelIndex,
    int? tfChannelIndex,
    double? amplitudeRangeUv,
    double? selectionStartSec,
    double? selectionEndSec,
    bool clearSelection = false,
  }) {
    return EegViewport(
      sampleRateHz: sampleRateHz,
      epochSeconds: epochSeconds,
      channelLabels: channelLabels,
      points: points ?? this.points,
      stages: stages ?? this.stages,
      currentEpoch: currentEpoch ?? this.currentEpoch,
      visibleStartSeconds: visibleStartSeconds ?? this.visibleStartSeconds,
      visibleDurationSeconds: visibleDurationSeconds ?? this.visibleDurationSeconds,
      totalDurationSeconds: totalDurationSeconds,
      sourceDescription: sourceDescription,
      spectrogramPower: spectrogramPower,
      spectrogramFreqs: spectrogramFreqs,
      swaPerEpoch: swaPerEpoch,
      tfFreqs: tfFreqs,
      tfNormMedian: tfNormMedian,
      tfNormIqr: tfNormIqr,
      spectrogramChannelIndex: spectrogramChannelIndex,
      currentEpochPeriodogram: currentEpochPeriodogram ?? this.currentEpochPeriodogram,
      periodogramFreqs: periodogramFreqs ?? this.periodogramFreqs,
      tfPower: tfPower ?? this.tfPower,
      periodogramChannelIndex: periodogramChannelIndex ?? this.periodogramChannelIndex,
      tfChannelIndex: tfChannelIndex ?? this.tfChannelIndex,
      amplitudeRangeUv: amplitudeRangeUv ?? this.amplitudeRangeUv,
      selectionStartSec: clearSelection ? null : (selectionStartSec ?? this.selectionStartSec),
      selectionEndSec: clearSelection ? null : (selectionEndSec ?? this.selectionEndSec),
    );
  }
}
