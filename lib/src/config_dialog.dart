// lib/src/config_dialog.dart
//
// Minimal configuration dialog — subset of ScoringHero-0.2.4 configurationWindow.py.
// Allows choosing the spectrogram channel, amplitude scale, and TF frequency range.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'eeg_backend.dart';

class ConfigDialog extends StatefulWidget {
  const ConfigDialog({
    super.key,
    required this.config,
    required this.channelLabels,
    required this.onApply,
  });

  final AppConfig config;
  final List<String> channelLabels;
  final void Function(AppConfig) onApply;

  @override
  State<ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<ConfigDialog> {
  late AppConfig _working;

  // Text controllers
  late final TextEditingController _amplCtrl;
  late final TextEditingController _tfMinCtrl;
  late final TextEditingController _tfMaxCtrl;
  late final TextEditingController _spectMinCtrl;
  late final TextEditingController _spectMaxCtrl;

  @override
  void initState() {
    super.initState();
    // Deep-copy the config so edits don't affect the live config
    _working = AppConfig(
      spectrogramChannelIndex: widget.config.spectrogramChannelIndex,
      periodogramChannelIndex: widget.config.periodogramChannelIndex,
      tfChannelIndex: widget.config.tfChannelIndex,
      amplitudeRangeUv: widget.config.amplitudeRangeUv,
      tfFreqMin: widget.config.tfFreqMin,
      tfFreqMax: widget.config.tfFreqMax,
      spectrogramPowerMin: widget.config.spectrogramPowerMin,
      spectrogramPowerMax: widget.config.spectrogramPowerMax,
    );
    _amplCtrl = TextEditingController(
      text: _working.amplitudeRangeUv.toStringAsFixed(1),
    );
    _tfMinCtrl = TextEditingController(
      text: _working.tfFreqMin.toStringAsFixed(2),
    );
    _tfMaxCtrl = TextEditingController(
      text: _working.tfFreqMax.toStringAsFixed(1),
    );
    _spectMinCtrl = TextEditingController(
      text: _working.spectrogramPowerMin.toStringAsFixed(1),
    );
    _spectMaxCtrl = TextEditingController(
      text: _working.spectrogramPowerMax.toStringAsFixed(1),
    );
  }

  @override
  void dispose() {
    _amplCtrl.dispose();
    _tfMinCtrl.dispose();
    _tfMaxCtrl.dispose();
    _spectMinCtrl.dispose();
    _spectMaxCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.channelLabels;
    return AlertDialog(
      title: const Text('Configuration'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ─── Spectrogram channel ────────────────────────────────────────
            const _SectionHeader('Spectrogram'),
            _ChannelDropdown(
              label: 'Channel',
              channelLabels: labels,
              value: _working.spectrogramChannelIndex.clamp(0, labels.length - 1),
              onChanged: (v) =>
                  setState(() => _working.spectrogramChannelIndex = v),
            ),
            _NumberRow(
              label: 'Power min (log₁₀)',
              controller: _spectMinCtrl,
              onChanged: (v) =>
                  _working.spectrogramPowerMin = v ?? _working.spectrogramPowerMin,
            ),
            _NumberRow(
              label: 'Power max (log₁₀)',
              controller: _spectMaxCtrl,
              onChanged: (v) =>
                  _working.spectrogramPowerMax = v ?? _working.spectrogramPowerMax,
            ),

            const SizedBox(height: 12),
            const _SectionHeader('Power Spectrum Panel'),
            _ChannelDropdown(
              label: 'Channel',
              channelLabels: labels,
              value: _working.periodogramChannelIndex.clamp(0, labels.length - 1),
              onChanged: (v) =>
                  setState(() => _working.periodogramChannelIndex = v),
            ),

            const SizedBox(height: 12),
            const _SectionHeader('Time-Frequency (Morlet)'),
            _ChannelDropdown(
              label: 'Channel',
              channelLabels: labels,
              value: _working.tfChannelIndex.clamp(0, labels.length - 1),
              onChanged: (v) => setState(() => _working.tfChannelIndex = v),
            ),
            _NumberRow(
              label: 'Freq min (Hz)',
              controller: _tfMinCtrl,
              onChanged: (v) =>
                  _working.tfFreqMin = v ?? _working.tfFreqMin,
            ),
            _NumberRow(
              label: 'Freq max (Hz)',
              controller: _tfMaxCtrl,
              onChanged: (v) =>
                  _working.tfFreqMax = v ?? _working.tfFreqMax,
            ),

            const SizedBox(height: 12),
            const _SectionHeader('EEG Display'),
            _NumberRow(
              label: 'Amplitude range (µV ±)',
              controller: _amplCtrl,
              onChanged: (v) =>
                  _working.amplitudeRangeUv = v ?? _working.amplitudeRangeUv,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            widget.onApply(_working);
            Navigator.of(context).pop();
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          text,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
      );
}

class _ChannelDropdown extends StatelessWidget {
  const _ChannelDropdown({
    required this.label,
    required this.channelLabels,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final List<String> channelLabels;
  final int value;
  final void Function(int) onChanged;

  @override
  Widget build(BuildContext context) {
    if (channelLabels.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 160,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: DropdownButtonFormField<int>(
              value: value,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              items: [
                for (var i = 0; i < channelLabels.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      '${i + 1}: ${channelLabels[i]}',
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _NumberRow extends StatelessWidget {
  const _NumberRow({
    required this.label,
    required this.controller,
    required this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final void Function(double?) onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 160,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: TextFormField(
              controller: controller,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true, signed: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(
                  RegExp(r'^-?\d*\.?\d*'),
                ),
              ],
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              style: const TextStyle(fontSize: 12),
              onChanged: (v) => onChanged(double.tryParse(v)),
            ),
          ),
        ],
      ),
    );
  }
}
