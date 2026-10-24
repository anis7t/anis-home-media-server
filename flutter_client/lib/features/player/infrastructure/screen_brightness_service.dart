import 'package:flutter/services.dart';

/// Window brightness for the player.
///
/// Android maps this to `WindowManager.LayoutParams.screenBrightness`, which
/// overrides the system level while the window is focused - exactly what a
/// player wants - and needs no permission. `null`/negative restores the system
/// default, which is what [restore] does when the player goes away.
///
/// Every failure is swallowed (a desktop host or a widget test has no plugin):
/// a brightness gesture must never break playback.
class ScreenBrightnessService {
  ScreenBrightnessService({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel(
              'in.anisparvez.media_server_client/screen_brightness',
            );

  final MethodChannel _channel;

  /// False once the platform has told us it has no brightness support.
  bool supported = true;

  /// [value] is 0.0-1.0. Returns false when the platform cannot do it.
  Future<bool> setBrightness(double value) async {
    if (!supported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('setBrightness', {
        'value': value.clamp(0.0, 1.0),
      });
      return ok ?? false;
    } on MissingPluginException {
      supported = false;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// The window's current brightness override, or null when it follows the system.
  Future<double?> currentBrightness() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<double>('getBrightness');
    } on MissingPluginException {
      supported = false;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Hand brightness back to the system.
  Future<void> restore() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('setBrightness', {'value': -1.0});
    } catch (_) {
      // Leaving the player must never fail on this.
    }
  }
}