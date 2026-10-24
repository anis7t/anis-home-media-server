import 'package:flutter/services.dart';

/// System media volume for the player's right-half swipe.
///
/// This is the level the phone's volume keys control and the level the user
/// actually hears; the app's own player volume is separate and stays at full.
/// Android maps it to `AudioManager.STREAM_MUSIC` (no permission needed).
///
/// Every failure is swallowed: a volume gesture must never break playback, and
/// a desktop host or widget test has no plugin.
class MediaVolumeService {
  MediaVolumeService({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel(
              'in.anisparvez.media_server_client/media_volume',
            );

  final MethodChannel _channel;

  /// False once the platform has told us it has no volume support.
  bool supported = true;

  /// Current system media volume as 0-100, or null when unavailable.
  Future<int?> getVolume() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<int>('getVolume');
    } on MissingPluginException {
      supported = false;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// [percent] is 0-100. Returns false when the platform cannot do it.
  Future<bool> setVolume(int percent) async {
    if (!supported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('setVolume', {
        'percent': percent.clamp(0, 100),
      });
      return ok ?? false;
    } on MissingPluginException {
      supported = false;
      return false;
    } catch (_) {
      return false;
    }
  }
}
