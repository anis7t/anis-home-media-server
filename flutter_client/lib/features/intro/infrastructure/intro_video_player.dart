import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// The television's **pre-rendered** brand opening sequence.
///
/// ## Why a video
///
/// The Fire TV's GPU is a 2015 PowerVR Rogue GE8300 with OpenGL ES 3.2 and
/// **no Vulkan**. Impeller, which compiles every pipeline at build time and
/// removes shader compilation jank by design, therefore cannot be used there,
/// and Skia on OpenGL ES compiles each new draw program **at runtime**, inside
/// the frame that needs it.
///
/// Measured on that television, the live sequence's first frame took **1.09
/// seconds** to raster, and the three-second sequence got **five frames**.
///
/// A pre-rendered video removes the problem: the GPU decodes frames instead of
/// generating them. That is also how the streaming applications get their
/// smoothness - their openings are pre-rendered too.
///
/// ## What the video is
///
/// It is rendered from the **shipped web application**, which is the
/// canonical, by `scripts/capture-intro-video.mjs`, and it is verified against
/// the canonical's reference frames by `scripts/verify-intro-video.mjs`.
///
/// The video carries **no audio**: the score is the canonical's own WAV,
/// played by `audioplayers` beside it, and anchored to the video's playback
/// position rather than to a clock.
///
/// The video is the television's **only** rendering of the sequence. The phone
/// keeps the live one, because the phone is not that device.
class IntroVideoPlayer {
  IntroVideoPlayer({Player? player}) : _player = player ?? Player() {
    _videoController = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        // The platform rules: on the MediaTek and PowerVR devices a zero-copy
        // `mediacodec` surface deadlocks on the display fence, so the frames
        // are copied. `auto` elsewhere.
        hwdec: defaultTargetPlatform == TargetPlatform.android
            ? 'mediacodec-copy'
            : 'auto',
      ),
    );
  }

  final Player _player;
  late final VideoController _videoController;

  /// The controller the `Video` widget renders from.
  VideoController get videoController => _videoController;

  /// The position in the sequence.
  Duration get position => _player.state.position;

  /// Whether the video has played to its end.
  bool get isComplete => _player.state.completed;

  /// Opens the video and starts it.
  Future<void> open(String assetPath) async {
    await _player.open(Media('asset://$assetPath'), play: false);
    // The video carries no audio track; the score is played beside it.
    await _player.setVolume(0);
    await _player.play();
  }

  /// Stops the video.
  Future<void> stop() async {
    await _player.stop();
  }

  /// Releases the player and its texture.
  Future<void> dispose() async {
    await _player.dispose();
  }
}
