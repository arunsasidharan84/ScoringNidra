// lib/src/scoring_io.dart
//
// Scoring file I/O — port of ScoringHero-0.2.4 scoring/ module.
// Supports read/write for: ScoringHero JSON, YASA .txt, Sleeptrip .csv, Zurich .vis

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Auto-save (ScoringHero JSON) – called after every stage change
// ─────────────────────────────────────────────────────────────────────────────

/// Write stages to the ScoringHero JSON file next to the source EDF/MAT.
/// If [activePath] is null (demo mode), no file is written.
Future<void> autoSaveScoring(
  String? activePath,
  List<SleepStage> stages,
  int epochSeconds,
) async {
  if (activePath == null) return;
  final jsonPath = _jsonPathForEdf(activePath);
  try {
    await _writeJsonScoring(jsonPath, stages, epochSeconds, activePath);
  } catch (_) {
    // Auto-save failure is non-fatal
  }
}

/// Load scoring from the JSON file that lives next to the EDF (auto-loaded on open).
Future<List<SleepStage>?> tryLoadAutoScoring(
  String activePath,
  int epochCount,
) async {
  final jsonPath = _jsonPathForEdf(activePath);
  final file = File(jsonPath);
  if (!file.existsSync()) return null;
  try {
    return await _loadJsonScoring(jsonPath, epochCount);
  } catch (_) {
    return null;
  }
}

String _jsonPathForEdf(String edfPath) {
  final dotIdx = edfPath.lastIndexOf('.');
  final base = dotIdx >= 0 ? edfPath.substring(0, dotIdx) : edfPath;
  return '$base.json';
}

// ─────────────────────────────────────────────────────────────────────────────
// ScoringHero JSON format
// ─────────────────────────────────────────────────────────────────────────────

/// JSON format (array of stage dicts, matching Python write_scoring.py):
/// [
///   {"epoch": 1, "start": 0.0, "end": 30.0, "stage": "N2", "digit": -2,
///    "confidence": null, "channels": [], "clean": 1, "source": "human"},
///   ...
/// ]
Future<void> _writeJsonScoring(
  String path,
  List<SleepStage> stages,
  int epochSeconds,
  String edfPath,
) async {
  final entries = <Map<String, dynamic>>[];
  for (var i = 0; i < stages.length; i++) {
    final stage = stages[i];
    entries.add({
      'epoch': i + 1,
      'start': i * epochSeconds.toDouble(),
      'end': (i + 1) * epochSeconds.toDouble(),
      'stage': stage.isScored ? stage.label : null,
      'digit': stage.isScored ? stage.code : null,
      'confidence': null,
      'channels': <String>[],
      'clean': 1,
      'source': stage.isScored ? 'human' : null,
    });
  }
  final json = [entries, <dynamic>[]]; // [stages_list, annotations_list]
  await File(path).writeAsString(
    const JsonEncoder.withIndent('  ').convert(json),
  );
}

Future<List<SleepStage>> _loadJsonScoring(String path, int epochCount) async {
  final content = await File(path).readAsString();
  final dynamic json = jsonDecode(content);

  List<dynamic> entries;
  if (json is List && json.isNotEmpty && json[0] is List) {
    // [stages_list, annotations_list] format
    entries = json[0] as List<dynamic>;
  } else if (json is List) {
    entries = json;
  } else {
    return List.filled(epochCount, SleepStage.unknown);
  }

  final stages = List.filled(epochCount, SleepStage.unknown);
  for (final entry in entries) {
    if (entry is Map<String, dynamic>) {
      final epochOneBased = (entry['epoch'] as num?)?.toInt();
      if (epochOneBased == null) continue;
      final idx = epochOneBased - 1;
      if (idx < 0 || idx >= epochCount) continue;
      final stageStr = entry['stage'] as String?;
      stages[idx] = SleepStage.fromLabel(stageStr);
    }
  }
  return stages;
}

// ─────────────────────────────────────────────────────────────────────────────
// Import dialog — pick file and parse
// ─────────────────────────────────────────────────────────────────────────────

