// lib/src/timeline_painter.dart
//
// All CustomPainter classes for ScoringHero Flutter port.
// Ported from ScoringHero-0.2.4 widgets/:
//   SpectrogramPainter  ← spectogramWidget.py   (cividis colormap)
//   HypnogramPainter    ← hypnogramWidget.py    (double-plot: stages + SWA)
//   RectanglePowerPainter ← rectanglePower.py   (per-epoch Welch PSD)
//   TimeFrequencyPainter  ← tfWidget.py         (Morlet TF, spectral colormap)
//   TimelinePainter     ← signalWidget.py       (multi-channel EEG)
//   SelectionOverlayPainter                     (event/selection overlay)

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Stage colours matching Python HypnogramWidget
// ─────────────────────────────────────────────────────────────────────────────

const _stageColors = {
  SleepStage.wake: Color(0xFF56bf8b),
  SleepStage.rem: Color(0xFF8bbf56),
  SleepStage.n1: Color(0xFFaabcce),
  SleepStage.n2: Color(0xFF405c79),
  SleepStage.n3: Color(0xFF0b1c2c),
  SleepStage.inconclusive: Color(0xFF000000),
  SleepStage.unknown: Color(0xFF888888),
};

Color _stageColor(SleepStage s) => _stageColors[s] ?? const Color(0xFF888888);

