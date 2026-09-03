import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class SyncedVideoPanel extends StatefulWidget {
  const SyncedVideoPanel({
    super.key,
    required this.videoPath,
    required this.controller,
    required this.currentEegSeconds,
    required this.offsetSeconds,
    required this.onOffsetChanged,
    required this.onClose,
    required this.onTogglePlayPause,
    required this.isPlaying,
  });

  final String videoPath;
  final VideoPlayerController controller;
  final double currentEegSeconds;
  final double offsetSeconds;
  final ValueChanged<double> onOffsetChanged;
  final VoidCallback onClose;
  final VoidCallback onTogglePlayPause;
  final bool isPlaying;

  @override
  State<SyncedVideoPanel> createState() => _SyncedVideoPanelState();
}

class _SyncedVideoPanelState extends State<SyncedVideoPanel> {
  bool _isMuted = false;
  late final TextEditingController _offsetCtrl;

  @override
  void initState() {
    super.initState();
    _offsetCtrl = TextEditingController(text: widget.offsetSeconds.toStringAsFixed(2));
  }

  @override
  void didUpdateWidget(covariant SyncedVideoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.offsetSeconds - widget.offsetSeconds).abs() > 0.001) {
      _offsetCtrl.text = widget.offsetSeconds.toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _offsetCtrl.dispose();
    super.dispose();
  }

  String _formatTime(double seconds) {
    final s = seconds.toInt();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isInit = widget.controller.value.isInitialized;
    final videoPos = widget.controller.value.position.inMilliseconds / 1000.0;
    final videoDur = widget.controller.value.duration.inMilliseconds / 1000.0;

    final fileName = widget.videoPath.split(Platform.pathSeparator).last;

    return Container(
      width: 380,
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        border: Border.all(color: const Color(0xFF475569)),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 8,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: const BoxDecoration(
              color: Color(0xFF0F172A),
              borderRadius: BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Row(
              children: [
                const Icon(Icons.videocam, size: 16, color: Color(0xFF38BDF8)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    fileName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: isInit ? const Color(0xFF22C55E) : const Color(0xFFF59E0B),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: widget.onClose,
                  child: const Icon(Icons.close, size: 16, color: Colors.white70),
                ),
              ],
            ),
          ),

          // Video Display
          Container(
            height: 220,
            color: Colors.black,
            child: isInit
                ? Center(
                    child: AspectRatio(
                      aspectRatio: widget.controller.value.aspectRatio > 0
                          ? widget.controller.value.aspectRatio
                          : 16 / 9,
                      child: VideoPlayer(widget.controller),
                    ),
                  )
                : const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                        SizedBox(height: 8),
                        Text('Initializing video…', style: TextStyle(color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
          ),

          // Playback & Time Info
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    widget.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                    color: Colors.white,
                    size: 26,
                  ),
                  onPressed: isInit ? widget.onTogglePlayPause : null,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(
                    _isMuted ? Icons.volume_off : Icons.volume_up,
                    color: Colors.white70,
                    size: 18,
                  ),
                  onPressed: isInit
                      ? () {
                          setState(() {
                            _isMuted = !_isMuted;
                            widget.controller.setVolume(_isMuted ? 0.0 : 1.0);
                          });
                        }
                      : null,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const Spacer(),
                Text(
                  '${_formatTime(videoPos)} / ${_formatTime(videoDur)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),

          // Sync Offset Controls
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: const BoxDecoration(
              color: Color(0xFF0F172A),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(7)),
            ),
            child: Row(
              children: [
                const Text(
                  'Sync Offset:',
                  style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 6),
                _OffsetButton(
                  label: '-1s',
                  onTap: () => widget.onOffsetChanged(widget.offsetSeconds - 1.0),
                ),
                const SizedBox(width: 3),
                _OffsetButton(
                  label: '-0.1s',
                  onTap: () => widget.onOffsetChanged(widget.offsetSeconds - 0.1),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 54,
                  height: 20,
                  child: TextField(
                    controller: _offsetCtrl,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                    decoration: const InputDecoration(
                      contentPadding: EdgeInsets.zero,
                      isDense: true,
                      border: OutlineInputBorder(borderSide: BorderSide(color: Colors.white30)),
                    ),
                    onSubmitted: (v) {
                      final val = double.tryParse(v);
                      if (val != null) widget.onOffsetChanged(val);
                    },
                  ),
                ),
                const SizedBox(width: 4),
                _OffsetButton(
                  label: '+0.1s',
                  onTap: () => widget.onOffsetChanged(widget.offsetSeconds + 0.1),
                ),
                const SizedBox(width: 3),
                _OffsetButton(
                  label: '+1s',
                  onTap: () => widget.onOffsetChanged(widget.offsetSeconds + 1.0),
                ),
                const Spacer(),
                InkWell(
                  onTap: () => widget.onOffsetChanged(0.0),
                  child: const Text('Reset', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 11)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OffsetButton extends StatelessWidget {
  const _OffsetButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFF334155),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 10)),
      ),
    );
  }
}
