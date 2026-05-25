import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'models.dart';

class MatLoader {
  LoadedEeg load(String path) {
    final bytes = File(path).readAsBytesSync();
    if (bytes.length < 136 || ascii.decode(bytes.sublist(0, 6)) != 'MATLAB') {
      throw const FormatException('Only MATLAB v5 MAT files are supported.');
    }

    var offset = 128;
    while (offset + 8 <= bytes.length) {
      final tag = _Tag.read(bytes, offset);
      offset = tag.nextOffset;
      if (tag.type == _miCompressed) {
        final inflated = Uint8List.fromList(ZLibDecoder().convert(tag.data));
        final value = _readMatrixElement(inflated, 0).value;
        if (value.name == 'EEG') {
          return _eegFromStruct(value);
        }
      } else if (tag.type == _miMatrix) {
        final value = _readMatrix(tag.data, 0, tag.data.length).value;
        if (value.name == 'EEG') {
          return _eegFromStruct(value);
        }
      }
    }
    throw const FormatException('MAT file does not contain an EEG structure.');
  }

  LoadedEeg _eegFromStruct(_MatValue eeg) {
    final data = eeg.fields['data']?.first;
    final srate = eeg.fields['srate']?.first;
    final chanlocs = eeg.fields['chanlocs'] ?? const [];
    if (data == null || srate == null || data.numeric.isEmpty) {
      throw const FormatException(
        'EEG.data or EEG.srate missing from MAT file.',
      );
    }

    final channelCount = data.dims.isNotEmpty ? data.dims.first : 1;
    final sampleCount = data.dims.length > 1
        ? data.dims[1]
        : data.numeric.length;
    final channels = [
      for (var channel = 0; channel < channelCount; channel++)
        [
          for (var sample = 0; sample < sampleCount; sample++)
            data.numeric[channel + sample * channelCount],
        ],
    ];

    final labels = <String>[];
    for (final chanloc in chanlocs) {
      final label = chanloc.fields['labels']?.first.text;
      if (label != null && label.isNotEmpty) {
        labels.add(label);
      }
    }
    while (labels.length < channelCount) {
      labels.add('Ch ${labels.length + 1}');
    }

    return LoadedEeg(
      sampleRateHz: srate.numeric.first,
      channelLabels: labels.take(channelCount).toList(),
      channelSamples: channels,
      sourceDescription:
          '$channelCount channels, ${srate.numeric.first.toStringAsFixed(1)} Hz, ${(sampleCount / math.max(srate.numeric.first, 1) / 60).toStringAsFixed(1)} min',
    );
  }
}

const _miInt8 = 1;
const _miUint8 = 2;
const _miInt16 = 3;
const _miUint16 = 4;
const _miInt32 = 5;
const _miUint32 = 6;
const _miSingle = 7;
const _miDouble = 9;
const _miMatrix = 14;
const _miCompressed = 15;

const _mxCellClass = 1;
const _mxStructClass = 2;
const _mxCharClass = 4;

({_MatValue value, int next}) _readMatrixElement(Uint8List bytes, int offset) {
  final tag = _Tag.read(bytes, offset);
  if (tag.type != _miMatrix) {
    throw const FormatException('Expected miMATRIX element.');
  }
  final result = _readMatrix(tag.data, 0, tag.data.length);
  return (value: result.value, next: tag.nextOffset);
}