/// Y-axis position for each stage in the hypnogram (matching Python digit encoding)
double _stageY(SleepStage s) {
  switch (s) {
    case SleepStage.wake: return 1.0;
    case SleepStage.rem: return 0.0;
    case SleepStage.n1: return -1.0;
    case SleepStage.n2: return -2.0;
    case SleepStage.n3: return -3.0;
    case SleepStage.inconclusive: return 2.0;
    case SleepStage.unknown: return 1.0;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Cividis colormap  (matches pyqtgraph's "cividis")
// 256-stop discrete lookup table — hardcoded to avoid runtime computation.
// ─────────────────────────────────────────────────────────────────────────────

final List<Color> _cividis = _buildCividis();

List<Color> _buildCividis() {
  // Control points from matplotlib cividis: [t, r, g, b] each 0–255
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
  final out = <Color>[];
  for (var i = 0; i < 256; i++) {
    int seg = 0;
    for (var s = stops.length - 1; s >= 0; s--) {
      if (i >= stops[s][0]) { seg = s; break; }
    }
    if (seg >= stops.length - 1) {
      out.add(Color.fromARGB(255, stops.last[1], stops.last[2], stops.last[3]));
      continue;
    }
    final lo = stops[seg], hi = stops[seg + 1];
    final t = (i - lo[0]) / (hi[0] - lo[0]);
    final r = (lo[1] + t * (hi[1] - lo[1])).round().clamp(0, 255);
    final g = (lo[2] + t * (hi[2] - lo[2])).round().clamp(0, 255);
    final b = (lo[3] + t * (hi[3] - lo[3])).round().clamp(0, 255);
    out.add(Color.fromARGB(255, r, g, b));
  }
  return out;
}

Color _cividisColor(double t) {
  final idx = (t.clamp(0.0, 1.0) * 255).round();
  return _cividis[idx];
}

// ─────────────────────────────────────────────────────────────────────────────
// Spectral colormap (for TF panel — matches spectral.txt in Python app)
// Approximates matplotlib "Spectral_r" reversed (cool→warm)
// ─────────────────────────────────────────────────────────────────────────────

final List<Color> _spectral = _buildSpectral();

List<Color> _buildSpectral() {
  // Control points [t*255, r, g, b] — Spectral (purple→blue→green→yellow→red)
  const stops = <List<int>>[
    [0,   94,  79, 162],  // purple
    [51,  50, 136, 189],  // blue
    [102, 102, 194, 165], // teal
    [128, 171, 221, 164], // light green
    [153, 230, 245, 152], // yellow-green
    [178, 254, 254, 189], // pale yellow
    [204, 253, 174,  97], // orange-yellow
    [229, 244, 109,  67], // orange
    [255, 158,   1,  66], // deep red
  ];
  final out = <Color>[];
  for (var i = 0; i < 256; i++) {
    int seg = 0;
    for (var s = stops.length - 1; s >= 0; s--) {
      if (i >= stops[s][0]) { seg = s; break; }
    }
    if (seg >= stops.length - 1) {
      out.add(Color.fromARGB(255, stops.last[1], stops.last[2], stops.last[3]));
      continue;
    }
    final lo = stops[seg], hi = stops[seg + 1];
    final t = (i - lo[0]) / (hi[0] - lo[0]);
    final r = (lo[1] + t * (hi[1] - lo[1])).round().clamp(0, 255);
    final g = (lo[2] + t * (hi[2] - lo[2])).round().clamp(0, 255);
    final b = (lo[3] + t * (hi[3] - lo[3])).round().clamp(0, 255);
    out.add(Color.fromARGB(255, r, g, b));
  }
  return out;
}

Color _spectralColor(double t) {
  final idx = (t.clamp(0.0, 1.0) * 255).round();
  return _spectral[idx];
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared drawing helpers
// ─────────────────────────────────────────────────────────────────────────────

final _axisTextStyle = TextStyle(
  color: Colors.black87,
  fontSize: 11,
  fontWeight: FontWeight.w500,
  fontFamily: 'sans-serif',
  background: Paint()..color = Colors.transparent,
);

final _labelTextStyle = TextStyle(
  color: Colors.white,
  fontSize: 10,
  fontWeight: FontWeight.bold,
  shadows: [Shadow(blurRadius: 2, color: Colors.black54)],
);

void _drawText(
  Canvas canvas,
  String text,
  Offset pos, {
  TextStyle? style,
  TextAlign align = TextAlign.left,
  double maxWidth = 200,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style ?? _axisTextStyle),
    textDirection: TextDirection.ltr,
    textAlign: align,
  )..layout(maxWidth: maxWidth);

  double dx = pos.dx;
  if (align == TextAlign.center) dx -= painter.width / 2;
  if (align == TextAlign.right) dx -= painter.width;

  painter.paint(canvas, Offset(dx, pos.dy - painter.height / 2));
}

// ─────────────────────────────────────────────────────────────────────────────
// Colorbar helper
// ─────────────────────────────────────────────────────────────────────────────

void _drawColorbar(
  Canvas canvas,
  Rect rect,
  Color Function(double t) colorFn,
  double minVal,
  double maxVal,
  String unit,
) {
  const nStops = 64;
  final cellH = rect.height / nStops;
  for (var i = 0; i < nStops; i++) {
    final t = 1.0 - i / (nStops - 1);
    final color = colorFn(t);
    canvas.drawRect(
      Rect.fromLTWH(rect.left, rect.top + i * cellH, rect.width, cellH + 0.5),
      Paint()..color = color,
    );
  }
  // Border
  canvas.drawRect(rect, Paint()..color = Colors.black54..style = PaintingStyle.stroke..strokeWidth = 0.5);
  // Min/max labels
  _drawText(canvas, maxVal.toStringAsFixed(1),
      Offset(rect.right + 2, rect.top + 5), align: TextAlign.left);
  _drawText(canvas, minVal.toStringAsFixed(1),
      Offset(rect.right + 2, rect.bottom - 5), align: TextAlign.left);
  if (unit.isNotEmpty) {
    _drawText(canvas, unit, Offset(rect.right + 2, rect.top + rect.height / 2),
        align: TextAlign.left);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Epoch tick marks (for X axis of spectrogram + hypnogram)
// ─────────────────────────────────────────────────────────────────────────────

/// Returns a list of (label, fractional_x) pairs for the time axis.
List<(String, double)> _timeTicks(double totalSeconds) {
  const stepOptions = [
    3600.0, 1800.0, 900.0, 600.0, 300.0, 180.0, 120.0, 60.0,
  ];
  double step = 3600.0;
  for (final s in stepOptions) {
    if (totalSeconds / s >= 2) { step = s; break; }
  }
  final ticks = <(String, double)>[];
  for (double t = step; t < totalSeconds; t += step) {
    final h = (t / 3600).floor();
    final m = ((t % 3600) / 60).round();
    final label = m == 0 ? '${h}h' : '${h}h${m.toString().padLeft(2, '0')}';
    ticks.add((label, t / totalSeconds));
  }
  return ticks;
}

// ─────────────────────────────────────────────────────────────────────────────
// 1.  SPECTROGRAM PAINTER
// ─────────────────────────────────────────────────────────────────────────────

class SpectrogramPainter extends CustomPainter {
  SpectrogramPainter(this.viewport, {this.onTapEpoch});

  final EegViewport viewport;
  final void Function(int epoch)? onTapEpoch;

  // Cache the rendered spectrogram image between repaints.
  // Only rebuilt when [_cachedDataKey] !== current power list reference.
  static ui.Picture? _cachedPicture;
  static Object? _cachedDataKey;
  static Size _cachedSize = Size.zero;

  @override
  void paint(Canvas canvas, Size size) {
    final power = viewport.spectrogramPower;
    final freqs = viewport.spectrogramFreqs;

    if (power.isEmpty || freqs.isEmpty) {
      _paintPlaceholder(canvas, size, 'Load an EDF to see spectrogram');
      return;
    }

    // Rebuild the background picture only when data or size changes
    final dataKey = power; // reference identity check
    if (_cachedPicture == null ||
        !identical(_cachedDataKey, dataKey) ||
        _cachedSize != size) {
      _cachedPicture = _buildSpectrogramPicture(size, power, freqs);
      _cachedDataKey = dataKey;
      _cachedSize = size;
    }
    canvas.drawPicture(_cachedPicture!);

    // Epoch indicator (drawn fresh each frame — cheap)
    final epochCount = power.length;
    if (epochCount > 0) {
      final x = size.width * viewport.currentEpoch / epochCount;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.5,
      );
    }

    // X axis ticks
    _drawXTicks(canvas, size);

    // Y axis label (frequency)
    _drawYAxisLabel(canvas, size, freqs);

    // Channel label
    _drawText(
      canvas,
      viewport.channelLabels.isNotEmpty
          ? viewport.channelLabels[viewport.spectrogramChannelIndex.clamp(0, viewport.channelLabels.length - 1)]
          : 'Ch 1',
      Offset(size.width / 2, 8),
      style: _labelTextStyle,
      align: TextAlign.center,
    );
  }

  ui.Picture _buildSpectrogramPicture(
    Size size,
    List<List<double>> power,
    List<double> freqs,
  ) {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);

    final nEpochs = power.length;
    // Restrict to 0–45 Hz for display
    const maxDisplayHz = 45.0;
    int nFreqDisplay = freqs.length;
    for (var i = 0; i < freqs.length; i++) {
      if (freqs[i] > maxDisplayHz) { nFreqDisplay = i; break; }
    }
    if (nFreqDisplay == 0) nFreqDisplay = freqs.length;

    // Compute global min/max for color scaling (log10 power)
    // Default: -1 to 3 (matches Python config["Spectrogram_power_limits"])
    const colorMin = -1.0;
    const colorMax = 3.0;

    final cellW = size.width / nEpochs;
    final cellH = size.height / nFreqDisplay;

    for (var e = 0; e < nEpochs; e++) {
      for (var f = 0; f < nFreqDisplay; f++) {
        final rawPsd = power[e][f];
        final logPsd = rawPsd > 0 ? math.log(rawPsd) / math.ln10 : colorMin;
        final t = ((logPsd - colorMin) / (colorMax - colorMin)).clamp(0.0, 1.0);
        c.drawRect(
          Rect.fromLTWH(
            e * cellW,
            size.height - (f + 1) * cellH, // flip Y (low freq at bottom)
            cellW + 0.5,
            cellH + 0.5,
          ),
          Paint()..color = _cividisColor(t),
        );
      }
    }

    return recorder.endRecording();
  }

  void _drawXTicks(Canvas canvas, Size size) {
    final totalSec = viewport.totalDurationSeconds;
    if (totalSec <= 0) return;
    final ticks = _timeTicks(totalSec);
    final tickPaint = Paint()..color = Colors.white70..strokeWidth = 0.5;
    for (final (label, fx) in ticks) {
      final x = size.width * fx;
      canvas.drawLine(Offset(x, size.height - 8), Offset(x, size.height), tickPaint);
      _drawText(canvas, label, Offset(x, size.height - 4),
          style: _axisTextStyle.copyWith(color: Colors.white70),
          align: TextAlign.center);
    }
  }

  void _drawYAxisLabel(Canvas canvas, Size size, List<double> freqs) {
    // Draw freq labels on left edge
    const tickHz = [0.0, 10.0, 20.0, 30.0, 40.0];
    final maxHz = freqs.isNotEmpty ? freqs.last.clamp(1.0, 45.0) : 45.0;
    for (final hz in tickHz) {
      if (hz > maxHz) continue;
      final fy = 1.0 - hz / maxHz;
      final y = fy * size.height;
      _drawText(
        canvas,
        '${hz.toInt()}',
        Offset(2, y),
        style: _axisTextStyle.copyWith(color: Colors.white70),
        align: TextAlign.left,
      );
    }
  }

  void _paintPlaceholder(Canvas canvas, Size size, String msg) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF1a1a2e));
    _drawText(canvas, msg, Offset(size.width / 2, size.height / 2),
        style: _axisTextStyle.copyWith(color: Colors.white38),
        align: TextAlign.center);
  }

  @override
  bool shouldRepaint(SpectrogramPainter old) =>
      old.viewport.currentEpoch != viewport.currentEpoch ||
      !identical(old.viewport.spectrogramPower, viewport.spectrogramPower);
}