/// Show a file picker and import a scoring file. Returns the parsed stages list,
/// or null if cancelled or failed. [onStatus] is called with status messages.
Future<List<SleepStage>?> importScoringDialog(
  int epochCount,
  String filetype, {
  required void Function(String) onStatus,
}) async {
  String dialogTitle;
  List<String> extensions;
  switch (filetype) {
    case 'scoringhero':
      dialogTitle = 'Load ScoringHero scoring (.json)';
      extensions = ['json'];
    case 'yasa':
      dialogTitle = 'Load YASA scoring (.txt)';
      extensions = ['txt'];
    case 'sleeptrip':
      dialogTitle = 'Load Sleeptrip scoring (.csv)';
      extensions = ['csv'];
    case 'vis':
      dialogTitle = 'Load Zurich scoring (.vis)';
      extensions = ['vis'];
    default:
      dialogTitle = 'Load scoring file';
      extensions = ['json', 'txt', 'csv', 'vis'];
  }

  final result = await FilePicker.pickFiles(
    dialogTitle: dialogTitle,
    type: FileType.custom,
    allowedExtensions: extensions,
  );
  final path = result?.files.single.path;
  if (path == null) {
    onStatus('Import cancelled');
    return null;
  }

  try {
    final stages = await _parseScoringFile(path, filetype, epochCount);
    onStatus('Loaded scoring from ${_basename(path)} — ${stages.where((s) => s.isScored).length}/${stages.length} epochs scored');
    return stages;
  } catch (e) {
    onStatus('Failed to load scoring: $e');
    return null;
  }
}

