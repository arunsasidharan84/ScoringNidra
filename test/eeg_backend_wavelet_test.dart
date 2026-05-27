import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:scoring_nidra/src/eeg_backend.dart';
import 'package:scoring_nidra/src/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('renders lazy wavelet image for a loaded viewport', () async {
    final backend = EegBackend();
    const sampleRate = 64.0;
    final samples = List<double>.generate((sampleRate * 36).round(), (i) {
      final t = i / sampleRate;
      return 40.0 * math.sin(2.0 * math.pi * 10.0 * t) +
          8.0 * math.sin(2.0 * math.pi * 2.0 * t);
    });
    final config = AppConfig.defaultsForChannels(const [
      'C3-M2',
    ], sampleRateHz: sampleRate)..tfFreqMax = 30.0;
    final raw = LoadedEeg(
      sampleRateHz: sampleRate,
      channelLabels: const ['C3-M2'],
      channelSamples: [samples],
      sourceDescription: 'synthetic',
    );

    final eeg = await backend.computeNightProducts(raw, config);
    final viewport = await backend.viewportFromEeg(
      eeg,
      currentEpoch: 0,
      config: config,
      includeTimeFrequency: false,
    );
    final refreshed = await backend.refreshTimeFrequencyForEpoch(
      viewport,
      eeg,
      config: config,
    );

    expect(refreshed.tfPower, isNotEmpty);
    expect(refreshed.tfPower.first, isNotEmpty);
    expect(refreshed.tfImage, isNotNull);
  });
}