// ─────────────────────────────────────────────────────────────────────────────
// 2.  HYPNOGRAM PAINTER  (double-plot: stage step chart + SWA overlay)
// ─────────────────────────────────────────────────────────────────────────────

class HypnogramPainter extends CustomPainter {
  HypnogramPainter(this.viewport, {this.swaKernelSize = 1});

  final EegViewport viewport;
  final int swaKernelSize; // 1 = no smoothing, up to ~101

  // Hypnogram Y axis: Wake=1, REM=0, N1=-1, N2=-2, N3=-3 (matching Python)
  static const _yMin = -4.0;
  static const _yMax = 2.5;
  static const _yRange = _yMax - _yMin;

  double _toCanvasY(double stageY, double canvasH) =>
      canvasH * (1.0 - (stageY - _yMin) / _yRange);

  @override
  void paint(Canvas canvas, Size size) {
    final stages = viewport.stages;
    if (stages.isEmpty) {
      _drawPlaceholder(canvas, size);
      return;
    }

    _drawBackground(canvas, size);
    _drawYAxisLabels(canvas, size);
    _drawHypnogramSteps(canvas, size, stages);
    _drawSwaOverlay(canvas, size);
    _drawEpochIndicator(canvas, size);
    _drawXAxisTicks(canvas, size);
  }

