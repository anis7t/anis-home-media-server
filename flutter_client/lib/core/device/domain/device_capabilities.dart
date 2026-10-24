/// Immutable capability profile describing the runtime hardware and input characteristics.
class DeviceCapabilities {
  final bool isTv;
  final bool isAmazonFireTv;
  final bool hasTouchscreen;
  final bool hasLeanbackFeature;
  final String model;
  final String manufacturer;

  const DeviceCapabilities({
    required this.isTv,
    this.isAmazonFireTv = false,
    this.hasTouchscreen = true,
    this.hasLeanbackFeature = false,
    this.model = '',
    this.manufacturer = '',
  });

  /// Factory constructor parsing map received from native Android channel.
  factory DeviceCapabilities.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) {
      return mobileDefault;
    }
    return DeviceCapabilities(
      isTv: map['isTv'] == true,
      isAmazonFireTv: map['isFireTv'] == true,
      hasTouchscreen: map['hasTouchscreen'] != false,
      hasLeanbackFeature: map['hasLeanback'] == true,
      model: map['model']?.toString() ?? '',
      manufacturer: map['manufacturer']?.toString() ?? '',
    );
  }

  /// Default standard mobile profile.
  static const DeviceCapabilities mobileDefault = DeviceCapabilities(
    isTv: false,
    hasTouchscreen: true,
  );

  /// Default TV profile (e.g. for TV emulator or debug override).
  static const DeviceCapabilities tvDefault = DeviceCapabilities(
    isTv: true,
    isAmazonFireTv: false,
    hasTouchscreen: false,
    hasLeanbackFeature: true,
  );

  /// Returns a copy of this capability profile with the given fields replaced.
  DeviceCapabilities copyWith({
    bool? isTv,
    bool? isAmazonFireTv,
    bool? hasTouchscreen,
    bool? hasLeanbackFeature,
    String? model,
    String? manufacturer,
  }) {
    return DeviceCapabilities(
      isTv: isTv ?? this.isTv,
      isAmazonFireTv: isAmazonFireTv ?? this.isAmazonFireTv,
      hasTouchscreen: hasTouchscreen ?? this.hasTouchscreen,
      hasLeanbackFeature: hasLeanbackFeature ?? this.hasLeanbackFeature,
      model: model ?? this.model,
      manufacturer: manufacturer ?? this.manufacturer,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceCapabilities &&
          runtimeType == other.runtimeType &&
          isTv == other.isTv &&
          isAmazonFireTv == other.isAmazonFireTv &&
          hasTouchscreen == other.hasTouchscreen &&
          hasLeanbackFeature == other.hasLeanbackFeature &&
          model == other.model &&
          manufacturer == other.manufacturer;

  @override
  int get hashCode =>
      isTv.hashCode ^
      isAmazonFireTv.hashCode ^
      hasTouchscreen.hashCode ^
      hasLeanbackFeature.hashCode ^
      model.hashCode ^
      manufacturer.hashCode;

  @override
  String toString() =>
      'DeviceCapabilities(isTv: $isTv, isAmazonFireTv: $isAmazonFireTv, '
      'hasTouchscreen: $hasTouchscreen, hasLeanback: $hasLeanbackFeature, '
      'model: $model, manufacturer: $manufacturer)';
}