Future<List<SleepStage>> _parseScoringFile(
  String path,
  String filetype,
  int epochCount,
) async {
  switch (filetype) {
    case 'scoringhero':
      return _loadJsonScoring(path, epochCount);
    case 'yasa':
      return _loadYasaScoring(path, epochCount);
    case 'sleeptrip':
      return _loadSleetripScoring(path, epochCount);
    case 'vis':
      return _loadVisScoring(path, epochCount);
    default:
      throw UnsupportedError('Unknown scoring format: $filetype');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// YASA format  (.txt — one stage per line: W, N1, N2, N3, R)
// ─────────────────────────────────────────────────────────────────────────────

Future<List<SleepStage>> _loadYasaScoring(String path, int epochCount) async {
  final lines = (await File(path).readAsString())
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  final stages = List.filled(epochCount, SleepStage.unknown);
  for (var i = 0; i < lines.length && i < epochCount; i++) {
    stages[i] = _stageFromYasaLabel(lines[i]);
  }
  return stages;
}

SleepStage _stageFromYasaLabel(String label) {
  switch (label.toUpperCase()) {
    case 'W':
      return SleepStage.wake;
    case 'N1':
      return SleepStage.n1;
    case 'N2':
      return SleepStage.n2;
    case 'N3':
      return SleepStage.n3;
    case 'N4':
      return SleepStage.n3; // treat N4 as N3
    case 'R':
    case 'REM':
      return SleepStage.rem;
    default:
      return SleepStage.unknown;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sleeptrip CSV format (.csv — has "stage" column)
// ─────────────────────────────────────────────────────────────────────────────

Future<List<SleepStage>> _loadSleetripScoring(String path, int epochCount) async {
  final lines = (await File(path).readAsString()).split('\n');
  if (lines.isEmpty) return List.filled(epochCount, SleepStage.unknown);

  // Find header row
  final header = lines[0].split(',').map((h) => h.trim().toLowerCase()).toList();
  final stageCol = header.indexOf('stage');
  if (stageCol < 0) throw FormatException('No "stage" column in Sleeptrip CSV');

  final stages = List.filled(epochCount, SleepStage.unknown);
  var row = 0;
  for (var i = 1; i < lines.length && row < epochCount; i++) {
    final parts = lines[i].split(',');
    if (parts.length <= stageCol) continue;
    stages[row] = _stageFromYasaLabel(parts[stageCol].trim());
    row++;
  }
  return stages;
}

// ─────────────────────────────────────────────────────────────────────────────
// Zurich VIS format (.vis)
// ─────────────────────────────────────────────────────────────────────────────

/// Zurich .vis format: lines beginning with digits are stage codes.
/// Stage mapping (from load_vis.py):
///   0 → Wake, 1 → N1, 2 → N2, 3 → N3, 4 → N3, 5 → REM, 8 → unknown
Future<List<SleepStage>> _loadVisScoring(String path, int epochCount) async {
  final lines = (await File(path).readAsString()).split('\n');
  final stages = List.filled(epochCount, SleepStage.unknown);
  var row = 0;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || !_isDigitStr(trimmed[0])) continue;
    // Stage code is typically a single digit, possibly with suffix
    final code = int.tryParse(trimmed.split(RegExp(r'\s+'))[0]);
    if (code == null || row >= epochCount) break;
    stages[row] = _stageFromVisCode(code);
    row++;
  }
  return stages;
}

bool _isDigitStr(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;

SleepStage _stageFromVisCode(int code) {
  switch (code) {
    case 0:
      return SleepStage.wake;
    case 1:
      return SleepStage.n1;
    case 2:
      return SleepStage.n2;
    case 3:
    case 4:
      return SleepStage.n3;
    case 5:
      return SleepStage.rem;
    default:
      return SleepStage.unknown;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Export dialog — choose format and write file
// ─────────────────────────────────────────────────────────────────────────────

Future<void> exportScoringDialog(
  List<SleepStage> stages,
  int epochSeconds,
  String? activePath, {
  required void Function(String) onStatus,
}) async {
  final formats = ['ScoringHero JSON (.json)', 'YASA (.txt)', 'Sleeptrip (.csv)', 'Zurich (.vis)'];
  final ext = ['json', 'txt', 'csv', 'vis'];

  String? savePath = await FilePicker.saveFile(
    dialogTitle: 'Save scoring as',
    type: FileType.any,
  );
  if (savePath == null) {
    onStatus('Save cancelled');
    return;
  }

  // Determine format from extension
  String filetype = 'scoringhero';
  for (var i = 0; i < ext.length; i++) {
    if (savePath.toLowerCase().endsWith('.${ext[i]}')) {
      filetype = ['scoringhero', 'yasa', 'sleeptrip', 'vis'][i];
      break;
    }
  }
  // Default to json if no recognised extension
  if (!savePath.contains('.')) savePath = '$savePath.json';

  try {
    await _writeScoringFile(savePath, stages, epochSeconds, filetype, activePath);
    onStatus('Saved scoring to ${_basename(savePath)}');
  } catch (e) {
    onStatus('Failed to save: $e');
  }
}

Future<void> _writeScoringFile(
  String path,
  List<SleepStage> stages,
  int epochSeconds,
  String filetype,
  String? activePath,
) async {
  switch (filetype) {
    case 'scoringhero':
      await _writeJsonScoring(path, stages, epochSeconds, activePath ?? path);
    case 'yasa':
      await _writeYasa(path, stages);
    case 'sleeptrip':
      await _writeSleeptrip(path, stages, epochSeconds);
    case 'vis':
      await _writeVis(path, stages);
  }
}

Future<void> _writeYasa(String path, List<SleepStage> stages) async {
  final lines = stages.map((s) {
    switch (s) {
      case SleepStage.wake: return 'W';
      case SleepStage.n1: return 'N1';
      case SleepStage.n2: return 'N2';
      case SleepStage.n3: return 'N3';
      case SleepStage.rem: return 'R';
      default: return 'W'; // export unscored as Wake to avoid blank lines
    }
  });
  await File(path).writeAsString(lines.join('\n'));
}

Future<void> _writeSleeptrip(
  String path,
  List<SleepStage> stages,
  int epochSeconds,
) async {
  final buf = StringBuffer('epoch,start,end,stage\n');
  for (var i = 0; i < stages.length; i++) {
    buf.write('${i + 1},${i * epochSeconds},${(i + 1) * epochSeconds},');
    buf.writeln(stages[i].label);
  }
  await File(path).writeAsString(buf.toString());
}

Future<void> _writeVis(String path, List<SleepStage> stages) async {
  final codes = stages.map((s) {
    switch (s) {
      case SleepStage.wake: return 0;
      case SleepStage.n1: return 1;
      case SleepStage.n2: return 2;
      case SleepStage.n3: return 3;
      case SleepStage.rem: return 5;
      default: return 8;
    }
  });
  await File(path).writeAsString(codes.join('\n'));
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

String _basename(String path) {
  final sep = Platform.pathSeparator;
  return path.split(sep).last;
}