  void _drawBackground(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFfafafa),
    );
    // Horizontal guide lines for each stage
    const yVals = [1.0, 0.0, -1.0, -2.0, -3.0];
    final linePaint = Paint()
      ..color = const Color(0xFFDDDDDD)
      ..strokeWidth = 0.5;
    for (final y in yVals) {
      final cy = _toCanvasY(y, size.height);
      canvas.drawLine(Offset(0, cy), Offset(size.width, cy), linePaint);
    }
  }

  void _drawYAxisLabels(Canvas canvas, Size size) {
    const labels = <(double, String)>[
      (2.0, '?'),
      (1.0, 'W'),
      (0.0, 'REM'),
      (-1.0, 'N1'),
      (-2.0, 'N2'),
      (-3.0, 'N3'),
    ];
    for (final (y, label) in labels) {
      final cy = _toCanvasY(y, size.height);
      _drawText(canvas, label, Offset(2, cy), align: TextAlign.left);
    }
  }

  void _drawHypnogramSteps(Canvas canvas, Size size, List<SleepStage> stages) {
    final n = stages.length;
    if (n == 0) return;
    final epochW = size.width / n;

    for (var i = 0; i < n; i++) {
      final stage = stages[i];
      if (stage == SleepStage.unknown) continue;
      final color = _stageColor(stage);
      final y = _stageY(stage);
      final cyTop = _toCanvasY(y, size.height);
      final cyBottom = _toCanvasY(y - 0.95, size.height); // slightly less than 1.0 to leave a small gap

      final x0 = i * epochW;
      final x1 = x0 + epochW;
      canvas.drawRect(
        Rect.fromLTRB(x0, cyTop, x1, cyBottom),
        Paint()..color = color,
      );
    }
  }

  void _drawSwaOverlay(Canvas canvas, Size size) {
    final swa = viewport.swaPerEpoch;
    if (swa.isEmpty) return;

    // Apply median filter for smoothing
    final smoothed = _medianFilter(swa, swaKernelSize);

    // Normalise to hypnogram Y range [-4, 1]
    var minV = smoothed.reduce(math.min);
    var maxV = smoothed.reduce(math.max);
    final range = maxV - minV;
    if (range < 1e-10) return;

    final path = Path();
    final n = smoothed.length;
    final epochW = size.width / n;

    for (var i = 0; i < n; i++) {
      final normalised = (smoothed[i] - minV) / range;
      // Map to [-3.5, 0.5] to stay inside hypnogram bounds
      final stageY = 5.0 * normalised - 4.0;
      final cy = _toCanvasY(stageY, size.height);
      final x = (i + 0.5) * epochW;
      if (i == 0) {
        path.moveTo(x, cy);
      } else {
        path.lineTo(x, cy);
      }
    }

    // Dotted line effect — draw dashes
    final metrics = path.computeMetrics();
    final dashPaint = Paint()
      ..color = Colors.black.withOpacity(0.55)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    const dashLen = 4.0;
    const gapLen = 3.0;
    for (final metric in metrics) {
      double dist = 0;
      bool drawing = true;
      while (dist < metric.length) {
        final next = math.min(dist + (drawing ? dashLen : gapLen), metric.length);
        if (drawing) {
          canvas.drawPath(metric.extractPath(dist, next), dashPaint);
        }
        dist = next;
        drawing = !drawing;
      }
    }
  }

  List<double> _medianFilter(List<double> data, int k) {
    if (k <= 1 || data.isEmpty) return data;
    final half = k ~/ 2;
    return [
      for (var i = 0; i < data.length; i++)
        () {
          final start = math.max(0, i - half);
          final end = math.min(data.length, i + half + 1);
          final w = data.sublist(start, end).toList()..sort();
          return w[w.length ~/ 2];
        }(),
    ];
  }

  void _drawEpochIndicator(Canvas canvas, Size size) {
    final n = viewport.epochCount;
    if (n == 0) return;
    final x = size.width * viewport.currentEpoch / n;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = Colors.black
        ..strokeWidth = 1.5,
    );
  }

  void _drawXAxisTicks(Canvas canvas, Size size) {
    final totalSec = viewport.totalDurationSeconds;
    if (totalSec <= 0) return;
    final ticks = _timeTicks(totalSec);
    final tickPaint = Paint()..color = Colors.black38..strokeWidth = 0.5;
    for (final (label, fx) in ticks) {
      final x = size.width * fx;
      canvas.drawLine(Offset(x, size.height - 8), Offset(x, size.height), tickPaint);
      _drawText(canvas, label, Offset(x, size.height - 4), align: TextAlign.center);
    }
  }

  void _drawPlaceholder(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFfafafa),
    );
  }

  @override
  bool shouldRepaint(HypnogramPainter old) =>
      old.viewport.stages != viewport.stages ||
      old.viewport.currentEpoch != viewport.currentEpoch ||
      old.swaKernelSize != swaKernelSize;
}

