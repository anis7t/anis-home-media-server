import 'package:dio/dio.dart';

import '../domain/playback_mode.dart';
import '../domain/player_controller_interface.dart';

/// Helper service responsible for resolving media URLs, API server origins,
/// seek-preview metadata, sidecar subtitles, and movie info.
class PlayerMediaResolver {
  /// Extracts the filename from explicit parameter or the mediaUrl path segments.
  static String? resolveFilename(String mediaUrl, String? explicitFilename) {
    if (explicitFilename != null && explicitFilename.isNotEmpty) {
      return explicitFilename;
    }
    final uri = Uri.tryParse(mediaUrl);
    if (uri == null) return null;

    final path = uri.path;
    if (path.startsWith('/media/')) {
      return Uri.decodeComponent(path.substring('/media/'.length));
    } else if (path.startsWith('/hls/')) {
      const prefix = '/hls/';
      var rest = path.substring(prefix.length);
      if (rest.endsWith('/playlist.m3u8')) {
        rest = rest.substring(0, rest.length - '/playlist.m3u8'.length);
      } else if (rest.endsWith('/master.m3u8')) {
        rest = rest.substring(0, rest.length - '/master.m3u8'.length);
      }
      return Uri.decodeComponent(rest);
    }

    if (uri.pathSegments.isNotEmpty) {
      final last = uri.pathSegments.last;
      if (last.isNotEmpty && last.contains('.')) {
        return Uri.decodeComponent(last);
      }
    }
    return null;
  }

  /// Resolves the actual streaming media URL, mapping localhost URLs to active LAN or WAN endpoints.
  static String resolveEffectiveMediaUrl({
    required String rawMediaUrl,
    required bool hasCustomController,
    String? activeConnectionServerUrl,
    String? savedSettingsServerUrl,
  }) {
    if (hasCustomController) {
      return rawMediaUrl;
    }
    final parsed = Uri.tryParse(rawMediaUrl);
    final isLocalhost = parsed == null ||
        !parsed.hasScheme ||
        parsed.host == '127.0.0.1' ||
        parsed.host == 'localhost';

    if (isLocalhost) {
      if (activeConnectionServerUrl != null &&
          activeConnectionServerUrl.isNotEmpty &&
          !activeConnectionServerUrl.contains('127.0.0.1') &&
          !activeConnectionServerUrl.contains('localhost')) {
        final server = activeConnectionServerUrl.endsWith('/')
            ? activeConnectionServerUrl.substring(0, activeConnectionServerUrl.length - 1)
            : activeConnectionServerUrl;
        final path = (parsed != null && parsed.hasScheme)
            ? (parsed.hasQuery ? '${parsed.path}?${parsed.query}' : parsed.path)
            : (rawMediaUrl.startsWith('/') ? rawMediaUrl : '/$rawMediaUrl');
        return '$server$path';
      }

      if (savedSettingsServerUrl != null &&
          savedSettingsServerUrl.isNotEmpty &&
          !savedSettingsServerUrl.contains('127.0.0.1') &&
          !savedSettingsServerUrl.contains('localhost')) {
        final server = savedSettingsServerUrl.endsWith('/')
            ? savedSettingsServerUrl.substring(0, savedSettingsServerUrl.length - 1)
            : savedSettingsServerUrl;
        final path = (parsed != null && parsed.hasScheme)
            ? (parsed.hasQuery ? '${parsed.path}?${parsed.query}' : parsed.path)
            : (rawMediaUrl.startsWith('/') ? rawMediaUrl : '/$rawMediaUrl');
        return '$server$path';
      }
    }
    return rawMediaUrl;
  }

  /// Resolves the base origin (`scheme://host:port`) for API calls.
  static String? resolveServerOrigin({
    String? effectiveServerOrigin,
    String? effectiveMediaUrl,
    required String rawMediaUrl,
    String? activeConnectionServerUrl,
  }) {
    if (effectiveServerOrigin != null && effectiveServerOrigin.isNotEmpty) {
      return effectiveServerOrigin;
    }
    final uri = Uri.tryParse(effectiveMediaUrl ?? rawMediaUrl);
    if (uri != null &&
        uri.hasScheme &&
        uri.hasAuthority &&
        uri.host != '127.0.0.1' &&
        uri.host != 'localhost') {
      return uri.origin;
    }
    if (activeConnectionServerUrl != null &&
        activeConnectionServerUrl.isNotEmpty &&
        !activeConnectionServerUrl.contains('127.0.0.1') &&
        !activeConnectionServerUrl.contains('localhost')) {
      final activeUri = Uri.tryParse(activeConnectionServerUrl);
      if (activeUri != null && activeUri.hasScheme && activeUri.hasAuthority) {
        return activeUri.origin;
      }
    }
    if (uri != null && uri.hasScheme && uri.hasAuthority) {
      return uri.origin;
    }
    return null;
  }

  /// Rewrites the media URL to HLS master playlist if authoritative mode is HLS.
  static String applyAuthoritativeMode(String url, PlaybackMode mode) {
    if (mode == PlaybackMode.directPlay) return url;
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final path = uri.path;
    if (path.startsWith('/hls/')) return url;
    final sub = path.startsWith('/media/') ? path.substring('/media/'.length) : path;
    final clean = sub.startsWith('/') ? sub.substring(1) : sub;
    final hlsPath = '/hls/$clean/master.m3u8';
    return uri
        .replace(
          path: hlsPath,
          queryParameters: uri.queryParameters.isEmpty ? null : uri.queryParameters,
        )
        .toString();
  }

