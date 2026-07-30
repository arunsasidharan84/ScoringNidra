import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// Class containing parameters for EDF modification
class EdfTransformOptions {
  bool downsample = false;
  double targetSampleRateHz = 200.0;

  bool cropTime = false;
  double startTimeSec = 0.0;
  double endTimeSec = 0.0;

  bool anonymizeHeader = false;
  String patientId = 'ANONYMOUS';
  String patientName = 'Anonymous';
  String patientSex = 'X';
  String birthdate = '01-JAN-1900';

  bool renameChannels = false;
  Map<String, String> channelNameMap = {};
  List<String> selectedChannels = [];
}

class EdfUtilitiesDialog extends StatefulWidget {
  const EdfUtilitiesDialog({
    super.key,
    this.initialEdfPath,
    this.availableChannels = const [],
  });

  final String? initialEdfPath;
  final List<String> availableChannels;

  @override
  State<EdfUtilitiesDialog> createState() => _EdfUtilitiesDialogState();
}

class _EdfUtilitiesDialogState extends State<EdfUtilitiesDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Single file state
  String? _inputFilePath;
  String? _outputFilePath;
  final EdfTransformOptions _singleOptions = EdfTransformOptions();
  final Map<String, String> _channelRenames = {};
  Set<String> _keptChannels = {};
  List<String> _currentChannels = [];

  // Batch state
  String? _batchInputDir;
  String? _batchOutputDir;
  final EdfTransformOptions _batchOptions = EdfTransformOptions();
  bool _isProcessing = false;
  double _progress = 0.0;
  String _statusText = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _inputFilePath = widget.initialEdfPath;
    _currentChannels = List<String>.from(widget.availableChannels);
    _keptChannels = Set<String>.from(_currentChannels);
    for (final ch in _currentChannels) {
      _channelRenames[ch] = ch;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _pickSingleInput() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['edf', 'EDF'],
      dialogTitle: 'Select Input EDF File',
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        _inputFilePath = result.files.single.path;
      });
    }
  }

  Future<void> _pickSingleOutput() async {
    final result = await FilePicker.saveFile(
      dialogTitle: 'Save Transformed EDF File',
      fileName: _inputFilePath != null
          ? '${File(_inputFilePath!).uri.pathSegments.last.replaceAll('.edf', '').replaceAll('.EDF', '')}_modified.edf'
          : 'output.edf',
      type: FileType.custom,
      allowedExtensions: ['edf'],
    );
    if (result != null) {
      setState(() {
        _outputFilePath = result;
      });
    }
  }

  Future<void> _pickBatchInputDir() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select Input Directory containing EDF files',
    );
    if (path != null) {
      setState(() {
        _batchInputDir = path;
      });
    }
  }

  Future<void> _pickBatchOutputDir() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select Output Directory for modified EDF files',
    );
    if (path != null) {
      setState(() {
        _batchOutputDir = path;
      });
    }
  }

  Future<void> _processSingleEdf() async {
    if (_inputFilePath == null) {
      _showToast('Please select an input EDF file.');
      return;
    }
    if (_outputFilePath == null) {
      await _pickSingleOutput();
      if (_outputFilePath == null) return;
    }

    setState(() {
      _isProcessing = true;
      _statusText = 'Transforming EDF file…';
    });

    try {
      _singleOptions.channelNameMap = _channelRenames;
      _singleOptions.selectedChannels = _keptChannels.toList();
      await processEdfFile(_inputFilePath!, _outputFilePath!, _singleOptions);
      if (mounted) {
        _showToast('Successfully exported EDF to $_outputFilePath');
      }
    } catch (e) {
      if (mounted) {
        _showToast('Error processing EDF: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _processBatchEdf() async {
    if (_batchInputDir == null || _batchOutputDir == null) {
      _showToast('Please select both input and output directories.');
      return;
    }

    final dir = Directory(_batchInputDir!);
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.edf'))
        .toList();

    if (files.isEmpty) {
      _showToast('No EDF files found in the selected input directory.');
      return;
    }

    setState(() {
      _isProcessing = true;
      _progress = 0.0;
      _statusText = 'Starting batch processing of ${files.length} EDF files…';
    });

    int count = 0;
    int success = 0;
    for (final file in files) {
      final baseName = file.uri.pathSegments.last;
      final outPath = '${_batchOutputDir!}/$baseName';
      setState(() {
        _statusText = 'Processing file ${count + 1}/${files.length}: $baseName';
        _progress = (count + 1) / files.length;
      });
      try {
        await processEdfFile(file.path, outPath, _batchOptions);
        success++;
      } catch (e) {
        debugPrint('Batch error on ${file.path}: $e');
      }
      count++;
    }

    if (mounted) {
      setState(() {
        _isProcessing = false;
        _statusText = 'Batch completed: $success / ${files.length} files processed successfully.';
      });
      _showToast('Batch processing complete ($success / ${files.length} success)');
    }
  }

  void _showToast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 780,
        height: 620,
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.build_circle_outlined, color: Colors.blue, size: 28),
                const SizedBox(width: 10),
                const Text(
                  'EDF Utilities — Reduce, Anonymize & Modify Header',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TabBar(
              controller: _tabController,
              labelColor: Colors.blue,
              unselectedLabelColor: Colors.grey,
              tabs: const [
                Tab(text: 'Single File Utility'),
                Tab(text: 'Batch EDF Processor'),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildSingleFileTab(),
                  _buildBatchTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSingleFileTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _inputFilePath != null
                              ? 'Input: $_inputFilePath'
                              : 'Select Input EDF file',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _pickSingleInput,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: const Text('Browse Input'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _outputFilePath != null
                              ? 'Output: $_outputFilePath'
                              : 'Select Output EDF file location',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _pickSingleOutput,
                        icon: const Icon(Icons.save, size: 18),
                        label: const Text('Save As…'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildOptionsSection(_singleOptions),
          const SizedBox(height: 12),
          if (_currentChannels.isNotEmpty) ...[
            const Text('Channel Renaming & Selection:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Container(
              height: 140,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(6),
              ),
              child: ListView.builder(
                itemCount: _currentChannels.length,
                itemBuilder: (ctx, idx) {
                  final ch = _currentChannels[idx];
                  final isKept = _keptChannels.contains(ch);
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                    child: Row(
                      children: [
                        Checkbox(
                          value: isKept,
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _keptChannels.add(ch);
                              } else {
                                _keptChannels.remove(ch);
                              }
                            });
                          },
                        ),
                        SizedBox(width: 80, child: Text(ch, style: const TextStyle(fontWeight: FontWeight.bold))),
                        const Icon(Icons.arrow_right_alt, size: 18, color: Colors.grey),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SizedBox(
                            height: 30,
                            child: TextField(
                              decoration: const InputDecoration(
                                isDense: true,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              ),
                              controller: TextEditingController(text: _channelRenames[ch] ?? ch),
                              onChanged: (val) {
                                _channelRenames[ch] = val.trim();
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
              onPressed: _isProcessing ? null : _processSingleEdf,
              icon: _isProcessing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.transform),
              label: Text(_isProcessing ? 'Processing…' : 'Process & Export EDF'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _batchInputDir != null ? 'Input Folder: $_batchInputDir' : 'Select Input Directory containing EDFs',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _pickBatchInputDir,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: const Text('Input Folder'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _batchOutputDir != null ? 'Output Folder: $_batchOutputDir' : 'Select Output Directory for transformed EDFs',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _pickBatchOutputDir,
                        icon: const Icon(Icons.folder, size: 18),
                        label: const Text('Output Folder'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildOptionsSection(_batchOptions),
          const SizedBox(height: 16),
          if (_isProcessing || _statusText.isNotEmpty) ...[
            LinearProgressIndicator(value: _isProcessing ? _progress : 1.0),
            const SizedBox(height: 8),
            Text(_statusText, style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
              onPressed: _isProcessing ? null : _processBatchEdf,
              icon: const Icon(Icons.dynamic_feed),
              label: Text(_isProcessing ? 'Processing Batch…' : 'Run Batch EDF Transformation'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOptionsSection(EdfTransformOptions opt) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Transformation Options:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),

            // Downsample
            Row(
              children: [
                Checkbox(
                  value: opt.downsample,
                  onChanged: (v) => setState(() => opt.downsample = v ?? false),
                ),
                const Text('Downsample to: '),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  height: 32,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), suffixText: 'Hz'),
                    controller: TextEditingController(text: opt.targetSampleRateHz.toStringAsFixed(0)),
                    onChanged: (v) => opt.targetSampleRateHz = double.tryParse(v) ?? opt.targetSampleRateHz,
                  ),
                ),
              ],
            ),

            // Crop
            Row(
              children: [
                Checkbox(
                  value: opt.cropTime,
                  onChanged: (v) => setState(() => opt.cropTime = v ?? false),
                ),
                const Text('Crop time between: '),
                const SizedBox(width: 8),
                SizedBox(
                  width: 70,
                  height: 32,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), suffixText: 's'),
                    controller: TextEditingController(text: opt.startTimeSec.toStringAsFixed(0)),
                    onChanged: (v) => opt.startTimeSec = double.tryParse(v) ?? opt.startTimeSec,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text('and'),
                ),
                SizedBox(
                  width: 70,
                  height: 32,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), suffixText: 's'),
                    controller: TextEditingController(text: opt.endTimeSec.toStringAsFixed(0)),
                    onChanged: (v) => opt.endTimeSec = double.tryParse(v) ?? opt.endTimeSec,
                  ),
                ),
              ],
            ),

            // Anonymize Header
            Row(
              children: [
                Checkbox(
                  value: opt.anonymizeHeader,
                  onChanged: (v) => setState(() => opt.anonymizeHeader = v ?? false),
                ),
                const Text('Anonymize Patient Header (Replace Name, ID & DOB)'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Helper function to transform and write EDF binary file
Future<void> processEdfFile(
  String inputPath,
  String outputPath,
  EdfTransformOptions options,
) async {
  final file = File(inputPath);
  if (!await file.exists()) throw Exception('Input EDF file does not exist.');

  final bytes = await file.readAsBytes();
  if (bytes.length < 256) throw Exception('File too small to be a valid EDF header.');

  // Parse basic primary header
  final headerStr = String.fromCharCodes(bytes.sublist(0, 256));
  final headerBytes = int.tryParse(headerStr.substring(184, 192).trim()) ?? 256;
  final numRecords = int.tryParse(headerStr.substring(236, 244).trim()) ?? -1;
  final recordDuration = double.tryParse(headerStr.substring(244, 252).trim()) ?? 1.0;
  final numSignals = int.tryParse(headerStr.substring(252, 256).trim()) ?? 0;

  if (numSignals <= 0) throw Exception('Invalid EDF: no signals declared.');

  // Extract signal headers
  final labels = <String>[];
  final samplesPerRec = <int>[];
  final physMin = <double>[];
  final physMax = <double>[];
  final digMin = <int>[];
  final digMax = <int>[];

  int offset = 256;
  for (int i = 0; i < numSignals; i++) {
    labels.add(String.fromCharCodes(bytes.sublist(offset + i * 16, offset + (i + 1) * 16)).trim());
  }
  offset += numSignals * 16; // Labels (16)
  offset += numSignals * 80; // Transducer (80)
  offset += numSignals * 8;  // Dimension (8)

  for (int i = 0; i < numSignals; i++) {
    physMin.add(double.tryParse(String.fromCharCodes(bytes.sublist(offset + i * 8, offset + (i + 1) * 8)).trim()) ?? -500.0);
  }
  offset += numSignals * 8;

  for (int i = 0; i < numSignals; i++) {
    physMax.add(double.tryParse(String.fromCharCodes(bytes.sublist(offset + i * 8, offset + (i + 1) * 8)).trim()) ?? 500.0);
  }
  offset += numSignals * 8;

  for (int i = 0; i < numSignals; i++) {
    digMin.add(int.tryParse(String.fromCharCodes(bytes.sublist(offset + i * 8, offset + (i + 1) * 8)).trim()) ?? -32768);
  }
  offset += numSignals * 8;

  for (int i = 0; i < numSignals; i++) {
    digMax.add(int.tryParse(String.fromCharCodes(bytes.sublist(offset + i * 8, offset + (i + 1) * 8)).trim()) ?? 32767);
  }
  offset += numSignals * 8;
  offset += numSignals * 80; // Prefilter (80)

  for (int i = 0; i < numSignals; i++) {
    samplesPerRec.add(int.tryParse(String.fromCharCodes(bytes.sublist(offset + i * 8, offset + (i + 1) * 8)).trim()) ?? 100);
  }

  // Determine signals to keep
  final keptIndices = <int>[];
  for (int i = 0; i < numSignals; i++) {
    final origLabel = labels[i];
    if (options.selectedChannels.isEmpty || options.selectedChannels.contains(origLabel)) {
      keptIndices.add(i);
    }
  }
  if (keptIndices.isEmpty) {
    for (int i = 0; i < numSignals; i++) keptIndices.add(i);
  }

  // Construct new header
  final newNumSignals = keptIndices.length;
  final newHeaderLen = 256 + newNumSignals * 256;

  String patientId = options.anonymizeHeader ? options.patientId : String.fromCharCodes(bytes.sublist(8, 88)).trim();
  String patientName = options.anonymizeHeader ? options.patientName : String.fromCharCodes(bytes.sublist(88, 168)).trim();

  StringBuffer newHdr = StringBuffer();
  newHdr.write('0'.padRight(8));
  newHdr.write(patientId.padRight(80));
  newHdr.write(patientName.padRight(80));
  newHdr.write(String.fromCharCodes(bytes.sublist(168, 176))); // Start date
  newHdr.write(String.fromCharCodes(bytes.sublist(176, 184))); // Start time
  newHdr.write(newHeaderLen.toString().padRight(8));
  newHdr.write('EDF+C'.padRight(44));
  newHdr.write(numRecords.toString().padRight(8));
  newHdr.write(recordDuration.toStringAsFixed(1).padRight(8));
  newHdr.write(newNumSignals.toString().padRight(4));

  // Write new signal attributes
  List<int> outBytes = [];
  outBytes.addAll(newHdr.toString().codeUnits);

  // Labels
  for (final idx in keptIndices) {
    String name = labels[idx];
    if (options.channelNameMap.containsKey(name) && options.channelNameMap[name]!.isNotEmpty) {
      name = options.channelNameMap[name]!;
    }
    outBytes.addAll(name.padRight(16).codeUnits.sublist(0, 16));
  }
  // Transducers
  for (int i = 0; i < newNumSignals; i++) outBytes.addAll(''.padRight(80).codeUnits);
  // Dimensions
  for (int i = 0; i < newNumSignals; i++) outBytes.addAll('uV'.padRight(8).codeUnits);
  // Phys min
  for (final idx in keptIndices) outBytes.addAll(physMin[idx].toStringAsFixed(2).padRight(8).codeUnits);
  // Phys max
  for (final idx in keptIndices) outBytes.addAll(physMax[idx].toStringAsFixed(2).padRight(8).codeUnits);
  // Dig min
  for (final idx in keptIndices) outBytes.addAll(digMin[idx].toString().padRight(8).codeUnits);
  // Dig max
  for (final idx in keptIndices) outBytes.addAll(digMax[idx].toString().padRight(8).codeUnits);
  // Prefilter
  for (int i = 0; i < newNumSignals; i++) outBytes.addAll(''.padRight(80).codeUnits);
  // Samples per record
  for (final idx in keptIndices) outBytes.addAll(samplesPerRec[idx].toString().padRight(8).codeUnits);
  // Reserved
  for (int i = 0; i < newNumSignals; i++) outBytes.addAll(''.padRight(32).codeUnits);

  // Copy raw signal payload for kept channels
  final totalBytesPerRec = samplesPerRec.reduce((a, b) => a + b) * 2;
  final totalRecs = numRecords > 0 ? numRecords : (bytes.length - headerBytes) ~/ totalBytesPerRec;

  int dataPos = headerBytes;
  for (int r = 0; r < totalRecs; r++) {
    if (dataPos + totalBytesPerRec > bytes.length) break;
    int recOffset = dataPos;
    for (int s = 0; s < numSignals; s++) {
      final sigLen = samplesPerRec[s] * 2;
      if (keptIndices.contains(s)) {
        outBytes.addAll(bytes.sublist(recOffset, recOffset + sigLen));
      }
      recOffset += sigLen;
    }
    dataPos += totalBytesPerRec;
  }

  final outFile = File(outputPath);
  await outFile.writeAsBytes(outBytes);
}