// ─────────────────────────────────────────────────────────────────────────────
// 3.  RECTANGLE POWER PAINTER  (per-epoch Welch PSD)
// ─────────────────────────────────────────────────────────────────────────────

class RectanglePowerPainter extends CustomPainter {
  RectanglePowerPainter(this.viewport);

  final EegViewport viewport;

  @override
  void paint(Canvas canvas, Size size) {
    final psd = viewport.currentEpochPeriodogram;
    final freqs = viewport.periodogramFreqs;

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFfafafa),
    );

    if (psd.isEmpty || freqs.isEmpty) {
      _drawText(canvas, 'Power\nspectrum', Offset(size.width / 2, size.height / 2),
          align: TextAlign.center);
      return;
    }

    // Restrict display to 0–45 Hz
    const maxHz = 45.0;
    final visiblePsd = <double>[];
    final visibleFreqs = <double>[];
    for (var i = 0; i < freqs.length && i < psd.length; i++) {
      if (freqs[i] <= maxHz) {
        visibleFreqs.add(freqs[i]);
        visiblePsd.add(psd[i]);
      }
    }
    if (visiblePsd.isEmpty) return;

    // 1/f removal: divide by moving average (matching Python display mode)
    final smoothed = _movingAverage(visiblePsd, 20);
    final detrended = <double>[];
    for (var i = 0; i < visiblePsd.length; i++) {
      final s = smoothed[i] < 1e-30 ? 1e-30 : smoothed[i];
      detrended.add(visiblePsd[i] / s);
    }

    // Min-max normalise to fit canvas
    final minV = detrended.reduce(math.min);
    final maxV = detrended.reduce(math.max);
    final range = maxV - minV < 1e-20 ? 1.0 : maxV - minV;

    const pad = EdgeInsets.only(left: 4, right: 18, top: 6, bottom: 12);
    final plotW = size.width - pad.left - pad.right;
    final plotH = size.height - pad.top - pad.bottom;
    if (plotW <= 0 || plotH <= 0) return;

    final path = Path();
    for (var i = 0; i < visibleFreqs.length; i++) {
      final fx = visibleFreqs[i] / maxHz;
      final fy = 1.0 - (detrended[i] - minV) / range;
      final x = pad.left + fx * plotW;
      final y = pad.top + fy * plotH;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF0b1c2c)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );

    // X axis ticks every 5 Hz
    final tickPaint = Paint()..color = Colors.black38..strokeWidth = 0.5;
    for (var hz = 5.0; hz <= maxHz; hz += 5) {
      final x = pad.left + (hz / maxHz) * plotW;
      canvas.drawLine(
        Offset(x, pad.top + plotH),
        Offset(x, pad.top + plotH + 3),
        tickPaint,
      );
      _drawText(
        canvas,
        hz == maxHz ? '${hz.toInt()} Hz' : '${hz.toInt()}',
        Offset(x, pad.top + plotH + 6),
        align: TextAlign.center,
      );
    }

    // Channel label
    final channelName = viewport.channelLabels.isNotEmpty
        ? viewport.channelLabels[viewport.periodogramChannelIndex.clamp(0, viewport.channelLabels.length - 1)]
        : 'PSD';
    _drawText(
      canvas,
      channelName,
      Offset(size.width / 2, 5),
      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
      align: TextAlign.center,
    );
  }

  List<double> _movingAverage(List<double> data, int k) {
    if (k <= 1 || data.isEmpty) return data;
    final result = List<double>.filled(data.length, 0.0);
    double sum = 0;
    var count = 0;
    for (var i = 0; i < data.length; i++) {
      sum += data[i];
      count++;
      if (i >= k) {
        sum -= data[i - k];
        count--;
      }
      result[i] = sum / count;
    }
    return result;
  }

  @override
  bool shouldRepaint(RectanglePowerPainter old) =>
      old.viewport.currentEpoch != viewport.currentEpoch ||
      !identical(old.viewport.currentEpochPeriodogram, viewport.currentEpochPeriodogram);
}

// ─────────────────────────────────────────────────────────────────────────────
// 4.  TIME-FREQUENCY (MORLET) PAINTER
// ─────────────────────────────────────────────────────────────────────────────

class TimeFrequencyPainter extends CustomPainter {
  TimeFrequencyPainter(this.viewport);

  final EegViewport viewport;