  /// Fetches seek preview frames metadata (`/api/seek-preview-meta/<filename>`).
  static Future<Map<String, dynamic>?> loadPreviewMeta({
    required Dio dio,
    required String serverOrigin,
    required String filename,
    CancelToken? cancelToken,
  }) async {
    final encoded = Uri.encodeComponent(filename);
    final url = '$serverOrigin/api/seek-preview-meta/$encoded';
    final res = await dio.get(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.json,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    if (res.statusCode == 200 && res.data != null) {
      return res.data is Map<String, dynamic>
          ? res.data as Map<String, dynamic>
          : (res.data as Map).cast<String, dynamic>();
    }
    return null;
  }

  /// Discovers server-side WebVTT and sidecar subtitles (`/api/subtitles/<filename>`).
  static Future<List<PlayerSubtitleTrack>> fetchSidecarSubtitles({
    required Dio dio,
    required String serverOrigin,
    required String filename,
    CancelToken? cancelToken,
  }) async {
    final encoded = Uri.encodeComponent(filename);
    final url = '$serverOrigin/api/subtitles/$encoded';
    final res = await dio.get(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.json,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    if (res.statusCode == 200 && res.data != null && res.data['tracks'] is List) {
      final rawTracks = res.data['tracks'] as List;
      final sidecars = <PlayerSubtitleTrack>[];
      for (final item in rawTracks) {
        if (item is Map) {
          final src = item['src'] as String? ?? '';
          final label = item['label'] as String? ?? item['name'] as String? ?? 'Subtitle';
          final lang = item['lang'] as String?;
          final isDefault = item['default'] == true;
          final fullUrl = src.startsWith('http') ? src : '$serverOrigin$src';
          sidecars.add(PlayerSubtitleTrack(
            id: fullUrl,
            title: label,
            language: lang,
            isExternal: true,
            isDefault: isDefault,
          ));
        }
      }
      return sidecars;
    }
    return [];
  }

  /// Probes `/api/media-info/<filename>` for direct_play capability and metadata.
  static Future<Map<String, dynamic>> loadMovieMeta({
    required Dio dio,
    required String serverOrigin,
    required String filename,
    CancelToken? cancelToken,
    void Function(PlaybackMode mode)? onModeResolved,
    void Function(Map<String, dynamic> updatedMeta)? onOverviewResolved,
  }) async {
    final encoded = Uri.encodeComponent(filename);
    final url = '$serverOrigin/api/media-info/$encoded';
    final res = await dio.get(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.json,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    Map<String, dynamic> meta = {};
    if (res.statusCode == 200 && res.data != null && res.data is Map) {
      meta = (res.data as Map).cast<String, dynamic>();
    }

    if (onModeResolved != null) {
      onModeResolved(PlaybackMode.fromDirectPlay(meta['direct_play']));
    }

    // Fallback: If overview is missing or empty, fetch from the /movie/$encoded HTML page in background
    if (meta['overview'] == null || meta['overview'].toString().trim().isEmpty) {
      final pageUrl = '$serverOrigin/movie/$encoded';
      dio.get(
        pageUrl,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
        ),
      ).then((pageRes) {
        if (pageRes.statusCode == 200 && pageRes.data != null) {
          final html = pageRes.data.toString();
          final synMatch = RegExp(r'class="synopsis-text">\s*(.*?)\s*</p>', dotAll: true).firstMatch(html);
          if (synMatch != null && synMatch.group(1) != null) {
            var syn = synMatch.group(1)!.trim();
            syn = syn
                .replaceAll('&amp;', '&')
                .replaceAll('&quot;', '"')
                .replaceAll('&#39;', "'")
                .replaceAll('&lt;', '<')
                .replaceAll('&gt;', '>');
            if (syn.isNotEmpty && !syn.toLowerCase().contains('no synopsis')) {
              meta['overview'] = syn;
            }
          }
          final titleMatch = RegExp(r'<h1 class="movie-title">\s*(.*?)\s*</h1>').firstMatch(html);
          if (titleMatch != null && titleMatch.group(1) != null && meta['title'] == null) {
            meta['title'] = titleMatch.group(1)!.trim();
          }
          final yearMatch = RegExp(r'<span class="meta-pill">(\d{4})</span>').firstMatch(html);
          if (yearMatch != null && yearMatch.group(1) != null && meta['year'] == null) {
            meta['year'] = yearMatch.group(1)!.trim();
          }
          final ratingMatch = RegExp(r'<span class="badge-score">★\s*([\d\.]+)').firstMatch(html);
          if (ratingMatch != null && ratingMatch.group(1) != null && meta['rating'] == null) {
            meta['rating'] = double.tryParse(ratingMatch.group(1)!.trim());
          }
          final genreBlock = RegExp(r'<div class="genre-chips">(.*?)</div>', dotAll: true).firstMatch(html)?.group(1);
          if (genreBlock != null && meta['genres'] == null) {
            final genres = RegExp(r'<span>([^<]+)</span>').allMatches(genreBlock).map((m) => m.group(1)!.trim()).toList();
            if (genres.isNotEmpty) {
              meta['genres'] = genres.join(', ');
            }
          }
          if (onOverviewResolved != null) {
            onOverviewResolved(meta);
          }
        }
      }).catchError((_) {});
    }
    return meta;
  }
}
