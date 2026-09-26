import 'package:flutter/foundation.dart';

/// Immutable model representing media technical specifications.
@immutable
class MovieSpecs {
  final String resolution;
  final String resolutionBadge;
  final String videoCodec;
  final String videoProfile;
  final String audioCodec;
  final String audioChannels;
  final String container;
  final String fileSize;
  final String bitrate;
  final List<String> subtitles;
  final String aspectRatio;

  const MovieSpecs({
    this.resolution = '',
    this.resolutionBadge = '',
    this.videoCodec = '',
    this.videoProfile = '',
    this.audioCodec = '',
    this.audioChannels = '',
    this.container = '',
    this.fileSize = '',
    this.bitrate = '',
    this.subtitles = const [],
    this.aspectRatio = '',
  });

  factory MovieSpecs.fromJson(Map<String, dynamic> json) {
    List<String> parseSubtitles(dynamic val) {
      if (val is List) {
        return val
            .map((e) => e?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
      }
      return const [];
    }

    return MovieSpecs(
      resolution: json['resolution']?.toString() ?? '',
      resolutionBadge: json['resolution_badge']?.toString() ?? '',
      videoCodec: json['video_codec']?.toString() ?? '',
      videoProfile: json['video_profile']?.toString() ?? '',
      audioCodec: json['audio_codec']?.toString() ?? '',
      audioChannels: json['audio_channels']?.toString() ?? '',
      container: json['container']?.toString() ?? '',
      fileSize: json['file_size']?.toString() ?? '',
      bitrate: json['bitrate']?.toString() ?? '',
      subtitles: parseSubtitles(json['subtitles']),
      aspectRatio: json['aspect_ratio']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'resolution': resolution,
      'resolution_badge': resolutionBadge,
      'video_codec': videoCodec,
      'video_profile': videoProfile,
      'audio_codec': audioCodec,
      'audio_channels': audioChannels,
      'container': container,
      'file_size': fileSize,
      'bitrate': bitrate,
      'subtitles': subtitles,
      'aspect_ratio': aspectRatio,
    };
  }
}