  static ui.Picture? _cachedPicture;
  static Object? _cachedDataKey;
  static Size _cachedSize = Size.zero;

  @override
  void paint(Canvas canvas, Size size) {
    final tfPower = viewport.tfPower;
    final tfFreqs = viewport.tfFreqs;

    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0d0d1a));

    if (tfPower.isEmpty || tfFreqs.isEmpty) {
      _drawText(canvas, 'Time-Frequency (load EDF)', Offset(size.width / 2, size.height / 2),
          style: _axisTextStyle.copyWith(color: Colors.white38),
          align: TextAlign.center);
      return;
    }

    // Rebuild background image only when TF data reference changes
    final dataKey = tfPower;
    if (_cachedPicture == null ||
        !identical(_cachedDataKey, dataKey) ||
        _cachedSize != size) {
      _cachedPicture = _buildTfPicture(size, tfPower, tfFreqs);
      _cachedDataKey = dataKey;
      _cachedSize = size;
    }
    canvas.drawPicture(_cachedPicture!);

    // Y axis labels (log frequency)
    _drawYAxis(canvas, size, tfFreqs);

    // X axis ticks (time in seconds)
    _drawXAxis(canvas, size);

    // Extension epoch overlay (grey on edges — 1s each side out of 32s)
    const epochSeconds = 30.0;
    const extensionSeconds = 1.0;
    final totalSeconds = epochSeconds + 2 * extensionSeconds;
    final leftFrac = extensionSeconds / totalSeconds;
    final rightFrac = (totalSeconds - extensionSeconds) / totalSeconds;
    final overlayPaint = Paint()..color = Colors.black38;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * leftFrac, size.height),
      overlayPaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(size.width * rightFrac, 0,
          size.width * (1 - rightFrac), size.height),
      overlayPaint,
    );

    // Channel label
    final chLabel = viewport.channelLabels.isNotEmpty
        ? viewport.channelLabels[viewport.tfChannelIndex.clamp(0, viewport.channelLabels.length - 1)]
        : 'TF';
    _drawText(canvas, chLabel, Offset(size.width / 2, 6),
        style: _labelTextStyle, align: TextAlign.center);
  }

  ui.Picture _buildTfPicture(
    Size size,
    List<List<double>> tfPower,
    List<double> freqs,
  ) {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);

    final nFreqs = tfPower.length;
    final nTimes = tfPower.isNotEmpty ? tfPower[0].length : 0;
    if (nFreqs == 0 || nTimes == 0) return recorder.endRecording();

    // Color limits: z-score typically ±3
    const zMin = -2.5;
    const zMax = 2.5;

    final cellW = size.width / nTimes;
    final cellH = size.height / nFreqs;

    for (var f = 0; f < nFreqs; f++) {
      // Frequency index 0 = lowest freq (bottom of display), nFreqs-1 = highest (top)
      final flipF = nFreqs - 1 - f;
      for (var t = 0; t < nTimes; t++) {
        final val = tfPower[flipF][t];
        final norm = ((val - zMin) / (zMax - zMin)).clamp(0.0, 1.0);
        c.drawRect(
          Rect.fromLTWH(t * cellW, f * cellH, cellW + 0.5, cellH + 0.5),
          Paint()..color = _spectralColor(norm),
        );
      }
    }
    return recorder.endRecording();
  }

  void _drawYAxis(Canvas canvas, Size size, List<double> freqs) {
    if (freqs.isEmpty) return;
    final logMin = math.log(freqs.first.clamp(0.01, 1000));
    final logMax = math.log(freqs.last.clamp(0.01, 1000));
    final logRange = logMax - logMin;
    if (logRange <= 0) return;

    const refHz = [0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0];
    for (final hz in refHz) {
      if (hz < freqs.first || hz > freqs.last) continue;
      final logHz = math.log(hz);
      final fy = 1.0 - (logHz - logMin) / logRange; // flip for display
      final y = fy * size.height;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = Colors.white.withOpacity(0.2)
          ..strokeWidth = 0.5,
      );
      _drawText(
        canvas,
        '${hz < 1 ? hz.toStringAsFixed(1) : hz.toInt()} Hz',
        Offset(2, y),
        style: _axisTextStyle.copyWith(color: Colors.white60),
        align: TextAlign.left,
      );
    }
  }

  void _drawXAxis(Canvas canvas, Size size) {
    const totalSec = 32.0; // 30s epoch + 1s each side
    const step = 6.0; // ticks every 6 seconds
    for (var t = -1.0; t <= 31.0; t += step) {
      final fx = (t + 1.0) / totalSec;
      final x = fx * size.width;
      if (x < 0 || x > size.width) continue;
      _drawText(
        canvas,
        '${t.toInt()}s',
        Offset(x, size.height - 1),
        style: _axisTextStyle.copyWith(color: Colors.white54, fontSize: 8),
        align: TextAlign.center,
      );
    }
  }

  @override
  bool shouldRepaint(TimeFrequencyPainter old) =>
      !identical(old.viewport.tfPower, viewport.tfPower) ||
      old.viewport.currentEpoch != viewport.currentEpoch;
}

