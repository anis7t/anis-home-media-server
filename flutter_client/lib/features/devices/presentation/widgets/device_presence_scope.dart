import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/device_presence_controller.dart';

/// Starts device presence tracking and keeps it in step with the app lifecycle.
///
/// Mounted once around the app in `main.dart` (not inside `MediaServerApp`), so
/// widget tests that build the app directly never open a heartbeat timer.
class DevicePresenceScope extends ConsumerStatefulWidget {
  final Widget child;

  const DevicePresenceScope({super.key, required this.child});

  @override
  ConsumerState<DevicePresenceScope> createState() => _DevicePresenceScopeState();
}

class _DevicePresenceScopeState extends ConsumerState<DevicePresenceScope>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Instantiating the controller registers the device and schedules the
    // periodic heartbeat while the app is in the foreground.
    ref.read(devicePresenceControllerProvider);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref.read(devicePresenceControllerProvider.notifier).handleLifecycle(state);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
