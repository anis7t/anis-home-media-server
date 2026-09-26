import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import '../../../../core/api/api_endpoints.dart';
import '../../../../core/models/app_channel.dart';
import '../models/update_manifest.dart';

class UpdateRepository {
  final Dio _dio;

  UpdateRepository(this._dio);

  /// Queries the server update manifest for the specified channel and validates against strict invariants.
  Future<ManifestValidationResult> fetchAndValidateManifest({
    required AppChannel channel,
    required int installedVersionCode,
    String expectedPackageId = 'in.anisparvez.media_server_client',
    int currentSdk = 36,
  }) async {
    try {
      final response = await _dio.get(
        ApiEndpoints.appUpdate,
        queryParameters: {'channel': channel.id},
        options: Options(
          sendTimeout: const Duration(seconds: 6),
          receiveTimeout: const Duration(seconds: 6),
          headers: {'Cache-Control': 'no-cache'},
        ),
      );

      if (response.statusCode == 200 && response.data is Map) {
        final data = Map<String, dynamic>.from(response.data as Map);
        return UpdateManifest.fromJson(
          data,
          expectedChannel: channel,
          installedVersionCode: installedVersionCode,
          expectedPackageId: expectedPackageId,
          currentSdk: currentSdk,
        );
      } else if (response.statusCode == 404) {
        return const ManifestValidationResult.invalid('No update manifest found on server for this channel');
      } else {
        return ManifestValidationResult.invalid('Server returned HTTP ${response.statusCode}');
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return const ManifestValidationResult.invalid('No update available for this channel');
      }
      return ManifestValidationResult.invalid(e.message ?? 'Network connection failed during update check');
    } catch (e) {
      return ManifestValidationResult.invalid('Unexpected update check error: $e');
    }
  }

  /// Downloads the release APK with continuous progress reporting into destinationPath.
  Future<bool> downloadApk({
    required String downloadUrl,
    required String destinationPath,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final destFile = File(destinationPath);
    final tempFile = File('$destinationPath.tmp');

    try {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      if (await destFile.exists()) {
        await destFile.delete();
      }
      await tempFile.parent.create(recursive: true);

      // Handle relative vs absolute URLs
      final fullUrl = downloadUrl.startsWith('http')
          ? downloadUrl
          : '${_dio.options.baseUrl}$downloadUrl';

      final response = await _dio.download(
        fullUrl,
        tempFile.path,
        onReceiveProgress: onProgress,
        cancelToken: cancelToken,
        options: Options(
          receiveTimeout: const Duration(minutes: 10),
          sendTimeout: const Duration(seconds: 15),
        ),
      );

      if (response.statusCode == 200 || response.statusCode == 206) {
        if (await tempFile.exists() && await tempFile.length() > 0) {
          await tempFile.rename(destinationPath);
          return true;
        }
      }
      await cleanupFile(tempFile.path);
      return false;
    } catch (e) {
      await cleanupFile(tempFile.path);
      rethrow;
    }
  }

  /// Cryptographically verifies the SHA-256 digest of the downloaded APK file.
  Future<bool> verifyChecksum(String filePath, String expectedSha256) async {
    final file = File(filePath);
    if (!await file.exists() || await file.length() <= 0) {
      return false;
    }

    try {
      final digest = await sha256.bind(file.openRead()).first;
      final calculatedHash = digest.toString().toLowerCase();
      final targetHash = expectedSha256.trim().toLowerCase();
      return calculatedHash == targetHash;
    } catch (_) {
      return false;
    }
  }

  /// Safely deletes temporary or corrupt files.
  Future<void> cleanupFile(String filePath) async {
    try {
      final f = File(filePath);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }
}