({_MatValue value, int next}) _readMatrix(
  Uint8List bytes,
  int offset,
  int end,
) {
  final flags = _Tag.read(bytes, offset);
  offset = flags.nextOffset;
  final classId = flags.data.isEmpty ? 0 : flags.data.first & 0xFF;

  final dimsTag = _Tag.read(bytes, offset);
  offset = dimsTag.nextOffset;
  final dims = _readInts(dimsTag.data, dimsTag.type);

  final nameTag = _Tag.read(bytes, offset);
  offset = nameTag.nextOffset;
  final name = ascii.decode(nameTag.data).replaceAll('\x00', '').trim();

  if (classId == _mxStructClass) {
    final fieldLengthTag = _Tag.read(bytes, offset);
    offset = fieldLengthTag.nextOffset;
    final fieldNameLength = _readInts(
      fieldLengthTag.data,
      fieldLengthTag.type,
    ).first;
    final fieldNamesTag = _Tag.read(bytes, offset);
    offset = fieldNamesTag.nextOffset;
    final fieldNames = <String>[];
    for (
      var i = 0;
      i + fieldNameLength <= fieldNamesTag.data.length;
      i += fieldNameLength
    ) {
      fieldNames.add(
        ascii
            .decode(fieldNamesTag.data.sublist(i, i + fieldNameLength))
            .replaceAll('\x00', '')
            .trim(),
      );
    }

    final elementCount = dims.fold<int>(1, (a, b) => a * b);
    final values = <String, List<_MatValue>>{
      for (final field in fieldNames) field: <_MatValue>[],
    };
    for (var element = 0; element < elementCount; element++) {
      for (final field in fieldNames) {
        if (offset >= end) {
          break;
        }
        final result = _readMatrixElement(bytes, offset);
        offset = result.next;
        values[field]!.add(result.value);
      }
    }
    return (
      value: _MatValue(name: name, dims: dims, fields: values),
      next: offset,
    );
  }

  if (classId == _mxCellClass) {
    final values = <_MatValue>[];
    while (offset < end) {
      final result = _readMatrixElement(bytes, offset);
      offset = result.next;
      values.add(result.value);
    }
    return (
      value: _MatValue(name: name, dims: dims, fields: {'cell': values}),
      next: offset,
    );
  }

  if (classId == _mxCharClass) {
    final textTag = offset < end ? _Tag.read(bytes, offset) : null;
    offset = textTag?.nextOffset ?? offset;
    return (
      value: _MatValue(
        name: name,
        dims: dims,
        text: textTag == null ? '' : _readText(textTag.data, textTag.type),
      ),
      next: offset,
    );
  }

  final numericTag = offset < end ? _Tag.read(bytes, offset) : null;
  offset = numericTag?.nextOffset ?? offset;
  return (
    value: _MatValue(
      name: name,
      dims: dims,
      numeric: numericTag == null
          ? const []
          : _readNumbers(numericTag.data, numericTag.type),
    ),
    next: offset,
  );
}

List<int> _readInts(Uint8List data, int type) {
  final bd = ByteData.sublistView(data);
  final values = <int>[];
  if (type == _miInt32 || type == _miUint32) {
    for (var i = 0; i + 4 <= data.length; i += 4) {
      values.add(bd.getInt32(i, Endian.little));
    }
  } else if (type == _miInt16 || type == _miUint16) {
    for (var i = 0; i + 2 <= data.length; i += 2) {
      values.add(bd.getInt16(i, Endian.little));
    }
  } else if (type == _miInt8 || type == _miUint8) {
    values.addAll(data);
  }
  return values;
}

List<double> _readNumbers(Uint8List data, int type) {
  final bd = ByteData.sublistView(data);
  final values = <double>[];
  if (type == _miDouble) {
    for (var i = 0; i + 8 <= data.length; i += 8) {
      values.add(bd.getFloat64(i, Endian.little));
    }
  } else if (type == _miSingle) {
    for (var i = 0; i + 4 <= data.length; i += 4) {
      values.add(bd.getFloat32(i, Endian.little));
    }
  } else {
    for (final value in _readInts(data, type)) {
      values.add(value.toDouble());
    }
  }
  return values;
}

String _readText(Uint8List data, int type) {
  if (type == _miUint16 || type == _miInt16) {
    final bd = ByteData.sublistView(data);
    final codes = <int>[];
    for (var i = 0; i + 2 <= data.length; i += 2) {
      final code = bd.getUint16(i, Endian.little);
      if (code != 0) {
        codes.add(code);
      }
    }
    return String.fromCharCodes(codes).trim();
  }
  return ascii.decode(data.where((byte) => byte != 0).toList()).trim();
}

class _Tag {
  const _Tag({
    required this.type,
    required this.data,
    required this.nextOffset,
  });

  final int type;
  final Uint8List data;
  final int nextOffset;

  static _Tag read(Uint8List bytes, int offset) {
    final bd = ByteData.sublistView(bytes);
    final rawType = bd.getUint32(offset, Endian.little);
    final smallBytes = rawType >> 16;
    if (smallBytes > 0) {
      final type = rawType & 0xFFFF;
      return _Tag(
        type: type,
        data: bytes.sublist(offset + 4, offset + 4 + smallBytes),
        nextOffset: offset + 8,
      );
    }

    final byteCount = bd.getUint32(offset + 4, Endian.little);
    final dataOffset = offset + 8;
    return _Tag(
      type: rawType,
      data: bytes.sublist(dataOffset, dataOffset + byteCount),
      nextOffset: dataOffset + byteCount + _padding(byteCount),
    );
  }
}

class _MatValue {
  const _MatValue({
    required this.name,
    required this.dims,
    this.numeric = const [],
    this.text = '',
    this.fields = const {},
  });

  final String name;
  final List<int> dims;
  final List<double> numeric;
  final String text;
  final Map<String, List<_MatValue>> fields;
}

int _padding(int length) {
  final remainder = length % 8;
  return remainder == 0 ? 0 : 8 - remainder;
}
