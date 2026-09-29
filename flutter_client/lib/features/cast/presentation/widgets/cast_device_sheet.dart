import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/cast_device.dart';
import '../controllers/cast_controller.dart';

/// Device picker for casting: lists what the server found (DLNA renderers and
/// Chromecasts), starts playback on the chosen one and can stop an active session.
class CastDeviceSheet extends ConsumerStatefulWidget {
  /// The file to cast. Null means the sheet only manages the active session.
  final String? filename;
  final Duration? position;

  /// Called with the device name once playback has been handed over, so the caller
  /// can show its own feedback (the player shows a HUD toast).
  final ValueChanged<String>? onStarted;

  const CastDeviceSheet({super.key, this.filename, this.position, this.onStarted});

  static Future<void> show({
    required BuildContext context,
    String? filename,
    Duration? position,
    ValueChanged<String>? onStarted,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => CastDeviceSheet(
        filename: filename,
        position: position,
        onStarted: onStarted,
      ),
    );
  }

  @override
  ConsumerState<CastDeviceSheet> createState() => _CastDeviceSheetState();
}

class _CastDeviceSheetState extends ConsumerState<CastDeviceSheet> {
  @override
  void initState() {
    super.initState();
    // Discover after the first frame: the provider must not be written during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(castControllerProvider.notifier).discover(refresh: true);
    });
  }

  Future<void> _select(CastDevice device) async {
    final filename = widget.filename;
    if (filename == null) return;
    final navigator = Navigator.of(context);
    final onStarted = widget.onStarted;
    final error = await ref.read(castControllerProvider.notifier).castTo(
          device,
          filename,
          position: widget.position,
        );
    if (!mounted) return;
    if (error == null) {
      onStarted?.call(device.name);
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(castControllerProvider);
    final controller = ref.read(castControllerProvider.notifier);

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF141822),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        border: Border(top: BorderSide(color: Color(0x33FFFFFF), width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.72),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 8),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.cast_rounded, color: Color(0xFFFF334B), size: 20),
                    const SizedBox(width: 10),
                    const Text(
                      'Cast to device',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Search again',
                      icon: const Icon(Icons.refresh_rounded, color: Colors.white70, size: 20),
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      onPressed: state.scanning ? null : () => controller.discover(refresh: true),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(color: Color(0x1FFFFFFF), height: 1),
              if (state.scanning)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Row(
                    children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 12),
                      Text('Searching your network…', style: TextStyle(color: Colors.white70, fontSize: 13)),
                    ],
                  ),
                ),
              if (state.error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                  child: Text(
                    state.error!,
                    style: const TextStyle(color: Color(0xFFFF8A8A), fontSize: 12.5, height: 1.35),
                  ),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final device in state.devices) _tile(device, state),
                    if (!state.scanning && state.devices.isEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 18, 20, 22),
                        child: Text(
                          'No cast devices found.\n'
                          'Make sure the TV is switched on and on this Wi-Fi network, then tap refresh.',
                          style: TextStyle(color: Colors.white60, fontSize: 13, height: 1.45),
                        ),
                      ),
                    if (state.isCasting)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                        child: TextButton.icon(
                          onPressed: () async {
                            final navigator = Navigator.of(context);
                            await controller.sendControl('stop');
                            if (mounted) navigator.pop();
                          },
                          icon: const Icon(Icons.stop_circle_outlined, size: 18),
                          label: Text('Stop casting to ${state.activeDevice?.name ?? ''}'),
                          style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF334B)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(CastDevice device, CastState state) {
    final isActive = state.activeDevice?.id == device.id;
    return InkWell(
      onTap: state.busy || widget.filename == null ? null : () => _select(device),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Icon(device.icon, color: isActive ? const Color(0xFFFF334B) : Colors.white70, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isActive ? const Color(0xFFFF334B) : Colors.white,
                      fontSize: 15,
                      fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                  Text(
                    [device.protocolLabel, if (device.model.isNotEmpty) device.model]
                        .join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (isActive)
              const Text('CASTING', style: TextStyle(color: Color(0xFFFF334B), fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
