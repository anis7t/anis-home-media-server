/// Represents a quality tier in the dynamic quality ladder.
class QualityOption {
  final String label;
  final String quality;
  final int height;
  final int width;
  final int bitrate;
  final bool isDirect;
  final bool isReady;
  final String? hlsUrl;

  const QualityOption({
    required this.label,
    required this.quality,
    required this.height,
    required this.width,
    required this.bitrate,
    required this.isDirect,
    required this.isReady,
    this.hlsUrl,
  });

  /// Auto-adaptive quality option (HLS master playlist).
  static const auto = QualityOption(
    label: 'Auto (Adaptive)',
    quality: 'auto',
    height: 0,
    width: 0,
    bitrate: 0,
    isDirect: false,
    isReady: true,
  );

  /// Helper factory for original source direct play.
  factory QualityOption.source({
    required int height,
    required int width,
    int bitrate = 0,
  }) {
    final resolutionStr = height > 0 ? '${height}p' : 'Source';
    return QualityOption(
      label: 'Original ($resolutionStr Direct)',
      quality: 'source',
      height: height,
      width: width,
      bitrate: bitrate,
      isDirect: true,
      isReady: true,
    );
  }

  factory QualityOption.fromJson(Map<String, dynamic> json) {
    return QualityOption(
      label: json['label'] as String? ?? 'Quality',
      quality: json['quality'] as String? ?? '',
      height: (json['height'] as num?)?.toInt() ?? 0,
      width: (json['width'] as num?)?.toInt() ?? 0,
      bitrate: (json['bitrate'] as num?)?.toInt() ?? 0,
      isDirect: json['is_direct'] == true,
      isReady: json['is_ready'] == true,
      hlsUrl: json['hls_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'label': label,
    'quality': quality,
    'height': height,
    'width': width,
    'bitrate': bitrate,
    'is_direct': isDirect,
    'is_ready': isReady,
    'hls_url': hlsUrl,
  };

  /// Short badge label for buttons (e.g. "HD", "SRC", "1080P", "720P").
  String get shortBadge {
    if (quality == 'auto') return 'HD';
    if (isDirect || quality == 'source') return 'SRC';
    return quality.toUpperCase();
  }

  /// Resolution dimensions string e.g. "1920×1080".
  String get dimensionsLabel => width > 0 && height > 0 ? '$width×$height' : '';

  /// Formatted bitrate string e.g. "4.5 Mbps".
  String get formattedBitrate {
    if (bitrate <= 0) return '';
    if (bitrate >= 1000000) {
      final mbps = bitrate / 1000000;
      return '${mbps.toStringAsFixed(mbps >= 10 ? 0 : 1)} Mbps';
    }
    final kbps = bitrate / 1000;
    return '${kbps.round()} kbps';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QualityOption &&
          runtimeType == other.runtimeType &&
          quality == other.quality;

  @override
  int get hashCode => quality.hashCode;

  @override
  String toString() => 'QualityOption($label, quality: $quality, ready: $isReady)';
}
