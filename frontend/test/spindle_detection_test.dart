import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/signal_processing.dart';

void main() {
  test('test detectSpindles with peak-to-peak amplitude', () {
    final sfreq = 200.0;
    final n = (sfreq * 300).round(); // 5 minutes
    final signal = List<double>.filled(n, 0.0);

    final rng = math.Random(42);
    for (var i = 0; i < n; i++) {
      final t = i / sfreq;
      signal[i] = 10.0 * math.sin(2 * math.pi * 1.0 * t) + (rng.nextDouble() - 0.5) * 8.0;
    }

    // Inject spindle of 25 uV at t=60s
    final sStart = (60.0 * sfreq).round();
    final sEnd = (61.0 * sfreq).round();
    for (var i = sStart; i < sEnd; i++) {
      final t = (i - sStart) / sfreq;
      final w = math.sin(math.pi * t / 1.0);
      signal[i] += 25.0 * w * math.sin(2 * math.pi * 12.5 * t);
    }

    // Also inject spindle of 18 uV at t=120s
    final s2Start = (120.0 * sfreq).round();
    final s2End = (121.2 * sfreq).round();
    for (var i = s2Start; i < s2End; i++) {
      final t = (i - s2Start) / sfreq;
      final w = math.sin(math.pi * t / 1.2);
      signal[i] += 18.0 * w * math.sin(2 * math.pi * 13.0 * t);
    }

    // If amin is checked against ptp or envelope*2:
    final res = detectSpindles(signal, sfreq, amin: 5.0, q: 90.0);
    print('detectSpindles with amin=5.0, q=90.0: $res');
  });
}
