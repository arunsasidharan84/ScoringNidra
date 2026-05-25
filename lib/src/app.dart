// lib/src/app.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config_dialog.dart';
import 'eeg_backend.dart';
import 'models.dart';
import 'scoring_io.dart';
import 'timeline_painter.dart';

class SleepEegApp extends StatelessWidget {
  const SleepEegApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Scoring Hero',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B6EA5),
          brightness: Brightness.light,
        ),
        useMaterial3: false,
        fontFamily: Platform.isMacOS ? '.AppleSystemUIFont' : null,
      ),
      home: const SleepEegHome(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class SleepEegHome extends StatefulWidget {
  const SleepEegHome({super.key});

  @override
  State<SleepEegHome> createState() => _SleepEegHomeState();
}

class _SleepEegHomeState extends State<SleepEegHome> {
  final EegBackend _backend = EegBackend();
  AppConfig _config = AppConfig();

  EegViewport? _viewport;
  LoadedEeg? _loadedEeg;
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
          : 'Load EDF file (.edf)',
      type: FileType.custom,
      allowedExtensions: kind == 'mat' ? ['mat'] : ['edf'],
    );
    final path = result?.files.single.path;
    if (path == null) {
      _setStatus('Open cancelled');
      return;
    }

    _setStatus('Loading ${_basename(path)} — computing spectrogram & wavelet…');
    await Future.microtask(() {}); // let the UI update

    try {
      final LoadedEeg rawEeg;
      if (kind == 'edf') {
        rawEeg = _backend.loadEdf(path, config: _config);
      } else if (kind == 'edfvolt') {
        rawEeg = _backend.loadEdf(
          path,
          scaleVoltsToMicrovolts: true,
          config: _config,
        );
      } else {
        rawEeg = _backend.loadMat(path, config: _config);
      }

      // Pre-compute night products including all-epoch Morlet TF in background
      _setStatus('Pre-computing wavelet transform for all epochs…');
      final eeg = await _backend.computeNightProducts(rawEeg, _config);

      // Try to auto-load an existing scoring JSON next to the EDF
      final epochCount = (eeg.durationSeconds / 30).ceil();
      final existingStages = await tryLoadAutoScoring(path, epochCount);

      final viewport = await _backend.viewportFromEeg(
        eeg,
        currentEpoch: 0,
        config: _config,
        existingStages: existingStages,
      );

      setState(() {
        _activePath = path;
        _loadedEeg = eeg;
        _viewport = viewport;
        _status =
            'Loaded ${_basename(path)} — '
            '${existingStages != null ? '${existingStages.where((s) => s.isScored).length}/${existingStages.length} epochs already scored' : 'scoring started'}';
      });
    } on UnsupportedError catch (e) {
      _setStatus(e.message ?? e.toString());
    } on Object catch (e) {
      _setStatus('Could not load ${_basename(path)}: $e');
    }
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
    autoSaveScoring(_activePath, newStages, viewport.epochSeconds);

    // Auto-advance to next epoch (matching Python score_stage.py)
    _nextEpoch();
  }

  // ─── Navigation ───────────────────────────────────────────────────────────

  void _nextEpoch() => _jumpRelative(1);
  void _previousEpoch() => _jumpRelative(-1);

  void _jumpRelative(int delta) {
    final v = _viewport;
    if (v == null) return;
    _jumpToEpoch(v.currentEpoch + 1 + delta);
  }

  Future<void> _jumpToEpoch(int epochOneBased) async {
    final v = _viewport;
    if (v == null) return;
    final epoch = (epochOneBased - 1).clamp(0, v.epochCount - 1);
    final eeg = _loadedEeg;
    final serial = ++_navigationSerial;

    EegViewport newViewport;
    if (eeg == null) {
      newViewport = v.copyWith(currentEpoch: epoch);
    } else {
      // With pre-computed epochTfPower this is an O(1) cache lookup.
      // rebuildViewportForEpoch will use eeg.epochTfPower[epoch] directly.
      final rebuilt = await _backend.rebuildViewportForEpoch(
        v,
        eeg,
        epoch,
        config: _config,
        includeTimeFrequency: _config.tfEnabled,
      );
      if (!mounted || serial != _navigationSerial) return;
      newViewport = rebuilt.copyWith(stages: v.stages);
    }

    if (mounted) {
      setState(() {
        _viewport = newViewport;
        _status =
            'Epoch ${epoch + 1} / ${v.epochCount}  |  ${v.stages[epoch].label}';
      });
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

  void _jumpNextUncertain() =>
      _jumpToNext((s) => s == SleepStage.inconclusive, 'uncertain');

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

  // ─── Selection ────────────────────────────────────────────────────────────

  Future<void> _updateSelection(double? startSec, double? endSec) async {
    final v = _viewport;
    final eeg = _loadedEeg;
    if (v == null || eeg == null) return;

    final newViewport = await _backend.updateSelection(
      v,
      eeg,
      startSec,
      endSec,
      config: _config,
    );
    if (mounted) {
      setState(() {
        _viewport = newViewport;
      });
    }
  }

  // ─── Scoring I/O ──────────────────────────────────────────────────────────

  Future<void> _loadScoring(String filetype) async {
    final v = _viewport;
    if (v == null) {
      _setStatus('Load an EDF first');
      return;
    }
    final stages = await importScoringDialog(
      v.epochCount,
      filetype,
      onStatus: _setStatus,
    );
    if (stages != null) {
      setState(() {
        _viewport = v.copyWith(stages: stages);
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
      onStatus: _setStatus,
    );
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
        final json = jsonDecode(content) as Map<String, dynamic>;
        final newCfg = AppConfig.fromJson(json);

        setState(() {
          _config = newCfg;
        });

        final eeg = _loadedEeg;
        final v = _viewport;
        if (eeg != null && v != null) {
          _setStatus('Applying loaded configuration…');
          final newEeg = _backend.computeNightProducts(eeg, newCfg);
          final newViewport = await _backend.viewportFromEeg(
            newEeg,
            currentEpoch: v.currentEpoch,
            config: newCfg,
            existingStages: v.stages,
          );
          if (mounted) {
            setState(() {
              _loadedEeg = newEeg;
              _viewport = newViewport;
              _status = 'Configuration loaded successfully';
            });
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
        final json = jsonEncode(_config.toJson());
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
        onApply: (newCfg) {
          setState(() {
            _config = newCfg;
          });
          final eeg = _loadedEeg;
          if (eeg != null) {
            // Recompute with new channel config
            _setStatus('Recomputing spectrogram for new channel…');
            Future.microtask(() async {
              final newEeg = _backend.computeNightProducts(eeg, newCfg);
              final newViewport = await _backend.viewportFromEeg(
                newEeg,
                currentEpoch: v.currentEpoch,
                config: newCfg,
                existingStages: v.stages,
              );
              setState(() {
                _loadedEeg = newEeg;
                _viewport = newViewport;
                _status = 'Config applied — spectrogram channel updated';
              });
            });
          }
        },
      ),
    );
  }

  // ─── Platform menus ───────────────────────────────────────────────────────

  List<PlatformMenuItem> _platformMenus() {
    return [
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
            onSelected: () => _showPending('R09 data loading'),
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
            onSelected: () => _showPending('Sleeptrip event import'),
          ),
          PlatformMenuItem(
            label: 'Load Sleepyland Scoring (.annot)',
            onSelected: () => _showPending('Sleepyland scoring import'),
          ),
          PlatformMenuItem(
            label: 'Load GSSC Scoring (.csv)',
            onSelected: () => _showPending('GSSC scoring import'),
          ),
          PlatformMenuItem(label: 'Save to…', onSelected: _saveScoring),
          PlatformMenuItem(
            label: 'Export Sleep Report (PDF)',
            onSelected: () => _showPending('Sleep report export'),
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
        ],
      ),
      // ─── Events ───────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Events',
        menus: [
          PlatformMenuItem(
            label: 'Artefact',
            onSelected: () => _showPending('Artefact event labelling'),
          ),
          for (var i = 1; i <= 12; i++)
            PlatformMenuItem(
              label: 'Event $i',
              onSelected: () => _showPending('Event $i labelling'),
            ),
          PlatformMenuItem(
            label: 'Erase events in drawn selection [Backspace]',
            onSelected: () => _showPending('Event erasing'),
          ),
          PlatformMenuItem(
            label: 'Delete all events',
            onSelected: () => _showPending('Event deletion'),
          ),
        ],
      ),
      // ─── Utilities ────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Utilities',
        menus: [
          PlatformMenuItem(
            label: 'Filter  [Ctrl+F]',
            onSelected: () => _showPending(
              'Filter window — add provision for external tool call',
            ),
          ),
          PlatformMenuItem(
            label: 'Auto Score (GSSC)  [Ctrl+G]',
            onSelected: () => _showPending(
              'GSSC autoscoring — external function call pending',
            ),
          ),
          PlatformMenuItem(
            label: 'K-Complex Detection (MT-KCD)  [Ctrl+K]',
            onSelected: () =>
                _showPending('MT-KCD — external function call pending'),
          ),
          PlatformMenuItem(
            label: 'Spindle Detection (MT-Spindle)  [Ctrl+Shift+S]',
            onSelected: () =>
                _showPending('MT-Spindle — external function call pending'),
          ),
          PlatformMenuItem(
            label: 'Zoom on selected EEG  [Z]',
            onSelected: () => _showPending('Zoom on selected EEG'),
          ),
        ],
      ),
      // ─── Compare ──────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Compare',
        menus: [
          PlatformMenuItem(
            label: 'Import scoring for comparison',
            onSelected: () => _showPending('Comparison scoring import'),
          ),
          PlatformMenuItem(
            label: 'Remove comparison scoring',
            onSelected: () => _showPending('Comparison scoring removal'),
          ),
          PlatformMenuItem(
            label: 'Show summary statistics',
            onSelected: () => _showPending('Comparison statistics'),
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
              setState(() {
                _config = AppConfig();
              });
              final eeg = _loadedEeg;
              final v = _viewport;
              if (eeg != null && v != null) {
                _setStatus('Restoring default configuration…');
                Future.microtask(() async {
                  final newEeg = _backend.computeNightProducts(eeg, _config);
                  final newViewport = await _backend.viewportFromEeg(
                    newEeg,
                    currentEpoch: v.currentEpoch,
                    config: _config,
                    existingStages: v.stages,
                  );
                  if (mounted) {
                    setState(() {
                      _loadedEeg = newEeg;
                      _viewport = newViewport;
                      _status = 'Default configuration restored';
                    });
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
            onSelected: () => _showPending('Signal selection help'),
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
          },
          child: Focus(
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
                    swaSlider: _swaSlider,
                    onSwaSlider: (v) => setState(() => _swaSlider = v),
                  ),
                  Expanded(
                    child: viewport == null
                        ? const Center(child: CircularProgressIndicator())
                        : _ScoringHeroSurface(
                            viewport: viewport,
                            onJump: _jumpToEpoch,
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
    required this.swaSlider,
    required this.onSwaSlider,
  });

  final EegViewport? viewport;
  final ValueChanged<int> onJump;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onUnscored;
  final VoidCallback onUncertain;
  final VoidCallback onTransition;
  final VoidCallback onHuman;
  final int swaSlider;
  final ValueChanged<int> onSwaSlider;

  @override
  State<_Toolbar> createState() => _ToolbarState();
}

class _ToolbarState extends State<_Toolbar> {
  late final TextEditingController _ctrl = TextEditingController(text: '1');

  @override
  void didUpdateWidget(covariant _Toolbar old) {
    super.didUpdateWidget(old);
    final epoch = widget.viewport?.currentEpoch ?? 0;
    _ctrl.text = '${epoch + 1}';
  }

  @override
  void dispose() {
    _ctrl.dispose();
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
              const Text('Epoch:', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 4),
              SizedBox(
                width: 56,
                height: 24,
                child: TextField(
                  controller: _ctrl,
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
                  onSubmitted: (v) => widget.onJump(int.tryParse(v) ?? 1),
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
                tooltip: 'Jump to next epoch with events (not yet implemented)',
                enabled: false,
                onPressed: () {},
              ),
              _ToolButton(
                label: 'human',
                tooltip: 'Jump to next human-scored epoch',
                enabled: enabled,
                onPressed: widget.onHuman,
              ),
              _ToolButton(
                label: 'disagreement',
                tooltip: 'Compare scoring not loaded',
                enabled: false,
                onPressed: () {},
              ),
              const SizedBox(width: 8),
              const _Divider(),
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
  final void Function(double? startSec, double? endSec) onSelectionEnd;

  @override
  State<_ScoringHeroSurface> createState() => _ScoringHeroSurfaceState();
}

class _ScoringHeroSurfaceState extends State<_ScoringHeroSurface> {
  double? _dragStartSec;
  double? _dragEndSec;

  void _handlePanStart(DragStartDetails details, BoxConstraints constraints) {
    final fx = details.localPosition.dx / constraints.maxWidth;
    final sec =
        widget.viewport.visibleStartSeconds +
        fx * widget.viewport.visibleDurationSeconds;
    setState(() {
      _dragStartSec = sec;
      _dragEndSec = sec;
    });
  }

  void _handlePanUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    if (_dragStartSec == null) return;
    final fx = details.localPosition.dx / constraints.maxWidth;
    final sec =
        widget.viewport.visibleStartSeconds +
        fx * widget.viewport.visibleDurationSeconds;
    setState(() {
      _dragEndSec = sec;
    });
  }

  void _handlePanEnd(DragEndDetails details) {
    widget.onSelectionEnd(_dragStartSec, _dragEndSec);
    setState(() {
      _dragStartSec = null;
      _dragEndSec = null;
    });
  }

  void _handlePanCancel() {
    widget.onSelectionEnd(null, null);
    setState(() {
      _dragStartSec = null;
      _dragEndSec = null;
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
            height: 118,
            child: Row(
              children: [
                Expanded(
                  flex: 56,
                  child: _ClickablePainterPanel(
                    painter: SpectrogramPainter(widget.viewport),
                    onTapFraction: (fx) {
                      final epoch = (fx * widget.viewport.epochCount).floor();
                      widget.onJump(epoch + 1);
                    },
                  ),
                ),
                Expanded(
                  flex: 30,
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
                  width: 22,
                  child: _HypnogramSlider(
                    value: widget.swaSlider,
                    onChanged: widget.onSwaSlider,
                  ),
                ),
                Expanded(
                  flex: 13,
                  child: _Panel(
                    painter: RectanglePowerPainter(widget.viewport),
                  ),
                ),
              ],
            ),
          ),
          // Middle: EEG signal (largest panel)
          Expanded(
            flex: 68,
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
            flex: 17,
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFD0D0D0)),
        ),
        child: CustomPaint(painter: painter, child: const SizedBox.expand()),
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFD0D0D0)),
        ),
        child: GestureDetector(
          onTapUp: (details) {
            final rb = context.findRenderObject()! as RenderBox;
            final fx = details.localPosition.dx / rb.size.width;
            onTapFraction(fx.clamp(0.0, 1.0));
          },
          child: CustomPaint(painter: painter, child: const SizedBox.expand()),
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
  // Navigation
  const SingleActivator(LogicalKeyboardKey.arrowRight):
      const _NextEpochIntent(),
  const SingleActivator(LogicalKeyboardKey.arrowLeft):
      const _PreviousEpochIntent(),
};

// ─────────────────────────────────────────────────────────────────────────────

String _basename(String path) => path.split(Platform.pathSeparator).last;
