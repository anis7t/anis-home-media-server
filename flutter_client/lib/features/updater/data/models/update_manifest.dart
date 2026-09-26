import '../../../../core/models/app_channel.dart';

/// Result of validating a downloaded update manifest against the current application state.
class ManifestValidationResult {
  final bool isValid;
  final String? errorMessage;
  final UpdateManifest? manifest;

  const ManifestValidationResult.valid(this.manifest)
      : isValid = true,
        errorMessage = null;

  const ManifestValidationResult.invalid(this.errorMessage)
      : isValid = false,
        manifest = null;

  @override
  String toString() => isValid ? 'Valid manifest: ${manifest?.version}' : 'Invalid manifest: $errorMessage';
}

/// Structured manifest delivered by `/api/app/update?channel=...`.
class UpdateManifest {
  final AppChannel channel;
  final String version;
  final int versionCode;
  final String releaseDate;
  final int minAndroidSdk;
  final int targetAndroidSdk;
  final String packageId;
  final String apkUrl;
  final String sha256;
  final int fileSizeBytes;
  final String releaseNotes;
  final bool mandatory;
  final int minSupportedVersionCode;
  final String? gitCommit;

  const UpdateManifest({
    required this.channel,
    required this.version,
    required this.versionCode,
    required this.releaseDate,
    required this.minAndroidSdk,
    required this.targetAndroidSdk,
    required this.packageId,
    required this.apkUrl,
    required this.sha256,
    required this.fileSizeBytes,
    required this.releaseNotes,
    this.mandatory = false,
    this.minSupportedVersionCode = 1,
    this.gitCommit,
  });

  /// Formatted human-readable file size (e.g. "54.2 MB").
  String get formattedFileSize {
    if (fileSizeBytes < 1024) return '$fileSizeBytes B';
    if (fileSizeBytes < 1024 * 1024) {
      return '${(fileSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Parses JSON and validates against strict fail-closed security invariants.
  static ManifestValidationResult fromJson(
    Map<String, dynamic> json, {
    required AppChannel expectedChannel,
    required int installedVersionCode,
    String expectedPackageId = 'in.anisparvez.media_server_client',
    int currentSdk = 36,
  }) {
    // 1. Channel validation
    final channelStr = json['channel']?.toString().trim();
    if (channelStr == null || channelStr.isEmpty) {
      return const ManifestValidationResult.invalid('Manifest is missing channel');
    }
    final manifestChannel = AppChannel.fromString(channelStr);
    if (manifestChannel != expectedChannel) {
      return ManifestValidationResult.invalid(
        'Channel mismatch: expected ${expectedChannel.id}, got ${manifestChannel.id}',
      );
    }

    // 2. Package ID validation
    final pkgId = json['packageId']?.toString().trim();
    if (pkgId == null || pkgId.isEmpty) {
      return const ManifestValidationResult.invalid('Manifest is missing packageId');
    }
    if (pkgId != expectedPackageId) {
      return ManifestValidationResult.invalid(
        'Package ID mismatch: expected $expectedPackageId, got $pkgId',
      );
    }

    // 3. Version & VersionCode validation
    final versionStr = json['version']?.toString().trim();
    if (versionStr == null || versionStr.isEmpty) {
      return const ManifestValidationResult.invalid('Manifest is missing version string');
    }

    final rawVersionCode = json['versionCode'];
    final vCode = rawVersionCode is int
        ? rawVersionCode
        : int.tryParse(rawVersionCode?.toString() ?? '');
    if (vCode == null || vCode <= 0) {
      return const ManifestValidationResult.invalid('Invalid or missing versionCode');
    }

    // VersionCode must be strictly greater than installed
    if (vCode <= installedVersionCode) {
      return ManifestValidationResult.invalid(
        'Version code $vCode is not newer than installed code $installedVersionCode',
      );
    }

    // 4. Android SDK requirements
    final minSdk = int.tryParse(json['minAndroidSdk']?.toString() ?? '') ?? 26;
    if (currentSdk < minSdk) {
      return ManifestValidationResult.invalid(
        'Device SDK $currentSdk is lower than required minimum SDK $minSdk',
      );
    }
    final targetSdk = int.tryParse(json['targetAndroidSdk']?.toString() ?? '') ?? 36;

    // 5. APK URL validation
    final url = json['apkUrl']?.toString().trim();
    if (url == null || url.isEmpty) {
      return const ManifestValidationResult.invalid('Manifest is missing apkUrl');
    }

    // 6. SHA-256 and Size validation
    final hash = json['sha256']?.toString().trim().toLowerCase();
    if (hash == null || hash.length != 64 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      return const ManifestValidationResult.invalid('Manifest contains invalid SHA-256 hash');
    }

    final rawSize = json['fileSizeBytes'];
    final size = rawSize is int ? rawSize : int.tryParse(rawSize?.toString() ?? '');
    if (size == null || size <= 0) {
      return const ManifestValidationResult.invalid('Manifest specifies invalid file size');
    }

    final notes = json['releaseNotes']?.toString() ?? '';
    final isMandatory = json['mandatory'] == true;
    final minSupp = int.tryParse(json['minSupportedVersionCode']?.toString() ?? '') ?? 1;
    final gitCommit = json['gitCommit']?.toString();
    final releaseDate = json['releaseDate']?.toString() ?? DateTime.now().toUtc().toIso8601String();

    final manifest = UpdateManifest(
      channel: manifestChannel,
      version: versionStr,
      versionCode: vCode,
      releaseDate: releaseDate,
      minAndroidSdk: minSdk,
      targetAndroidSdk: targetSdk,
      packageId: pkgId,
      apkUrl: url,
      sha256: hash,
      fileSizeBytes: size,
      releaseNotes: notes,
      mandatory: isMandatory,
      minSupportedVersionCode: minSupp,
      gitCommit: gitCommit,
    );

    return ManifestValidationResult.valid(manifest);
  }

  Map<String, dynamic> toJson() => {
        'channel': channel.id,
        'version': version,
        'versionCode': versionCode,
        'releaseDate': releaseDate,
        'minAndroidSdk': minAndroidSdk,
        'targetAndroidSdk': targetAndroidSdk,
        'packageId': packageId,
        'apkUrl': apkUrl,
        'sha256': sha256,
        'fileSizeBytes': fileSizeBytes,
        'releaseNotes': releaseNotes,
        'mandatory': mandatory,
        'minSupportedVersionCode': minSupportedVersionCode,
        if (gitCommit != null) 'gitCommit': gitCommit,
      };
}
