import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/models.dart';
import 'package:ccs_sleep_studio/src/marker_io.dart';

void main() {
  group('Marker & Annotation IO Tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('marker_io_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('parses BrainVision .vmrk file', () async {
      final vhdrPath = '${tempDir.path}/rec.vhdr';
      final vmrkPath = '${tempDir.path}/rec.vmrk';
      File(vhdrPath).writeAsStringSync('BrainVision header dummy');
      File(vmrkPath).writeAsStringSync('''
Brain Vision Data Exchange Marker File, Version 1.0

[Common Infos]
Codepage=UTF-8
DataFile=rec.eeg

[Marker Infos]
; Each entry: Mk<Number>=<Type>,<Description>,<Position in data points>,<Size in data points>,<Channel number>
Mk1=New Segment,,1,1,0,20240101120000000000
Mk2=Comment,Lights Off,201,0,0
Mk3=Stimulus,S  1,1001,0,1
Mk4=Sync,SyncPoint,2001,400,2
''');

      final markers = await tryLoadAllMarkers(
        vhdrPath,
        sampleRateHz: 200.0,
        channelLabels: ['F3', 'C3'],
      );

      expect(markers.length, greaterThanOrEqualTo(3));
      final lightsOff = markers.firstWhere((m) => m.label == 'Lights Off');
      expect(lightsOff.startSec, closeTo(1.0, 0.01));
      expect(lightsOff.isPointMarker, isTrue);

      final syncPt = markers.firstWhere((m) => m.label == 'SyncPoint');
      expect(syncPt.startSec, closeTo(10.0, 0.01));
      expect(syncPt.durationSeconds, closeTo(2.0, 0.01));
      expect(syncPt.channel, equals('C3'));
      expect(syncPt.isPointMarker, isFalse);
    });

    test('parses Nihon Kohden .LOG file', () async {
      final eegPath = '${tempDir.path}/patient.eeg';
      final logPath = '${tempDir.path}/patient.LOG';
      File(eegPath).writeAsStringSync('NK dummy');
      File(logPath).writeAsStringSync('''
# NK Event Log
22:30:15.000 Lights Out
22:35:00.500 Body Movement
''');

      final startTime = DateTime(2024, 1, 1, 22, 30, 0);
      final markers = await tryLoadAllMarkers(
        eegPath,
        sampleRateHz: 200.0,
        recordingStartTime: startTime,
      );

      expect(markers.length, equals(2));
      expect(markers[0].label, equals('Lights Out'));
      expect(markers[0].startSec, closeTo(15.0, 0.01));
      expect(markers[1].label, equals('Body Movement'));
      expect(markers[1].startSec, closeTo(300.5, 0.01));
    });

    test('parses Profusion XML events', () async {
      final eegPath = '${tempDir.path}/psg.edf';
      final xmlPath = '${tempDir.path}/psg.xml';
      File(eegPath).writeAsStringSync('EDF dummy');
      File(xmlPath).writeAsStringSync('''<?xml version="1.0"?>
<ScoredEvents>
  <ScoredEvent>
    <Name>Arousal</Name>
    <Start>120.5</Start>
    <Duration>4.2</Duration>
    <Input>C3</Input>
  </ScoredEvent>
  <ScoredEvent>
    <Name>Obstructive Apnea</Name>
    <Start>350.0</Start>
    <Duration>18.0</Duration>
    <Input>Flow</Input>
  </ScoredEvent>
</ScoredEvents>''');

      final markers = await tryLoadAllMarkers(eegPath);
      expect(markers.length, equals(2));
      expect(markers[0].label, equals('Arousal'));
      expect(markers[0].startSec, closeTo(120.5, 0.01));
      expect(markers[0].durationSeconds, closeTo(4.2, 0.01));
      expect(markers[0].channel, equals('C3'));
      expect(markers[1].label, equals('Obstructive Apnea'));
      expect(markers[1].durationSeconds, closeTo(18.0, 0.01));
    });

    test('parses CSV annotation events', () async {
      final edfPath = '${tempDir.path}/study.edf';
      final csvPath = '${tempDir.path}/study_events.csv';
      File(edfPath).writeAsStringSync('EDF dummy');
      File(csvPath).writeAsStringSync('''onset,duration,label,channel
60.0,1.5,Spindle,C3
180.25,0.0,Spike,F4
''');

      final markers = await tryLoadAllMarkers(edfPath);
      expect(markers.length, equals(2));
      expect(markers[0].label, equals('Spindle'));
      expect(markers[0].durationSeconds, closeTo(1.5, 0.01));
      expect(markers[0].channel, equals('C3'));
      expect(markers[1].label, equals('Spike'));
      expect(markers[1].isPointMarker, isTrue);
      expect(markers[1].channel, equals('F4'));
    });
  });
}
