// lib/src/app.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config_dialog.dart';
import 'detection_dialogs.dart';
import 'eeg_backend.dart';
import 'models.dart';
import 'scoring_io.dart';
import 'signal_processing.dart' as sp;
import 'timeline_painter.dart';

const double _plotLeftPadding = 90.0;

class ScoringNidraApp extends StatelessWidget {
  const ScoringNidraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ScoringNidra',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B6EA5),
          brightness: Brightness.light,
        ),
        useMaterial3: false,
        fontFamily: Platform.isMacOS ? '.AppleSystemUIFont' : null,
      ),
      home: const ScoringNidraHome(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class ScoringNidraHome extends StatefulWidget {
  const ScoringNidraHome({super.key});

  @override
  State<ScoringNidraHome> createState() => _ScoringNidraHomeState();
}

class _ScoringNidraHomeState extends State<ScoringNidraHome> {
  final EegBackend _backend = EegBackend();
  final FocusNode _viewerFocusNode = FocusNode();
  AppConfig _config = AppConfig();

  EegViewport? _viewport;
  LoadedEeg? _loadedEeg;
  List<SleepStage>? _comparisonStages;
  String? _activePath;
  String _status = 'Ready — load an EDF file to begin scoring';
  int _navigationSerial = 0;
  Timer? _tfRefreshTimer;

  // SWA slider value (0–100). 100 = no smoothing, 0 = maximum smoothing.
  int _swaSlider = 100;

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _viewport = _backend.loadDemoViewport();
  }

  @override
  void dispose() {
    _tfRefreshTimer?.cancel();
    _viewerFocusNode.dispose();
    super.dispose();
  }

  // ─── Status bar helpers ───────────────────────────────────────────────────

  void _setStatus(String s) => setState(() => _status = s);

  void _showPending(String feature) =>
      _setStatus('$feature — not yet implemented in this version.');

  // ─── File loading ─────────────────────────────────────────────────────────

  Future<void> _openRecording({required String kind}) async {
    _setStatus(
      kind == 'mat' ? 'Opening MAT file picker…' : 'Opening EDF file picker…',
    );
    final result = await FilePicker.pickFiles(
      dialogTitle: kind == 'mat'
          ? 'Load EEGLAB structure (.mat)'
          : (kind == 'r09' ? 'Load Zurich file (.r09)' : 'Load EDF file (.edf)'),
      type: FileType.custom,
      allowedExtensions: kind == 'mat' ? ['mat'] : (kind == 'r09' ? ['r09'] : ['edf']),
    );
    final path = result?.files.single.path;
    if (path == null) {
      _setStatus('Open cancelled');
      return;
    }

    _setStatus('Loading ${_basename(path)} — computing spectrogram…');
    await Future.microtask(() {}); // let the UI update

    try {
      // Try to auto-load config JSON next to the EDF
      final autoCfg = await tryLoadAutoConfig(path);

      final LoadedEeg rawEeg;
      if (kind == 'edf') {
        rawEeg = _backend.loadEdf(path);
      } else if (kind == 'edfvolt') {
        rawEeg = _backend.loadEdf(
          path,
          scaleVoltsToMicrovolts: true,
        );
      } else if (kind == 'r09') {
        rawEeg = _backend.loadR09(path);
      } else {
        rawEeg = _backend.loadMat(path);
      }

      final activeConfig = autoCfg ?? AppConfig.defaultsForChannels(rawEeg.channelLabels, sampleRateHz: rawEeg.sampleRateHz);
      if (autoCfg == null) {
        // Copy user preferences
        activeConfig.amplitudeRangeUv = _config.amplitudeRangeUv;
        activeConfig.tfFreqMin = _config.tfFreqMin;
        activeConfig.tfFreqMax = _config.tfFreqMax;
        activeConfig.spectrogramFreqMin = _config.spectrogramFreqMin;
        activeConfig.spectrogramFreqMax = _config.spectrogramFreqMax;
        activeConfig.periodogramFreqMin = _config.periodogramFreqMin;
        activeConfig.periodogramFreqMax = _config.periodogramFreqMax;
        activeConfig.spectrogramPowerMin = _config.spectrogramPowerMin;
        activeConfig.spectrogramPowerMax = _config.spectrogramPowerMax;
        activeConfig.tfEnabled = _config.tfEnabled;
        activeConfig.tfDisplayMode = _config.tfDisplayMode;
        activeConfig.tfFrequencyScale = _config.tfFrequencyScale;
        activeConfig.tfShowRidge = _config.tfShowRidge;
        activeConfig.tfPowerMin = _config.tfPowerMin;
        activeConfig.tfPowerMax = _config.tfPowerMax;
        activeConfig.stackChannels = _config.stackChannels;
        activeConfig.robustZStandardize = _config.robustZStandardize;
        activeConfig.periodogramDisplayMode = _config.periodogramDisplayMode;
        activeConfig.eegPanelTimeUnit = _config.eegPanelTimeUnit;
        activeConfig.distanceBetweenChannelsUv = _config.distanceBetweenChannelsUv;
        activeConfig.referenceAmplitudeLineUv = _config.referenceAmplitudeLineUv;
      }
      activeConfig.bindLoadedChannels(rawEeg.channelLabels);
      if (autoCfg == null) {
        await saveAutoConfig(path, activeConfig);
      }

      // Pre-compute night products. Per-epoch wavelets are computed lazily.
      _setStatus('Computing spectrogram and power summaries…');
      final eeg = await _backend.computeNightProducts(rawEeg, activeConfig);

      // Try to auto-load an existing scoring JSON next to the EDF
      final epochCount = (eeg.durationSeconds / 30).ceil();
      final loadResult = await tryLoadAutoScoring(path, epochCount);
      final existingStages = loadResult?.stages;
      final existingStagesUncertain = loadResult?.stagesUncertain;
      final existingEvents = await tryLoadAutoEvents(path);

      final viewport = await _backend.viewportFromEeg(
        eeg,
        currentEpoch: 0,
        config: activeConfig,
        existingStages: existingStages,
        existingStagesUncertain: existingStagesUncertain,
        includeTimeFrequency: false,
      );

      setState(() {
        _activePath = path;
        _loadedEeg = eeg;
        _config = activeConfig;
        _viewport = viewport.copyWith(scoredEvents: existingEvents);
        _status =
            'Loaded ${_basename(path)} — '
            '${existingStages != null ? '${existingStages.where((s) => s.isScored).length}/${existingStages.length} epochs already scored' : 'scoring started'}';
      });
      _viewerFocusNode.requestFocus();
      if (_config.tfEnabled) {
        _scheduleTimeFrequencyRefresh(++_navigationSerial);
      }
    } on UnsupportedError catch (e) {
      _setStatus(e.message ?? e.toString());
    } on Object catch (e) {
      _setStatus('Could not load ${_basename(path)}: $e');
    }
  }

  // ─── Close file ────────────────────────────────────────────────────────────

  void _closeCurrentFile() {
    _tfRefreshTimer?.cancel();
    _tfRefreshTimer = null;
    setState(() {
      _activePath = null;
      _loadedEeg = null;
      _comparisonStages = null;
      _viewport = _backend.loadDemoViewport();
      _config = AppConfig();
      _status = 'File closed — load an EDF file to begin scoring';
    });
  }

  // ─── Scoring ──────────────────────────────────────────────────────────────

  void _scoreCurrentEpoch(SleepStage stage) {
    final viewport = _viewport;
    if (viewport == null) return;

    final newStages = [
      for (var i = 0; i < viewport.epochCount; i++)
        i == viewport.currentEpoch ? stage : viewport.stages[i],
    ];
    setState(() {
      _viewport = viewport.copyWith(stages: newStages);
      _status = 'Epoch ${viewport.currentEpoch + 1} → ${stage.label}';
    });

    // Auto-save on every score change
    autoSaveScoring(
      _activePath,
      newStages,
      viewport.epochSeconds,
      events: viewport.scoredEvents,
      stagesUncertain: viewport.stagesUncertain,
    );

    // Auto-advance to next epoch (matching Python score_stage.py)
    _nextEpoch();
  }

  void _toggleUncertainty() {
    final v = _viewport;
    if (v == null) return;
    final epoch = v.currentEpoch;
    final newUncertain = List<bool>.from(v.stagesUncertain);
    newUncertain[epoch] = !newUncertain[epoch];
    final updated = v.copyWith(stagesUncertain: newUncertain);
    setState(() {
      _viewport = updated;
      _status = 'Epoch ${epoch + 1} uncertainty toggled to ${newUncertain[epoch]}';
    });
    autoSaveScoring(
      _activePath,
      updated.stages,
      updated.epochSeconds,
      events: updated.scoredEvents,
      stagesUncertain: updated.stagesUncertain,
    );
  }

  // ─── Navigation ───────────────────────────────────────────────────────────

  void _nextEpoch() => _jumpRelative(1);
  void _previousEpoch() => _jumpRelative(-1);

  void _jumpRelative(int delta) {
    final v = _viewport;
    if (v == null) return;
    _jumpToEpoch(v.currentEpoch + 1 + delta);
  }

  void _jumpToEpoch(int epochOneBased, [bool claimFocus = true]) {
    final v = _viewport;
    if (v == null) return;
    final epoch = (epochOneBased - 1).clamp(0, v.epochCount - 1);
    final eeg = _loadedEeg;
    final serial = ++_navigationSerial;
    _tfRefreshTimer?.cancel();

    EegViewport newViewport;
    if (eeg == null) {
      newViewport = v.copyWith(currentEpoch: epoch);
    } else {
      newViewport = _backend
          .rebuildViewportForEpochSync(v, eeg, epoch, config: _config)
          .copyWith(stages: v.stages, stagesUncertain: v.stagesUncertain);
    }

    if (mounted) {
      setState(() {
        _viewport = newViewport;
        _status =
            'Epoch ${epoch + 1} / ${v.epochCount}  |  ${v.stages[epoch].label}';
      });
      if (claimFocus) {
        _viewerFocusNode.requestFocus();
      }
    }
    if (eeg != null && _config.tfEnabled) {
      _scheduleTimeFrequencyRefresh(serial);
    }
  }

  void _scheduleTimeFrequencyRefresh(int serial) {
    _tfRefreshTimer?.cancel();
    _tfRefreshTimer = Timer(const Duration(milliseconds: 550), () {
      unawaited(_refreshTimeFrequency(serial));
    });
  }

  Future<void> _refreshTimeFrequency(int serial) async {
    final v = _viewport;
    final eeg = _loadedEeg;
    if (v == null || eeg == null || serial != _navigationSerial) return;

    try {
      final refreshed = await _backend.refreshTimeFrequencyForEpoch(
        v,
        eeg,
        config: _config,
      );
      if (!mounted || serial != _navigationSerial) return;
      setState(() {
        _viewport = refreshed.copyWith(stages: v.stages, stagesUncertain: v.stagesUncertain);
      });
    } catch (e) {
      if (!mounted || serial != _navigationSerial) return;
      _setStatus('Wavelet rendering failed: $e');
    }
  }

  // ─── Toolbar navigation jumps ─────────────────────────────────────────────

  /// Jump to the next epoch satisfying [test], starting from currentEpoch+1.
  void _jumpToNext(bool Function(SleepStage s) test, String label) {
    final v = _viewport;
    if (v == null) return;
    for (var i = v.currentEpoch + 1; i < v.epochCount; i++) {
      if (test(v.stages[i])) {
        _jumpToEpoch(i + 1);
        return;
      }
    }
    _setStatus('No more $label epochs found');
  }

  void _jumpNextUnscored() => _jumpToNext((s) => !s.isScored, 'unscored');

  void _jumpNextUncertain() {
    final v = _viewport;
    if (v == null) return;
    for (var i = v.currentEpoch + 1; i < v.epochCount; i++) {
      if (v.stagesUncertain[i]) {
        _jumpToEpoch(i + 1);
        return;
      }
    }
    _setStatus('No more uncertain epochs found');
  }

  void _jumpNextTransition() {
    final v = _viewport;
    if (v == null) return;
    for (var i = v.currentEpoch + 1; i < v.epochCount; i++) {
      if (i > 0 && v.stages[i] != v.stages[i - 1]) {
        _jumpToEpoch(i + 1);
        return;
      }
    }
    _setStatus('No more stage transitions found');
  }

  void _jumpNextHuman() => _jumpToNext(
    (s) => s.isScored && s != SleepStage.inconclusive,
    'human-scored',
  );

  void _jumpNextEvent() {
    final v = _viewport;
    if (v == null) return;
    final currentEpoch = v.currentEpoch;
    final eventEpochs = <int>{};
    for (final event in v.scoredEvents) {
      eventEpochs.addAll(event.epochs(v.epochSeconds, v.epochCount));
    }
    final sorted = eventEpochs.toList()..sort();
    for (final epoch in sorted) {
      if (epoch > currentEpoch) {
        _jumpToEpoch(epoch + 1);
        return;
      }
    }
    _setStatus('No more event epochs found');
  }

  void _jumpNextDisagreement() {
    final v = _viewport;
    final comparison = _comparisonStages;
    if (v == null || comparison == null) {
      _setStatus('No comparison scoring loaded');
      return;
    }
    for (
      var i = v.currentEpoch + 1;
      i < v.epochCount && i < comparison.length;
      i++
    ) {
      if (v.stages[i] != comparison[i]) {
        _jumpToEpoch(i + 1);
        return;
      }
    }
    _setStatus('No more disagreement epochs found');
  }

  // ─── Selection ────────────────────────────────────────────────────────────

  Future<void> _updateSelection(
    double? startSec,
    double? endSec,
    int? channel,
    double? startUv,
    double? endUv,
  ) async {
    final v = _viewport;
    final eeg = _loadedEeg;
    if (v == null || eeg == null) return;

    final newViewport = await _backend.updateSelection(
      v,
      eeg,
      startSec,
      endSec,
      channel: channel,
      startUv: startUv,
      endUv: endUv,
      config: _config,
    );
    if (mounted) {
      setState(() {
        _viewport = newViewport;
      });
      if (newViewport.scoredEvents.length != v.scoredEvents.length) {
        autoSaveScoring(
          _activePath,
          newViewport.stages,
          newViewport.epochSeconds,
          events: newViewport.scoredEvents,
          stagesUncertain: newViewport.stagesUncertain,
        );
      }
    }
  }

  void _markEvent(int digit) {
    final v = _viewport;
    if (v == null) return;
    final label = _eventLabel(digit);
    final key = digit == 0 ? 'A' : 'F$digit';
    final newEvents = <ScoredEvent>[...v.scoredEvents];
    if (v.eventSelections.isEmpty) {
      final start = v.currentEpoch * v.epochSeconds.toDouble();
      newEvents.add(
        ScoredEvent(
          digit: digit,
          key: key,
          label: label,
          startSec: start,
          endSec: start + v.epochSeconds,
        ),
      );
    } else {
      for (final selection in v.eventSelections) {
        final start = selection.startSec < selection.endSec
            ? selection.startSec
            : selection.endSec;
        final end = selection.startSec < selection.endSec
            ? selection.endSec
            : selection.startSec;
        if (end > start) {
          newEvents.add(
            ScoredEvent(
              digit: digit,
              key: key,
              label: label,
              startSec: start,
              endSec: end,
            ),
          );
        }
      }
    }
    setState(() {
      _viewport = v.copyWith(
        scoredEvents: _mergeScoredEvents(newEvents),
        clearSelection: true,
        clearEventSelections: true,
      );
      _status = 'Marked ${_eventLabel(digit)}';
    });
    final updated = _viewport;
    if (updated != null) {
      autoSaveScoring(
        _activePath,
        updated.stages,
        updated.epochSeconds,
        events: updated.scoredEvents,
        stagesUncertain: updated.stagesUncertain,
      );
    }
  }

  void _eraseEventsInSelections() {
    final v = _viewport;
    if (v == null || v.eventSelections.isEmpty) return;
    final eraseRanges = [
      for (final selection in v.eventSelections)
        (
          selection.startSec < selection.endSec
              ? selection.startSec
              : selection.endSec,
          selection.startSec < selection.endSec
              ? selection.endSec
              : selection.startSec,
        ),
    ];
    final kept = <ScoredEvent>[];
    for (final event in v.scoredEvents) {
      var fragments = <(double, double)>[(event.startSec, event.endSec)];
      for (final erase in eraseRanges) {
        final next = <(double, double)>[];
        for (final fragment in fragments) {
          final start = fragment.$1;
          final end = fragment.$2;
          final eraseStart = erase.$1;
          final eraseEnd = erase.$2;
          if (eraseEnd <= start || eraseStart >= end) {
            next.add(fragment);
          } else {
            if (eraseStart > start) next.add((start, eraseStart));
            if (eraseEnd < end) next.add((eraseEnd, end));
          }
        }
        fragments = next;
      }
      for (final fragment in fragments) {
        if (fragment.$2 > fragment.$1) {
          kept.add(
            ScoredEvent(
              digit: event.digit,
              key: event.key,
              label: event.label,
              startSec: fragment.$1,
              endSec: fragment.$2,
            ),
          );
        }
      }
    }
    setState(() {
      _viewport = v.copyWith(
        scoredEvents: kept,
        clearSelection: true,
        clearEventSelections: true,
      );
      _status = 'Erased events in drawn selection';
    });
    final updated = _viewport;
    if (updated != null) {
      autoSaveScoring(
        _activePath,
        updated.stages,
        updated.epochSeconds,
        events: updated.scoredEvents,
        stagesUncertain: updated.stagesUncertain,
      );
    }
  }

  void _deleteAllEvents() {
    final v = _viewport;
    if (v == null) return;
    setState(() {
      _viewport = v.copyWith(
        scoredEvents: const [],
        clearEventSelections: true,
      );
      _status = 'Deleted all events';
    });
    autoSaveScoring(_activePath, v.stages, v.epochSeconds, stagesUncertain: v.stagesUncertain);
  }

  List<ScoredEvent> _mergeScoredEvents(List<ScoredEvent> events) {
    events.sort((a, b) {
      final labelCompare = a.digit.compareTo(b.digit);
      if (labelCompare != 0) return labelCompare;
      return a.startSec.compareTo(b.startSec);
    });
    final merged = <ScoredEvent>[];
    for (final event in events) {
      if (merged.isEmpty ||
          merged.last.digit != event.digit ||
          event.startSec > merged.last.endSec) {
        merged.add(event);
      } else {
        final last = merged.removeLast();
        merged.add(
          ScoredEvent(
            digit: last.digit,
            key: last.key,
            label: last.label,
            startSec: last.startSec,
            endSec: event.endSec > last.endSec ? event.endSec : last.endSec,
          ),
        );
      }
    }
    return merged;
  }

  String _eventLabel(int digit) => digit == 0 ? 'Artifact' : 'Event $digit';

  // ─── Scoring I/O ──────────────────────────────────────────────────────────

  Future<void> _loadScoring(String filetype) async {
    final v = _viewport;
    if (v == null) {
      _setStatus('Load an EDF first');
      return;
    }
    final result = await importScoringDialog(
      v.epochCount,
      filetype,
      onStatus: _setStatus,
    );
    if (result != null) {
      setState(() {
        _viewport = v.copyWith(stages: result.stages, stagesUncertain: result.stagesUncertain);
      });
    }
  }

  Future<void> _saveScoring() async {
    final v = _viewport;
    if (v == null) {
      _setStatus('Nothing to save');
      return;
    }
    await exportScoringDialog(
      v.stages,
      v.epochSeconds,
      _activePath,
      events: v.scoredEvents,
      stagesUncertain: v.stagesUncertain,
      onStatus: _setStatus,
    );
  }

  Future<void> _loadComparisonScoring() async {
    final v = _viewport;
    if (v == null) {
      _setStatus('Load an EDF first');
      return;
    }
    final result = await importScoringDialog(
      v.epochCount,
      'any',
      onStatus: _setStatus,
    );
    if (result == null) return;
    setState(() {
      _comparisonStages = result.stages;
      _status =
          'Loaded comparison scoring — ${_disagreementCount(v.stages, result.stages)} disagreements';
    });
  }

  void _removeComparisonScoring() {
    setState(() {
      _comparisonStages = null;
      _status = 'Comparison scoring removed';
    });
  }

  void _showComparisonStats() {
    final v = _viewport;
    final comparison = _comparisonStages;
    if (v == null || comparison == null) {
      _setStatus('No comparison scoring loaded');
      return;
    }
    final total = v.epochCount < comparison.length
        ? v.epochCount
        : comparison.length;
    final disagreements = _disagreementCount(v.stages, comparison);
    final agreement = total == 0
        ? 0.0
        : (total - disagreements) / total * 100.0;
    final rows = <String>[];
    for (final stage in SleepStage.values.where(
      (s) => s != SleepStage.unknown,
    )) {
      final appCount = v.stages.take(total).where((s) => s == stage).length;
      final cmpCount = comparison.take(total).where((s) => s == stage).length;
      rows.add('${stage.label}: app $appCount | comparison $cmpCount');
    }
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Comparison statistics'),
        content: Text(
          'Epochs compared: $total\n'
          'Disagreements: $disagreements\n'
          'Agreement: ${agreement.toStringAsFixed(1)}%\n\n'
          '${rows.join('\n')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showSelectionHelp() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Signal selection box'),
        content: const Text(
          'Drag on the signal panel to draw one or more selection boxes. '
          'The total duration is shown in the upper right of the signal view. '
          'Press A for Artifact or F1-F12 for Event 1-12 to convert the drawn boxes into events. '
          'Press Backspace to erase existing events inside drawn boxes. '
          'Press Q to toggle uncertainty for the current epoch.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadSleeptripEvents() async {
    final v = _viewport;
    if (v == null) {
      _setStatus('Load an EDF first');
      return;
    }
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Load Sleeptrip Events (_events.csv)',
      type: FileType.custom,
      allowedExtensions: ['csv', 'tsv', 'txt'],
    );
    final path = result?.files.single.path;
    if (path == null) {
      _setStatus('Event import cancelled');
      return;
    }
    try {
      final lines = await File(path).readAsLines();
      if (lines.isEmpty) throw const FormatException('Empty events file');
      final delimiter = lines.first.contains('\t') ? '\t' : ',';
      final header = lines.first
          .split(delimiter)
          .map((h) => h.trim().toLowerCase())
          .toList();
      final eventCol = header.indexOf('event');
      final startCol = header.indexOf('start');
      final stopCol = header.contains('stop')
          ? header.indexOf('stop')
          : header.indexOf('end');
      if (eventCol < 0 || startCol < 0 || stopCol < 0) {
        throw const FormatException(
          'Expected event, start, and stop/end columns',
        );
      }
      final labelToDigit = <String, int>{};
      final imported = <ScoredEvent>[];
      for (final line in lines.skip(1)) {
        if (line.trim().isEmpty) continue;
        final cols = line.split(delimiter);
        if (cols.length <= stopCol ||
            cols.length <= eventCol ||
            cols.length <= startCol) {
          continue;
        }
        final label = cols[eventCol].trim();
        final start = double.tryParse(cols[startCol].trim());
        final stop = double.tryParse(cols[stopCol].trim());
        if (label.isEmpty || start == null || stop == null || stop <= start) {
          continue;
        }
        final digit = labelToDigit.putIfAbsent(
          label,
          () => (labelToDigit.length + 1).clamp(1, 12).toInt(),
        );
        imported.add(
          ScoredEvent(
            digit: digit,
            key: 'F$digit',
            label: label,
            startSec: start,
            endSec: stop,
          ),
        );
      }
      setState(() {
        _viewport = v.copyWith(
          scoredEvents: _mergeScoredEvents([...v.scoredEvents, ...imported]),
        );
        _status = 'Imported ${imported.length} Sleeptrip events';
      });
    } catch (e) {
      _setStatus('Failed to import Sleeptrip events: $e');
    }
  }

  Future<void> _runKComplexDetection() async {
    final eeg = _loadedEeg;
    final v = _viewport;
    if (eeg == null || v == null) {
      _setStatus('Load an EDF first');
      return;
    }

    final hasStages = v.stages.any((s) => s.isScored);

    showDialog(
      context: context,
      builder: (_) => MtKcdDialog(
        channelLabels: eeg.channelLabels,
        hasStages: hasStages,
        onRun: (settings) async {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => const AlertDialog(
              content: Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 20),
                  Text('Running MT-KCD K-Complex detection…'),
                ],
              ),
            ),
          );

          try {
            final chIdx = eeg.channelLabels.indexOf(settings['channel']);
            if (chIdx < 0) throw Exception('Channel not found');
            final signal = eeg.channelSamples[chIdx];
            final sfreq = eeg.sampleRateHz;

            final amin = settings['amin'] as double;
            final dmax_s = settings['dmax_s'] as double;
            final q = settings['q'] as double;
            final fmax = settings['fmax'] as double;

            final events = await _runKComplexIsolate(
              signal,
              sfreq,
              amin,
              dmax_s,
              q,
              fmax,
            );

            if (mounted) Navigator.of(context).pop();

            final filterStages = settings['filter_stages'] as List<String>?;
            var finalEvents = events;
            if (filterStages != null && filterStages.isNotEmpty) {
              final stageSet = filterStages.toSet();
              finalEvents = events.where((event) {
                final mid = (event.$1 + event.$2) / 2.0;
                final epochIdx = (mid / v.epochSeconds).floor();
                if (epochIdx >= 0 && epochIdx < v.stages.length) {
                  return stageSet.contains(v.stages[epochIdx].label);
                }
                return false;
              }).toList();
            }

            final markerLabel = settings['marker'] as String;
            final digit = markerLabel == 'Artifact' ? 0 : int.parse(markerLabel.substring(1));
            final key = digit == 0 ? 'A' : 'F$digit';
            final label = digit == 0 ? 'Artifact' : 'Event $digit';

            final scoredEvents = <ScoredEvent>[...v.scoredEvents];
            for (final ev in finalEvents) {
              scoredEvents.add(
                ScoredEvent(
                  digit: digit,
                  key: key,
                  label: label,
                  startSec: ev.$1,
                  endSec: ev.$2,
                ),
              );
            }

            final merged = _mergeScoredEvents(scoredEvents);

            if (mounted) {
              setState(() {
                _viewport = v.copyWith(
                  scoredEvents: merged,
                  clearEventSelections: true,
                );
                _status = 'MT-KCD completed: detected ${finalEvents.length} K-complex(s)';
              });
              
              autoSaveScoring(
                _activePath,
                _viewport!.stages,
                _viewport!.epochSeconds,
                events: _viewport!.scoredEvents,
                stagesUncertain: _viewport!.stagesUncertain,
              );
            }
          } catch (e) {
            if (mounted) {
              Navigator.of(context).pop();
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('MT-KCD Error'),
                  content: Text('An error occurred during K-complex detection:\n\n$e'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
            }
          }
        },
      ),
    );
  }

  Future<void> _runSpindleDetection() async {
    final eeg = _loadedEeg;
    final v = _viewport;
    if (eeg == null || v == null) {
      _setStatus('Load an EDF first');
      return;
    }

    final hasStages = v.stages.any((s) => s.isScored);

    showDialog(
      context: context,
      builder: (_) => MtSpindleDialog(
        channelLabels: eeg.channelLabels,
        hasStages: hasStages,
        onRun: (settings) async {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => const AlertDialog(
              content: Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 20),
                  Text('Running MT-Spindle spindle detection…'),
                ],
              ),
            ),
          );

          try {
            final chIdx = eeg.channelLabels.indexOf(settings['channel']);
            if (chIdx < 0) throw Exception('Channel not found');
            final signal = eeg.channelSamples[chIdx];
            final sfreq = eeg.sampleRateHz;

            final fmin = settings['fmin'] as double;
            final fmax = settings['fmax'] as double;
            final amin = settings['amin'] as double;
            final dmin_s = settings['dmin_s'] as double;
            final dmax_s = settings['dmax_s'] as double;
            final q = settings['q'] as double;

            final events = await _runSpindleIsolate(
              signal,
              sfreq,
              fmin,
              fmax,
              amin,
              dmin_s,
              dmax_s,
              q,
            );

            if (mounted) Navigator.of(context).pop();

            final filterStages = settings['filter_stages'] as List<String>?;
            var finalEvents = events;
            if (filterStages != null && filterStages.isNotEmpty) {
              final stageSet = filterStages.toSet();
              finalEvents = events.where((event) {
                final mid = (event.$1 + event.$2) / 2.0;
                final epochIdx = (mid / v.epochSeconds).floor();
                if (epochIdx >= 0 && epochIdx < v.stages.length) {
                  return stageSet.contains(v.stages[epochIdx].label);
                }
                return false;
              }).toList();
            }

            final markerLabel = settings['marker'] as String;
            final digit = markerLabel == 'Artifact' ? 0 : int.parse(markerLabel.substring(1));
            final key = digit == 0 ? 'A' : 'F$digit';
            final label = digit == 0 ? 'Artifact' : 'Event $digit';

            final scoredEvents = <ScoredEvent>[...v.scoredEvents];
            for (final ev in finalEvents) {
              scoredEvents.add(
                ScoredEvent(
                  digit: digit,
                  key: key,
                  label: label,
                  startSec: ev.$1,
                  endSec: ev.$2,
                ),
              );
            }

            final merged = _mergeScoredEvents(scoredEvents);

            if (mounted) {
              setState(() {
                _viewport = v.copyWith(
                  scoredEvents: merged,
                  clearEventSelections: true,
                );
                _status = 'MT-Spindle completed: detected ${finalEvents.length} spindle(s)';
              });
              
              autoSaveScoring(
                _activePath,
                _viewport!.stages,
                _viewport!.epochSeconds,
                events: _viewport!.scoredEvents,
                stagesUncertain: _viewport!.stagesUncertain,
              );
            }
          } catch (e) {
            if (mounted) {
              Navigator.of(context).pop();
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('MT-Spindle Error'),
                  content: Text('An error occurred during spindle detection:\n\n$e'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
            }
          }
        },
      ),
    );
  }

  Future<void> _exportSleepReport() async {
    final v = _viewport;
    if (v == null) {
      _setStatus('Load an EDF first');
      return;
    }
    final output = await FilePicker.saveFile(
      dialogTitle: 'Export Sleep Report (PDF)',
      fileName: '${_basename(_activePath ?? 'sleep_report')}.report.pdf',
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (output == null) {
      _setStatus('Report export cancelled');
      return;
    }
    final path = output.toLowerCase().endsWith('.pdf') ? output : '$output.pdf';
    final lines = _sleepReportLines(v);
    await File(path).writeAsBytes(_buildSimplePdf(lines));
    _setStatus('Exported sleep report to ${_basename(path)}');
  }

  List<String> _sleepReportLines(EegViewport v) {
    final scored = v.stages.where((s) => s.isScored).length;
    final sleepEpochs = v.stages
        .where(
          (s) =>
              s == SleepStage.n1 ||
              s == SleepStage.n2 ||
              s == SleepStage.n3 ||
              s == SleepStage.rem,
        )
        .length;
    final totalMinutes = v.epochCount * v.epochSeconds / 60.0;
    final sleepMinutes = sleepEpochs * v.epochSeconds / 60.0;
    final efficiency = totalMinutes <= 0
        ? 0.0
        : sleepMinutes / totalMinutes * 100.0;
    final lines = <String>[
      'Scoring Hero Sleep Report',
      'Recording: ${_basename(_activePath ?? v.sourceDescription)}',
      'Epochs: ${v.epochCount} (${v.epochSeconds} s)',
      'Scored epochs: $scored / ${v.epochCount}',
      'Recording time: ${totalMinutes.toStringAsFixed(1)} min',
      'Total sleep time: ${sleepMinutes.toStringAsFixed(1)} min',
      'Sleep efficiency: ${efficiency.toStringAsFixed(1)} %',
      '',
      'Stage distribution',
    ];
    for (final stage in [
      SleepStage.wake,
      SleepStage.n1,
      SleepStage.n2,
      SleepStage.n3,
      SleepStage.rem,
      SleepStage.inconclusive,
      SleepStage.unknown,
    ]) {
      final count = v.stages.where((s) => s == stage).length;
      final minutes = count * v.epochSeconds / 60.0;
      lines.add(
        '${stage.label}: $count epochs, ${minutes.toStringAsFixed(1)} min',
      );
    }
    lines.add('');
    lines.add('Events');
    final eventsByLabel = <String, (int, double)>{};
    for (final event in v.scoredEvents) {
      final old = eventsByLabel[event.label] ?? (0, 0.0);
      eventsByLabel[event.label] = (old.$1 + 1, old.$2 + event.durationSeconds);
    }
    if (eventsByLabel.isEmpty) {
      lines.add('No events marked.');
    } else {
      for (final entry in eventsByLabel.entries) {
        lines.add(
          '${entry.key}: ${entry.value.$1} events, ${entry.value.$2.toStringAsFixed(1)} s',
        );
      }
    }
    return lines;
  }

  List<int> _buildSimplePdf(List<String> lines) {
    final escaped = lines
        .take(42)
        .map(
          (line) => line
              .replaceAll('\\', '\\\\')
              .replaceAll('(', r'\(')
              .replaceAll(')', r'\)'),
        )
        .toList();
    final content = StringBuffer('BT\n/F1 12 Tf\n50 760 Td\n');
    for (var i = 0; i < escaped.length; i++) {
      if (i > 0) content.write('0 -16 Td\n');
      content.write('(${escaped[i]}) Tj\n');
    }
    content.write('ET\n');
    final stream = content.toString();
    final objects = <String>[
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
      '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    ];
    final buffer = StringBuffer('%PDF-1.4\n');
    final offsets = <int>[0];
    for (var i = 0; i < objects.length; i++) {
      offsets.add(buffer.length);
      buffer.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
    }
    final xrefOffset = buffer.length;
    buffer.write('xref\n0 ${objects.length + 1}\n');
    buffer.write('0000000000 65535 f \n');
    for (final offset in offsets.skip(1)) {
      buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
    }
    buffer.write(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xrefOffset\n%%EOF\n',
    );
    return buffer.toString().codeUnits;
  }

  void _zoomOnSelectedEeg() {
    final v = _viewport;
    final eeg = _loadedEeg;
    if (v == null || eeg == null || v.eventSelections.isEmpty) {
      _setStatus('Draw a signal selection first');
      return;
    }
    final selection = v.eventSelections.last;
    final rawIdx =
        selection.channel >= 0 &&
            selection.channel < v.signalChannelSourceIndices.length
        ? v.signalChannelSourceIndices[selection.channel]
        : selection.channel;
    if (rawIdx < 0 || rawIdx >= eeg.channelSamples.length) return;
    final srate = eeg.sampleRateHz;
    final start = (math.min(selection.startSec, selection.endSec) * srate)
        .round()
        .clamp(0, eeg.channelSamples[rawIdx].length);
    final end = (math.max(selection.startSec, selection.endSec) * srate)
        .round()
        .clamp(0, eeg.channelSamples[rawIdx].length);
    if (end <= start) return;
    final samples = eeg.channelSamples[rawIdx].sublist(start, end);
    final label = rawIdx < v.channelLabels.length
        ? v.channelLabels[rawIdx]
        : 'Channel';
    showDialog(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 760,
          height: 420,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'Selected EEG: $label',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                child: CustomPaint(
                  painter: _ZoomSignalPainter(samples, srate),
                  child: const SizedBox.expand(),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  int _disagreementCount(List<SleepStage> a, List<SleepStage> b) {
    final total = a.length < b.length ? a.length : b.length;
    var count = 0;
    for (var i = 0; i < total; i++) {
      if (a[i] != b[i]) count++;
    }
    return count;
  }

  // ─── Configuration I/O ────────────────────────────────────────────────────

  Future<void> _loadConfig() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      try {
        final content = await file.readAsString();
        final dynamic decoded = jsonDecode(content);
        final newCfg = decoded is Map<String, dynamic>
            ? AppConfig.fromJson(decoded)
            : AppConfig.fromPythonJson(
                decoded,
                _viewport?.channelLabels ?? const [],
              );
        final eegForBinding = _loadedEeg;
        if (eegForBinding != null) {
          newCfg.bindLoadedChannels(eegForBinding.channelLabels);
        }

        setState(() {
          _config = newCfg;
        });
        if (_activePath != null) {
          await saveAutoConfig(_activePath!, newCfg);
        }

        final eeg = _loadedEeg;
        final v = _viewport;
        if (eeg != null && v != null) {
          _backend.clearDisplayCache();
          _setStatus('Applying loaded configuration…');
          final newEeg = await _backend.computeNightProducts(eeg, newCfg);
          final newViewport = await _backend.viewportFromEeg(
            newEeg,
            currentEpoch: v.currentEpoch,
            config: newCfg,
            existingStages: v.stages,
            existingStagesUncertain: v.stagesUncertain,
            includeTimeFrequency: false,
          );
          if (mounted) {
            setState(() {
              _loadedEeg = newEeg;
              _viewport = newViewport;
              _status = 'Configuration loaded successfully';
            });
            if (_config.tfEnabled) {
              _scheduleTimeFrequencyRefresh(++_navigationSerial);
            }
          }
        } else {
          _setStatus('Configuration loaded');
        }
      } catch (e) {
        _setStatus('Error loading configuration: $e');
      }
    }
  }

  Future<void> _saveConfig() async {
    final String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Save Configuration',
      fileName: 'config.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );

    if (outputFile != null) {
      try {
        final json = jsonEncode(_config.toPythonJson());
        await File(outputFile).writeAsString(json);
        _setStatus('Configuration saved to $outputFile');
      } catch (e) {
        _setStatus('Error saving configuration: $e');
      }
    }
  }

  // ─── Configuration ────────────────────────────────────────────────────────

  void _openConfigDialog() {
    final v = _viewport;
    if (v == null) {
      _setStatus('Load an EDF first to configure channels');
      return;
    }
    showDialog(
      context: context,
      builder: (_) => ConfigDialog(
        config: _config,
        channelLabels: v.channelLabels,
        onPreview: _previewDisplayConfig,
        onApply: (newCfg) {
          setState(() {
            _config = newCfg;
          });
          if (_activePath != null) {
            saveAutoConfig(_activePath!, newCfg);
          }
          final eeg = _loadedEeg;
          if (eeg != null) {
            _backend.clearDisplayCache();
            // Recompute with new channel config
            _setStatus('Recomputing spectrogram for new channel…');
            Future.microtask(() async {
              final newEeg = await _backend.computeNightProducts(eeg, newCfg);
              final newViewport = await _backend.viewportFromEeg(
                newEeg,
                currentEpoch: v.currentEpoch,
                config: newCfg,
                existingStages: v.stages,
                existingStagesUncertain: v.stagesUncertain,
                includeTimeFrequency: false,
              );
              setState(() {
                _loadedEeg = newEeg;
                _viewport = newViewport;
                _status = 'Config applied — spectrogram channel updated';
              });
              if (_config.tfEnabled) {
                _scheduleTimeFrequencyRefresh(++_navigationSerial);
              }
            });
          }
        },
      ),
    );
  }

  void _openFilterDialog() {
    final v = _viewport;
    if (v == null) {
      _setStatus('Load an EDF first to configure filters');
      return;
    }
    showDialog(
      context: context,
      builder: (_) => FilterDialog(
        config: _config,
        channelLabels: v.channelLabels,
        onApply: (newCfg) {
          _previewDisplayConfig(newCfg);
          _setStatus('Filters applied');
        },
      ),
    );
  }

  void _previewDisplayConfig(AppConfig newCfg) {
    final eeg = _loadedEeg;
    final v = _viewport;
    if (eeg == null || v == null) {
      setState(() => _config = newCfg);
      return;
    }
    // Clear waveform cache so filter/display changes take immediate effect.
    _backend.clearDisplayCache();
    final rebuilt = _backend
        .rebuildViewportForEpochSync(v, eeg, v.currentEpoch, config: newCfg)
        .copyWith(stages: v.stages, stagesUncertain: v.stagesUncertain);
    setState(() {
      _config = newCfg;
      _viewport = rebuilt;
      _status = 'Configuration preview applied';
    });
    if (_activePath != null) {
      saveAutoConfig(_activePath!, newCfg);
    }
    if (_config.tfEnabled) {
      _scheduleTimeFrequencyRefresh(++_navigationSerial);
    }
  }


  // ─── Platform menus ───────────────────────────────────────────────────────

  List<PlatformMenuItem> _platformMenus() {
    final appMenuItems = <PlatformMenuItem>[
      if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.about))
        const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about)
      else
        const PlatformMenuItem(label: 'About ScoringNidra'),
      if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.quit))
        const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
    ];

    return [
      PlatformMenu(label: 'ScoringNidra', menus: appMenuItems),
      // ─── Data ─────────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Data',
        menus: [
          PlatformMenuItem(
            label: 'Load EDF file (.edf)',
            onSelected: () => _openRecording(kind: 'edf'),
          ),
          PlatformMenuItem(
            label: 'Load EDF file (.edf) – scaled from V to µV',
            onSelected: () => _openRecording(kind: 'edfvolt'),
          ),
          PlatformMenuItem(
            label: 'Load EEGLAB structure (.mat)',
            onSelected: () => _openRecording(kind: 'mat'),
          ),
          PlatformMenuItem(
            label: 'Load Zurich data file (.r09)',
            onSelected: () => _openRecording(kind: 'r09'),
          ),
          PlatformMenuItem(
            label: 'Close Current File',
            onSelected: _closeCurrentFile,
          ),
        ],
      ),
      // ─── Scoring ──────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Scoring',
        menus: [
          PlatformMenuItem(
            label: 'Load Scoring Hero (.json)',
            onSelected: () => _loadScoring('scoringhero'),
          ),
          PlatformMenuItem(
            label: 'Load Zurich Scoring (.vis)',
            onSelected: () => _loadScoring('vis'),
          ),
          PlatformMenuItem(
            label: 'Load YASA Scoring (.txt)',
            onSelected: () => _loadScoring('yasa'),
          ),
          PlatformMenuItem(
            label: 'Load Sleeptrip Scoring (.csv)',
            onSelected: () => _loadScoring('sleeptrip'),
          ),
          PlatformMenuItem(
            label: 'Load Sleeptrip Events (_events.csv)',
            onSelected: _loadSleeptripEvents,
          ),
          PlatformMenuItem(
            label: 'Load Sleepyland Scoring (.annot)',
            onSelected: () => _loadScoring('sleepyland'),
          ),
          PlatformMenuItem(
            label: 'Load GSSC Scoring (.csv)',
            onSelected: () => _loadScoring('gssc'),
          ),
          PlatformMenuItem(label: 'Save to…', onSelected: _saveScoring),
          PlatformMenuItem(
            label: 'Export Sleep Report (PDF)',
            onSelected: _exportSleepReport,
          ),
        ],
      ),
      // ─── Stages ───────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Stages',
        menus: [
          PlatformMenuItem(
            label: 'None  [Delete]',
            onSelected: () => _scoreCurrentEpoch(SleepStage.unknown),
          ),
          PlatformMenuItem(
            label: 'Wake  [W]',
            onSelected: () => _scoreCurrentEpoch(SleepStage.wake),
          ),
          PlatformMenuItem(
            label: 'N1  [1]',
            onSelected: () => _scoreCurrentEpoch(SleepStage.n1),
          ),
          PlatformMenuItem(
            label: 'N2  [2]',
            onSelected: () => _scoreCurrentEpoch(SleepStage.n2),
          ),
          PlatformMenuItem(
            label: 'N3  [3]',
            onSelected: () => _scoreCurrentEpoch(SleepStage.n3),
          ),
          PlatformMenuItem(
            label: 'REM  [R]',
            onSelected: () => _scoreCurrentEpoch(SleepStage.rem),
          ),
          PlatformMenuItem(
            label: 'Inconclusive  [I]',
            onSelected: () => _scoreCurrentEpoch(SleepStage.inconclusive),
          ),
          PlatformMenuItem(
            label: 'Toggle Uncertainty [Q]',
            onSelected: _toggleUncertainty,
          ),
        ],
      ),
      // ─── Events ───────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Events',
        menus: [
          PlatformMenuItem(label: 'Artefact', onSelected: () => _markEvent(0)),
          for (var i = 1; i <= 12; i++)
            PlatformMenuItem(
              label: 'Event $i',
              onSelected: () => _markEvent(i),
            ),
          PlatformMenuItem(
            label: 'Erase events in drawn selection [Backspace]',
            onSelected: _eraseEventsInSelections,
          ),
          PlatformMenuItem(
            label: 'Delete all events',
            onSelected: _deleteAllEvents,
          ),
        ],
      ),
      // ─── Utilities ────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Utilities',
        menus: [
          PlatformMenuItem(
            label: 'Filter  [Ctrl+F]',
            onSelected: _openFilterDialog,
          ),
          PlatformMenuItem(
            label: 'Auto Score (GSSC)  [Ctrl+G]',
            onSelected: () => _showPending(
              'GSSC autoscoring — external function call pending',
            ),
          ),
          PlatformMenuItem(
            label: 'K-Complex Detection (MT-KCD)  [Ctrl+K]',
            onSelected: _runKComplexDetection,
          ),
          PlatformMenuItem(
            label: 'Spindle Detection (MT-Spindle)  [Ctrl+Shift+S]',
            onSelected: _runSpindleDetection,
          ),
          PlatformMenuItem(
            label: 'Zoom on selected EEG  [Z]',
            onSelected: _zoomOnSelectedEeg,
          ),
        ],
      ),
      // ─── Compare ──────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Compare',
        menus: [
          PlatformMenuItem(
            label: 'Import scoring for comparison',
            onSelected: _loadComparisonScoring,
          ),
          PlatformMenuItem(
            label: 'Remove comparison scoring',
            onSelected: _removeComparisonScoring,
          ),
          PlatformMenuItem(
            label: 'Show summary statistics',
            onSelected: _showComparisonStats,
          ),
        ],
      ),
      // ─── Configuration ────────────────────────────────────────────────
      PlatformMenu(
        label: 'Configuration',
        menus: [
          PlatformMenuItem(
            label: 'Open configuration window  [Ctrl+C]',
            onSelected: _openConfigDialog,
          ),
          PlatformMenuItem(
            label: 'Save configuration as .json',
            onSelected: _saveConfig,
          ),
          PlatformMenuItem(
            label: 'Load configuration from .json',
            onSelected: _loadConfig,
          ),
          PlatformMenuItem(
            label: 'Restore default configuration',
            onSelected: () {
              final eeg = _loadedEeg;
              final v = _viewport;
              if (eeg != null && v != null) {
                final defaultConfig = AppConfig.defaultsForChannels(
                  eeg.channelLabels,
                  sampleRateHz: eeg.sampleRateHz,
                );
                setState(() {
                  _config = defaultConfig;
                });
                _setStatus('Restoring default configuration…');
                Future.microtask(() async {
                  final newEeg = await _backend.computeNightProducts(
                    eeg,
                    defaultConfig,
                  );
                  final newViewport = await _backend.viewportFromEeg(
                    newEeg,
                    currentEpoch: v.currentEpoch,
                    config: defaultConfig,
                    existingStages: v.stages,
                    includeTimeFrequency: false,
                  );
                  if (mounted) {
                    setState(() {
                      _loadedEeg = newEeg;
                      _viewport = newViewport;
                      _status = 'Default configuration restored';
                    });
                    if (_config.tfEnabled) {
                      _scheduleTimeFrequencyRefresh(++_navigationSerial);
                    }
                  }
                });
              }
            },
          ),
        ],
      ),
      // ─── Help ─────────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Help',
        menus: [
          PlatformMenuItem(
            label: 'Signal selection box  [Ctrl+H]',
            onSelected: _showSelectionHelp,
          ),
        ],
      ),
    ];
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final viewport = _viewport;

    return PlatformMenuBar(
      menus: _platformMenus(),
      child: Shortcuts(
        shortcuts: _shortcuts,
        child: Actions(
          actions: {
            _ScoreIntent: CallbackAction<_ScoreIntent>(
              onInvoke: (i) => _scoreCurrentEpoch(i.stage),
            ),
            _NextEpochIntent: CallbackAction<_NextEpochIntent>(
              onInvoke: (_) => _nextEpoch(),
            ),
            _PreviousEpochIntent: CallbackAction<_PreviousEpochIntent>(
              onInvoke: (_) => _previousEpoch(),
            ),
            _EventIntent: CallbackAction<_EventIntent>(
              onInvoke: (i) => _markEvent(i.digit),
            ),
            _EraseEventsIntent: CallbackAction<_EraseEventsIntent>(
              onInvoke: (_) => _eraseEventsInSelections(),
            ),
            _ZoomSelectionIntent: CallbackAction<_ZoomSelectionIntent>(
              onInvoke: (_) => _zoomOnSelectedEeg(),
            ),
            _ToggleUncertaintyIntent: CallbackAction<_ToggleUncertaintyIntent>(
              onInvoke: (_) => _toggleUncertainty(),
            ),
            _KComplexDetectionIntent: CallbackAction<_KComplexDetectionIntent>(
              onInvoke: (_) => _runKComplexDetection(),
            ),
            _SpindleDetectionIntent: CallbackAction<_SpindleDetectionIntent>(
              onInvoke: (_) => _runSpindleDetection(),
            ),
            _ConfigIntent: CallbackAction<_ConfigIntent>(
              onInvoke: (_) => _openConfigDialog(),
            ),
            _FilterIntent: CallbackAction<_FilterIntent>(
              onInvoke: (_) => _openFilterDialog(),
            ),
          },
          child: Focus(
            focusNode: _viewerFocusNode,
            autofocus: true,
            child: Scaffold(
              backgroundColor: const Color(0xFFEDEDED),
              body: Column(
                children: [
                  _Toolbar(
                    viewport: viewport,
                    onJump: _jumpToEpoch,
                    onPrevious: _previousEpoch,
                    onNext: _nextEpoch,
                    onUnscored: _jumpNextUnscored,
                    onUncertain: _jumpNextUncertain,
                    onTransition: _jumpNextTransition,
                    onHuman: _jumpNextHuman,
                    onEvent: _jumpNextEvent,
                    onDisagreement: _jumpNextDisagreement,
                    hasComparison: _comparisonStages != null,
                    onConfig: _openConfigDialog,
                    swaSlider: _swaSlider,
                    onSwaSlider: (v) => setState(() => _swaSlider = v),
                  ),
                  Expanded(
                    child: viewport == null
                        ? const Center(child: CircularProgressIndicator())
                        : _ScoringHeroSurface(
                            viewport: viewport,
                            onJump: (epoch) => _jumpToEpoch(epoch),
                            swaSlider: _swaSlider,
                            onSwaSlider: (v) => setState(() => _swaSlider = v),
                            onSelectionEnd: _updateSelection,
                          ),
                  ),
                  _StatusBar(
                    status: _status,
                    activePath: _activePath,
                    viewport: viewport,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Toolbar
// ─────────────────────────────────────────────────────────────────────────────

class _Toolbar extends StatefulWidget {
  const _Toolbar({
    required this.viewport,
    required this.onJump,
    required this.onPrevious,
    required this.onNext,
    required this.onUnscored,
    required this.onUncertain,
    required this.onTransition,
    required this.onHuman,
    required this.onEvent,
    required this.onDisagreement,
    required this.hasComparison,
    required this.onConfig,
    required this.swaSlider,
    required this.onSwaSlider,
  });

  final EegViewport? viewport;
  final void Function(int, [bool]) onJump;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onUnscored;
  final VoidCallback onUncertain;
  final VoidCallback onTransition;
  final VoidCallback onHuman;
  final VoidCallback onEvent;
  final VoidCallback onDisagreement;
  final bool hasComparison;
  final VoidCallback onConfig;
  final int swaSlider;
  final ValueChanged<int> onSwaSlider;

  @override
  State<_Toolbar> createState() => _ToolbarState();
}

class _ToolbarState extends State<_Toolbar> {
  late final TextEditingController _ctrl;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    final epoch = widget.viewport?.currentEpoch ?? 0;
    _ctrl = TextEditingController(text: '${epoch + 1}');
    _focusNode.addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    if (!_focusNode.hasFocus) {
      final val = int.tryParse(_ctrl.text);
      if (val != null && widget.viewport != null) {
        final clamped = val.clamp(1, widget.viewport!.epochCount);
        widget.onJump(clamped, true);
      } else {
        final epoch = widget.viewport?.currentEpoch ?? 0;
        _ctrl.text = '${epoch + 1}';
      }
    }
  }

  @override
  void didUpdateWidget(covariant _Toolbar old) {
    super.didUpdateWidget(old);
    final epoch = widget.viewport?.currentEpoch ?? 0;
    if (!_focusNode.hasFocus) {
      _ctrl.text = '${epoch + 1}';
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.viewport != null;
    return Material(
      color: const Color(0xFFF4F4F4),
      elevation: 1,
      child: SizedBox(
        height: 36,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              const SizedBox(width: 8),
              const Text('Jump to epoch:', style: TextStyle(fontSize: 14)),
              const SizedBox(width: 6),
              SizedBox(
                width: 56,
                height: 24,
                child: Shortcuts(
                  shortcuts: const <ShortcutActivator, Intent>{
                    SingleActivator(LogicalKeyboardKey.keyW): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.digit1): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.digit2): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.digit3): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.keyR): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.keyI): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.delete): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.keyA): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.f1): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.f2): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.f3): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.f4): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.f5): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.f6): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.f7): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.f8): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.f9): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.f10): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.f11): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.f12): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.backspace): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.keyZ): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.keyK, control: true): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.keyC, control: true): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.keyF, control: true): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.arrowRight): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.arrowLeft): DoNothingIntent(),
                    SingleActivator(LogicalKeyboardKey.keyQ): DoNothingIntent(),
                  },
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focusNode,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                    ),
                    style: const TextStyle(fontSize: 12),
                    onTapOutside: (_) => _focusNode.unfocus(),
                    onSubmitted: (_) => _focusNode.unfocus(),
                    onChanged: (text) {
                      final val = int.tryParse(text);
                      if (val != null && widget.viewport != null) {
                        final clamped = val.clamp(1, widget.viewport!.epochCount);
                        widget.onJump(clamped, false);
                      }
                    },
                  ),
                ),
              ),
              if (widget.viewport != null)
                Padding(
                  padding: const EdgeInsets.only(left: 3),
                  child: Text(
                    '/ ${widget.viewport!.epochCount}',
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                ),
              const SizedBox(width: 8),
              _ToolButton(
                label: '◀',
                enabled: enabled,
                onPressed: widget.onPrevious,
              ),
              _ToolButton(
                label: '▶',
                enabled: enabled,
                onPressed: widget.onNext,
              ),
              const SizedBox(width: 8),
              const _Divider(),
              _ToolButton(
                label: 'unscored',
                tooltip: 'Jump to next unscored epoch',
                enabled: enabled,
                onPressed: widget.onUnscored,
              ),
              _ToolButton(
                label: 'uncertain',
                tooltip: 'Jump to next inconclusive epoch',
                enabled: enabled,
                onPressed: widget.onUncertain,
              ),
              _ToolButton(
                label: 'transition',
                tooltip: 'Jump to next stage transition',
                enabled: enabled,
                onPressed: widget.onTransition,
              ),
              _ToolButton(
                label: 'event',
                tooltip: 'Jump to next epoch with events',
                enabled: enabled,
                onPressed: widget.onEvent,
              ),
              _ToolButton(
                label: 'human',
                tooltip: 'Jump to next human-scored epoch',
                enabled: enabled,
                onPressed: widget.onHuman,
              ),
              _ToolButton(
                label: 'disagreement',
                tooltip: widget.hasComparison
                    ? 'Jump to next scoring disagreement'
                    : 'Compare scoring not loaded',
                enabled: enabled && widget.hasComparison,
                onPressed: widget.onDisagreement,
              ),
              const SizedBox(width: 8),
              const _Divider(),
              _ToolButton(
                label: 'config',
                tooltip: 'Open channel and display configuration',
                enabled: enabled,
                onPressed: widget.onConfig,
              ),
              // Removed horizontal SWA slider (moved to vertical widget below)
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main scoring surface
// ─────────────────────────────────────────────────────────────────────────────

class _ScoringHeroSurface extends StatefulWidget {
  const _ScoringHeroSurface({
    required this.viewport,
    required this.onJump,
    required this.swaSlider,
    required this.onSwaSlider,
    required this.onSelectionEnd,
  });

  final EegViewport viewport;
  final ValueChanged<int> onJump;
  final int swaSlider;
  final ValueChanged<int> onSwaSlider;
  final void Function(
    double? startSec,
    double? endSec,
    int? channel,
    double? startUv,
    double? endUv,
  )
  onSelectionEnd;

  @override
  State<_ScoringHeroSurface> createState() => _ScoringHeroSurfaceState();
}

class _ScoringHeroSurfaceState extends State<_ScoringHeroSurface> {
  double? _dragStartSec;
  double? _dragEndSec;
  int? _dragChannel;
  double? _dragStartUv;
  double? _dragEndUv;

  void _handlePanStart(DragStartDetails details, BoxConstraints constraints) {
    final n = widget.viewport.channelCount;
    if (n == 0) return;
    final drawWidth = (constraints.maxWidth - _plotLeftPadding).clamp(
      1.0,
      double.infinity,
    );
    final fx = ((details.localPosition.dx - _plotLeftPadding) / drawWidth)
        .clamp(0.0, 1.0);
    final sec =
        widget.viewport.visibleStartSeconds +
        fx * widget.viewport.visibleDurationSeconds;

    final ch = (details.localPosition.dy / constraints.maxHeight * n)
        .floor()
        .clamp(0, n - 1);
    final baselineFraction = (ch + 0.5) / n;
    final yFrac = details.localPosition.dy / constraints.maxHeight;
    final normalizedVal = (baselineFraction - yFrac) * n / 0.42;
    final uv = normalizedVal * widget.viewport.amplitudeRangeUv;

    setState(() {
      _dragStartSec = sec;
      _dragEndSec = sec;
      _dragChannel = ch;
      _dragStartUv = uv;
      _dragEndUv = uv;
    });
  }

  void _handlePanUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    if (_dragStartSec == null || _dragChannel == null) return;
    final drawWidth = (constraints.maxWidth - _plotLeftPadding).clamp(
      1.0,
      double.infinity,
    );
    final fx = ((details.localPosition.dx - _plotLeftPadding) / drawWidth)
        .clamp(0.0, 1.0);
    final sec =
        widget.viewport.visibleStartSeconds +
        fx * widget.viewport.visibleDurationSeconds;

    final n = widget.viewport.channelCount;
    final baselineFraction = (_dragChannel! + 0.5) / n;
    final yFrac = details.localPosition.dy / constraints.maxHeight;
    final normalizedVal = (baselineFraction - yFrac) * n / 0.42;
    final uv = normalizedVal * widget.viewport.amplitudeRangeUv;

    setState(() {
      _dragEndSec = sec;
      _dragEndUv = uv;
    });
  }

  void _handlePanEnd(DragEndDetails details) {
    widget.onSelectionEnd(
      _dragStartSec,
      _dragEndSec,
      _dragChannel,
      _dragStartUv,
      _dragEndUv,
    );
    setState(() {
      _dragStartSec = null;
      _dragEndSec = null;
      _dragChannel = null;
      _dragStartUv = null;
      _dragEndUv = null;
    });
  }

  void _handlePanCancel() {
    widget.onSelectionEnd(null, null, null, null, null);
    setState(() {
      _dragStartSec = null;
      _dragEndSec = null;
      _dragChannel = null;
      _dragStartUv = null;
      _dragEndUv = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.white,
      child: Column(
        children: [
          // Top strip: spectrogram | hypnogram | SWA slider | power spectrum
          SizedBox(
            height: 158,
            child: Row(
              children: [
                Expanded(
                  flex: 50,
                  child: _ClickablePainterPanel(
                    painter: SpectrogramPainter(widget.viewport),
                    onTapFraction: (fx) {
                      final epoch = (fx * widget.viewport.epochCount).floor();
                      widget.onJump(epoch + 1);
                    },
                  ),
                ),
                Expanded(
                  flex: 27,
                  child: _ClickablePainterPanel(
                    painter: HypnogramPainter(
                      widget.viewport,
                      swaKernelSize: 101 - widget.swaSlider,
                    ),
                    onTapFraction: (fx) {
                      final epoch = (fx * widget.viewport.epochCount).floor();
                      widget.onJump(epoch + 1);
                    },
                  ),
                ),
                SizedBox(
                  width: 42,
                  child: _HypnogramSlider(
                    value: widget.swaSlider,
                    onChanged: widget.onSwaSlider,
                  ),
                ),
                Expanded(
                  flex: 12,
                  child: _Panel(
                    painter: RectanglePowerPainter(widget.viewport),
                  ),
                ),
              ],
            ),
          ),
          // Middle: EEG signal (largest panel)
          Expanded(
            flex: 74,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return GestureDetector(
                  onPanStart: (d) => _handlePanStart(d, constraints),
                  onPanUpdate: (d) => _handlePanUpdate(d, constraints),
                  onPanEnd: _handlePanEnd,
                  onPanCancel: _handlePanCancel,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _Panel(
                        painter: TimelinePainter(widget.viewport),
                        padding: EdgeInsets.zero,
                      ),
                      IgnorePointer(
                        child: CustomPaint(
                          painter: SelectionOverlayPainter(
                            widget.viewport,
                            activeDragStartSec: _dragStartSec,
                            activeDragEndSec: _dragEndSec,
                            activeDragChannel: _dragChannel,
                            activeDragStartUv: _dragStartUv,
                            activeDragEndUv: _dragEndUv,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          // Bottom: Time-Frequency panel
          Expanded(
            flex: 16,
            child: _Panel(painter: TimeFrequencyPainter(widget.viewport)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Status bar
// ─────────────────────────────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.status,
    required this.activePath,
    required this.viewport,
  });

  final String status;
  final String? activePath;
  final EegViewport? viewport;

  @override
  Widget build(BuildContext context) {
    final vp = viewport;
    final epochText = vp == null
        ? ''
        : 'Epoch ${vp.currentEpoch + 1}/${vp.epochCount}  |  ${vp.currentStage.label}  |  ${vp.sampleRateHz.toStringAsFixed(0)} Hz';
    return Container(
      height: 24,
      decoration: const BoxDecoration(
        color: Color(0xFFF2F2F2),
        border: Border(top: BorderSide(color: Color(0xFFCFCFCF))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          if (activePath != null)
            Flexible(
              child: Text(
                _basename(activePath!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          const SizedBox(width: 12),
          Text(epochText, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget helpers
// ─────────────────────────────────────────────────────────────────────────────

class _Panel extends StatelessWidget {
  const _Panel({required this.painter, this.padding = const EdgeInsets.all(1)});

  final CustomPainter painter;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFD0D0D0)),
          ),
          child: ClipRect(
            child: CustomPaint(painter: painter, child: const SizedBox.expand()),
          ),
        ),
      ),
    );
  }
}

class _ClickablePainterPanel extends StatelessWidget {
  const _ClickablePainterPanel({
    required this.painter,
    required this.onTapFraction,
  });

  final CustomPainter painter;
  final void Function(double fx) onTapFraction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(1),
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFD0D0D0)),
          ),
          child: GestureDetector(
            onTapDown: (details) {
              final rb = context.findRenderObject()! as RenderBox;
              final plotWidth = (rb.size.width - _plotLeftPadding).clamp(
                1.0,
                double.infinity,
              );
              final fx =
                  ((details.localPosition.dx - _plotLeftPadding) / plotWidth)
                      .clamp(0.0, 1.0);
              onTapFraction(fx);
            },
            onPanUpdate: (details) {
              final rb = context.findRenderObject()! as RenderBox;
              final plotWidth = (rb.size.width - _plotLeftPadding).clamp(
                1.0,
                double.infinity,
              );
              final fx =
                  ((details.localPosition.dx - _plotLeftPadding) / plotWidth)
                      .clamp(0.0, 1.0);
              onTapFraction(fx);
            },
            onPanDown: (details) {
              final rb = context.findRenderObject()! as RenderBox;
              final plotWidth = (rb.size.width - _plotLeftPadding).clamp(
                1.0,
                double.infinity,
              );
              final fx =
                  ((details.localPosition.dx - _plotLeftPadding) / plotWidth)
                      .clamp(0.0, 1.0);
              onTapFraction(fx);
            },
            child: ClipRect(
              child: CustomPaint(
                painter: painter,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HypnogramSlider extends StatelessWidget {
  const _HypnogramSlider({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 4.0),
          child: Text(
            'SWA',
            style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: Slider(
              value: value.toDouble(),
              min: 0,
              max: 100,
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
        ),
      ],
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.tooltip,
  });

  final String label;
  final bool enabled;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SizedBox(
        height: 24,
        child: OutlinedButton(
          onPressed: enabled ? onPressed : null,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: Size.zero,
          ),
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      ),
    );
    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: btn);
    }
    return btn;
  }
}

class _ZoomSignalPainter extends CustomPainter {
  const _ZoomSignalPainter(this.samples, this.sampleRate);

  final List<double> samples;
  final double sampleRate;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (samples.length < 2) return;
    final minV = samples.reduce(math.min);
    final maxV = samples.reduce(math.max);
    final range = math.max(maxV - minV, 1e-6);
    const pad = EdgeInsets.fromLTRB(44, 12, 12, 28);
    final plotW = size.width - pad.left - pad.right;
    final plotH = size.height - pad.top - pad.bottom;
    final axisPaint = Paint()
      ..color = Colors.black38
      ..strokeWidth = 0.8;
    canvas.drawRect(
      Rect.fromLTWH(pad.left, pad.top, plotW, plotH),
      Paint()
        ..color = Colors.black12
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6,
    );
    final zeroY = pad.top + (1.0 - (0.0 - minV) / range) * plotH;
    if (zeroY >= pad.top && zeroY <= pad.top + plotH) {
      canvas.drawLine(
        Offset(pad.left, zeroY),
        Offset(pad.left + plotW, zeroY),
        axisPaint,
      );
    }
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = pad.left + (i / (samples.length - 1)) * plotW;
      final y = pad.top + (1.0 - (samples[i] - minV) / range) * plotH;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke,
    );
    final duration = samples.length / sampleRate;
    _paintText(
      canvas,
      '0 s',
      Offset(pad.left, size.height - 12),
      TextAlign.left,
    );
    _paintText(
      canvas,
      '${duration.toStringAsFixed(2)} s',
      Offset(pad.left + plotW, size.height - 12),
      TextAlign.right,
    );
    _paintText(
      canvas,
      '${maxV.toStringAsFixed(1)} µV',
      Offset(4, pad.top + 6),
      TextAlign.left,
    );
    _paintText(
      canvas,
      '${minV.toStringAsFixed(1)} µV',
      Offset(4, pad.top + plotH - 6),
      TextAlign.left,
    );
  }

  void _paintText(Canvas canvas, String text, Offset offset, TextAlign align) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(fontSize: 11, color: Colors.black87),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(maxWidth: 140);
    var dx = offset.dx;
    if (align == TextAlign.right) dx -= painter.width;
    painter.paint(canvas, Offset(dx, offset.dy - painter.height / 2));
  }

  @override
  bool shouldRepaint(_ZoomSignalPainter oldDelegate) =>
      oldDelegate.samples != samples || oldDelegate.sampleRate != sampleRate;
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: const Color(0xFFCCCCCC),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Intents + Shortcuts
// ─────────────────────────────────────────────────────────────────────────────

class _ScoreIntent extends Intent {
  const _ScoreIntent(this.stage);
  final SleepStage stage;
}

class _NextEpochIntent extends Intent {
  const _NextEpochIntent();
}

class _PreviousEpochIntent extends Intent {
  const _PreviousEpochIntent();
}

class _ToggleUncertaintyIntent extends Intent {
  const _ToggleUncertaintyIntent();
}

class _EventIntent extends Intent {
  const _EventIntent(this.digit);
  final int digit;
}

class _EraseEventsIntent extends Intent {
  const _EraseEventsIntent();
}

class _ZoomSelectionIntent extends Intent {
  const _ZoomSelectionIntent();
}

class _KComplexDetectionIntent extends Intent {
  const _KComplexDetectionIntent();
}

class _SpindleDetectionIntent extends Intent {
  const _SpindleDetectionIntent();
}

class _ConfigIntent extends Intent {
  const _ConfigIntent();
}

class _FilterIntent extends Intent {
  const _FilterIntent();
}

final _shortcuts = <ShortcutActivator, Intent>{
  // Stage scoring
  const SingleActivator(LogicalKeyboardKey.keyW): const _ScoreIntent(
    SleepStage.wake,
  ),
  const SingleActivator(LogicalKeyboardKey.digit1): const _ScoreIntent(
    SleepStage.n1,
  ),
  const SingleActivator(LogicalKeyboardKey.digit2): const _ScoreIntent(
    SleepStage.n2,
  ),
  const SingleActivator(LogicalKeyboardKey.digit3): const _ScoreIntent(
    SleepStage.n3,
  ),
  const SingleActivator(LogicalKeyboardKey.keyR): const _ScoreIntent(
    SleepStage.rem,
  ),
  const SingleActivator(LogicalKeyboardKey.keyI): const _ScoreIntent(
    SleepStage.inconclusive,
  ),
  const SingleActivator(LogicalKeyboardKey.delete): const _ScoreIntent(
    SleepStage.unknown,
  ),
  const SingleActivator(LogicalKeyboardKey.keyA): const _EventIntent(0),
  const SingleActivator(LogicalKeyboardKey.f1): const _EventIntent(1),
  const SingleActivator(LogicalKeyboardKey.f2): const _EventIntent(2),
  const SingleActivator(LogicalKeyboardKey.f3): const _EventIntent(3),
  const SingleActivator(LogicalKeyboardKey.f4): const _EventIntent(4),
  const SingleActivator(LogicalKeyboardKey.f5): const _EventIntent(5),
  const SingleActivator(LogicalKeyboardKey.f6): const _EventIntent(6),
  const SingleActivator(LogicalKeyboardKey.f7): const _EventIntent(7),
  const SingleActivator(LogicalKeyboardKey.f8): const _EventIntent(8),
  const SingleActivator(LogicalKeyboardKey.f9): const _EventIntent(9),
  const SingleActivator(LogicalKeyboardKey.f10): const _EventIntent(10),
  const SingleActivator(LogicalKeyboardKey.f11): const _EventIntent(11),
  const SingleActivator(LogicalKeyboardKey.f12): const _EventIntent(12),
  const SingleActivator(LogicalKeyboardKey.backspace):
      const _EraseEventsIntent(),
  const SingleActivator(LogicalKeyboardKey.keyZ): const _ZoomSelectionIntent(),
  // Detections
  const SingleActivator(LogicalKeyboardKey.keyK, control: true):
      const _KComplexDetectionIntent(),
  const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true):
      const _SpindleDetectionIntent(),
  // Configuration & Filters
  const SingleActivator(LogicalKeyboardKey.keyC, control: true):
      const _ConfigIntent(),
  const SingleActivator(LogicalKeyboardKey.keyF, control: true):
      const _FilterIntent(),
  // Navigation
  const SingleActivator(LogicalKeyboardKey.arrowRight):
      const _NextEpochIntent(),
  const SingleActivator(LogicalKeyboardKey.arrowLeft):
      const _PreviousEpochIntent(),
  // Confidence uncertainty toggle
  const SingleActivator(LogicalKeyboardKey.keyQ): const _ToggleUncertaintyIntent(),
};

// ─────────────────────────────────────────────────────────────────────────────

String _basename(String path) => path.split(Platform.pathSeparator).last;

Future<List<(double, double)>> _runKComplexIsolate(
  List<double> signal,
  double sfreq,
  double amin,
  double dmax_s,
  double q,
  double fmax,
) {
  return Isolate.run(() {
    return sp.detectKComplex(
      signal,
      sfreq,
      amin: amin,
      dmax_s: dmax_s,
      q: q,
      fmax: fmax,
    );
  });
}

Future<List<(double, double)>> _runSpindleIsolate(
  List<double> signal,
  double sfreq,
  double fmin,
  double fmax,
  double amin,
  double dmin_s,
  double dmax_s,
  double q,
) {
  return Isolate.run(() {
    return sp.detectSpindles(
      signal,
      sfreq,
      fmin: fmin,
      fmax: fmax,
      amin: amin,
      dmin_s: dmin_s,
      dmax_s: dmax_s,
      q: q,
    );
  });
}
