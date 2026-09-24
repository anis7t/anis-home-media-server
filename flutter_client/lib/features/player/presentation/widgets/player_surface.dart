import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Isolated video rendering surface.
///
/// Keeps the native Direct3D video texture isolated from overlay widget rebuilds.
class PlayerSurface extends StatelessWidget {
  final VideoController controller;
  final BoxFit fit;

  const PlayerSurface({
    super.key,
    required this.controller,
    this.fit = BoxFit.contain,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      width: double.infinity,
      height: double.infinity,
      child: Center(
        child: Video(
          controller: controller,
          fit: fit,
          controls: NoVideoControls,
        ),
      ),
    );
  }
}
