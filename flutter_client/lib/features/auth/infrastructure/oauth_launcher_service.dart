import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Service coordinating Chrome Custom Tab Google OAuth launch and incoming
/// deep-link session token capture.
class OAuthLauncherService {
  final AppLinks _appLinks;

  OAuthLauncherService({AppLinks? appLinks}) : _appLinks = appLinks ?? AppLinks();

  /// Launches Google OAuth sign-in flow in a Chrome Custom Tab.
  Future<bool> launchGoogleSignIn(String serverBaseUrl) async {
    final cleanBase = serverBaseUrl.endsWith('/')
        ? serverBaseUrl.substring(0, serverBaseUrl.length - 1)
        : serverBaseUrl;

    final targetUrl = '$cleanBase/auth/google?next=/auth/callback/mobile';

    try {
      final uri = Uri.parse(targetUrl);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
      );
      if (!launched) {
        // Fallback to external application
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return true;
    } catch (e) {
      debugPrint('[OAuthLauncherService] Failed to launch Google OAuth: $e');
      return false;
    }
  }

  /// Listens for incoming `ahms://auth/callback?session_token=...` deep links,
  /// across both cold app launches and background/resumed intent deliveries.
  StreamSubscription<Uri> listenForAuthCallbacks(
    void Function(String sessionToken) onTokenReceived,
  ) {
    // 1. Check initial cold-boot link
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) {
        _handleIncomingUri(uri, onTokenReceived);
      }
    }).catchError((e) {
      debugPrint('[OAuthLauncherService] Error checking initial deep link: $e');
    });

    // 2. Listen to subsequent link stream while app is alive
    return _appLinks.uriLinkStream.listen(
      (uri) {
        _handleIncomingUri(uri, onTokenReceived);
      },
      onError: (e) {
        debugPrint('[OAuthLauncherService] Error in deep link stream: $e');
      },
    );
  }

  void _handleIncomingUri(
    Uri uri,
    void Function(String sessionToken) onTokenReceived,
  ) {
    if (uri.scheme == 'ahms' && uri.host == 'auth' && uri.path == '/callback') {
      final token = uri.queryParameters['session_token'];
      if (token != null && token.isNotEmpty) {
        debugPrint('[OAuthLauncherService] Captured session token from deep link!');
        onTokenReceived(token);
      }
    }
  }
}