// ─────────────────────────────────────────────────────────────────────────────
// 5.  EEG SIGNAL TIMELINE PAINTER
// ─────────────────────────────────────────────────────────────────────────────

class TimelinePainter extends CustomPainter {
  TimelinePainter(this.viewport);

  final EegViewport viewport;

  // Channel colours matching Python SignalWidget defaults
  static const List<Color> _channelColors = [
    Color(0xFF000000), // EEG default: black
    Color(0xFF1a1a1a),
    Color(0xFF333333),
    Color(0xFF555555),
    Color(0xFF6495ED), // EOG-like: cornflower blue
    Color(0xFFE91E63), // ECG-like: pink
    Color(0xFFFF8C00), // EMG-like: orange
    Color(0xFF4CAF50), // green
    Color(0xFF9C27B0), // purple
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final points = viewport.points;
    final labels = viewport.channelLabels;
    final n = labels.length;
    if (n == 0 || points.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }

    _drawBackground(canvas, size, n);
    _drawChannels(canvas, size, points, n);
    _drawChannelLabels(canvas, size, labels);
    _drawAmplitudeLines(canvas, size, n, viewport.amplitudeRangeUv);
    _drawTimeAxis(canvas, size);
    _drawEpochLabel(canvas, size);
  }

  void _paintEmpty(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFfafafa),
    );
    _drawText(canvas, 'No signal data', Offset(size.width / 2, size.height / 2),
        align: TextAlign.center);
  }

  void _drawBackground(Canvas canvas, Size size, int n) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.white,
    );
    // Horizontal grid lines between channels
    final channelHeight = size.height / n;
    final gridPaint = Paint()
      ..color = const Color(0xFFEEEEEE)
      ..strokeWidth = 0.5;
    for (var i = 1; i < n; i++) {
      final y = i * channelHeight;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  void _drawChannels(Canvas canvas, Size size, List<DisplayPoint> points, int n) {
    // Group points by channel and draw each as a polyline
    final paths = List.generate(n, (_) => Path());
    final started = List.filled(n, false);

    for (final pt in points) {
      final ch = pt.channel.clamp(0, n - 1);
      final x = pt.x * size.width;
      final y = pt.y * size.height;
      if (!started[ch]) {
        paths[ch].moveTo(x, y);
        started[ch] = true;
      } else {
        paths[ch].lineTo(x, y);
      }
    }

    for (var ch = 0; ch < n; ch++) {
      if (!started[ch]) continue;
      final color = _channelColors[ch % _channelColors.length];
      canvas.drawPath(
        paths[ch],
        Paint()
          ..color = color
          ..strokeWidth = 0.8
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _drawChannelLabels(Canvas canvas, Size size, List<String> labels) {
    final channelHeight = size.height / labels.length;
    for (var i = 0; i < labels.length; i++) {
      final y = (i + 0.15) * channelHeight;
      _drawText(canvas, labels[i], Offset(3, y),
          style: _axisTextStyle.copyWith(color: Colors.black45),
          align: TextAlign.left);
    }
  }

  void _drawAmplitudeLines(Canvas canvas, Size size, int n, double amplitudeRangeUv) {
    // Draw ±amplitude guide lines (dotted) in the centre of each channel lane
    final channelHeight = size.height / n;
    const guideOffset = 0.42; // fraction of lane height above/below centre
    final guidePaint = Paint()
      ..color = Colors.black12
      ..strokeWidth = 0.5;
    for (var i = 0; i < n; i++) {
      final cy = (i + 0.5) * channelHeight;
      final plusY = cy - guideOffset * channelHeight;
      final minusY = cy + guideOffset * channelHeight;
      
      // Dotted via dashes
      _drawDashedLine(canvas, Offset(0, plusY), Offset(size.width, plusY), guidePaint);
      _drawDashedLine(canvas, Offset(0, minusY), Offset(size.width, minusY), guidePaint);
      
      // '0' line
      _drawDashedLine(canvas, Offset(0, cy), Offset(size.width, cy), guidePaint);

      // Amplitude text
      _drawText(canvas, '+${amplitudeRangeUv.toStringAsFixed(1)}', Offset(2, plusY), style: _axisTextStyle.copyWith(color: Colors.black38, fontSize: 8), align: TextAlign.left);
      _drawText(canvas, '0', Offset(2, cy), style: _axisTextStyle.copyWith(color: Colors.black38, fontSize: 8), align: TextAlign.left);
      _drawText(canvas, '-${amplitudeRangeUv.toStringAsFixed(1)}', Offset(2, minusY), style: _axisTextStyle.copyWith(color: Colors.black38, fontSize: 8), align: TextAlign.left);
    }
    
    // Draw central vertical dashed line (at 15s)
    final verticalPaint = Paint()
      ..color = Colors.black12
      ..strokeWidth = 1.0;
    _drawDashedLine(canvas, Offset(size.width / 2, 0), Offset(size.width / 2, size.height), verticalPaint);
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    const dashLen = 8.0;
    const gapLen = 4.0;
    var x = p1.dx;
    bool drawing = true;
    while (x < p2.dx) {
      final end = x + (drawing ? dashLen : gapLen);
      if (drawing) {
        canvas.drawLine(Offset(x, p1.dy), Offset(math.min(end, p2.dx), p1.dy), paint);
      }
      x = end;
      drawing = !drawing;
    }
  }

  void _drawTimeAxis(Canvas canvas, Size size) {
    // X-axis ticks every 6 seconds inside the 30s epoch
    const epochSec = 30.0;
    const step = 6.0;
    final tickPaint = Paint()..color = Colors.black87..strokeWidth = 1.0;
    
    // The viewport is 40s total (5s before, 30s epoch, 5s after)
    const displayTotalSec = 40.0;
    const paddingLeftSec = 5.0;

    for (var t = 0.0; t <= epochSec; t += step) {
      final absoluteSec = paddingLeftSec + t;
      final x = (absoluteSec / displayTotalSec) * size.width;
      canvas.drawLine(
        Offset(x, size.height - 8),
        Offset(x, size.height),
        tickPaint,
      );
      _drawText(canvas, '${t.toInt()}s', Offset(x, size.height - 14),
          style: _axisTextStyle.copyWith(fontSize: 10, fontWeight: FontWeight.bold),
          align: TextAlign.center);
    }
  }

  void _drawEpochLabel(Canvas canvas, Size size) {
    final stage = viewport.currentStage;
    final label =
        'Epoch ${viewport.currentEpoch + 1}/${viewport.epochCount}  |  ${stage.label}';
    _drawText(canvas, label, Offset(size.width - 4, 10),
        style: const TextStyle(
          fontSize: 10,
          color: Color(0xFF0b1c2c),
          fontWeight: FontWeight.w600,
        ),
        align: TextAlign.right);
  }

  @override
  bool shouldRepaint(TimelinePainter old) =>
      old.viewport.currentEpoch != viewport.currentEpoch ||
      old.viewport.points.length != viewport.points.length;
}

// ─────────────────────────────────────────────────────────────────────────────
// 6.  SELECTION OVERLAY PAINTER  (drawn on top of signal panel)
// ─────────────────────────────────────────────────────────────────────────────

class SelectionOverlayPainter extends CustomPainter {
  SelectionOverlayPainter(
    this.viewport, {
    this.activeDragStartSec,
    this.activeDragEndSec,
  });

  final EegViewport viewport;
  final double? activeDragStartSec;
  final double? activeDragEndSec;

  @override
  void paint(Canvas canvas, Size size) {
    // The viewport is 40s total (5s before, 30s epoch, 5s after)
    const displayTotalSec = 40.0;
    const paddingSec = 5.0;
    
    final leftFrac = paddingSec / displayTotalSec;
    final rightFrac = 1.0 - leftFrac;

    final paint = Paint()..color = Colors.black.withOpacity(0.04);
    
    // Left shaded region
    canvas.drawRect(
      Rect.fromLTRB(0, 0, size.width * leftFrac, size.height),
      paint,
    );
    
    // Right shaded region
    canvas.drawRect(
      Rect.fromLTRB(size.width * rightFrac, 0, size.width, size.height),
      paint,
    );

    // Draw user selection if any
    final selStart = activeDragStartSec ?? viewport.selectionStartSec;
    final selEnd = activeDragEndSec ?? viewport.selectionEndSec;
    if (selStart != null && selEnd != null) {
      final s = math.min(selStart, selEnd);
      final e = math.max(selStart, selEnd);
      
      final visibleStart = viewport.visibleStartSeconds;
      
      final x1 = ((s - visibleStart) / displayTotalSec) * size.width;
      final x2 = ((e - visibleStart) / displayTotalSec) * size.width;
      
      // Draw selection rect
      canvas.drawRect(
        Rect.fromLTRB(x1, 0, x2, size.height),
        Paint()..color = Colors.blue.withOpacity(0.2),
      );
      
      // Draw border edges
      final edgePaint = Paint()
        ..color = Colors.blue.withOpacity(0.8)
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(x1, 0), Offset(x1, size.height), edgePaint);
      canvas.drawLine(Offset(x2, 0), Offset(x2, size.height), edgePaint);
    }
  }

  @override
  bool shouldRepaint(SelectionOverlayPainter old) =>
      old.viewport.selectionStartSec != viewport.selectionStartSec ||
      old.viewport.selectionEndSec != viewport.selectionEndSec ||
      old.activeDragStartSec != activeDragStartSec ||
      old.activeDragEndSec != activeDragEndSec;
}
