import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/api/api_client.dart';
import '../../domain/models/auth_state.dart';
import '../../domain/models/user_identity.dart';
import '../../infrastructure/auth_repository.dart';
import '../../infrastructure/auth_secure_storage.dart';
import '../../infrastructure/oauth_launcher_service.dart';
import '../../infrastructure/qr_auth_repository.dart';
import '../controllers/auth_notifier.dart';
import '../controllers/tv_qr_pair_controller.dart';

/// Provider for hardware-backed secure storage.
final authSecureStorageProvider = Provider<AuthSecureStorage>((ref) {
  return AuthSecureStorage();
});

/// Provider for Google OAuth launcher and deep-link listener service.
final oauthLauncherServiceProvider = Provider<OAuthLauncherService>((ref) {
  return OAuthLauncherService();
});

/// Provider for remote authentication repository.
final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final storage = ref.watch(authSecureStorageProvider);
  return AuthRepository(
    apiClient: apiClient,
    secureStorage: storage,
  );
});

/// Central Riverpod NotifierProvider for authentication state.
final authNotifierProvider = NotifierProvider<AuthNotifier, AuthState>(() {
  return AuthNotifier();
});

/// Convenience provider returning whether the user is authenticated.
final isAuthenticatedProvider = Provider<bool>((ref) {
  final authState = ref.watch(authNotifierProvider);
  return authState.isAuthenticated;
});

/// Convenience provider returning whether the current user or session possesses Admin privileges.
final isAdminProvider = Provider<bool>((ref) {
  final authState = ref.watch(authNotifierProvider);
  return authState.isAdmin;
});

/// Convenience provider returning the active [UserIdentity] or [UserIdentity.guest].
final currentUserProvider = Provider<UserIdentity>((ref) {
  final authState = ref.watch(authNotifierProvider);
  return authState.identity ?? UserIdentity.guest;
});

/// Provider for remote QR authentication repository.
final qrAuthRepositoryProvider = Provider<QrAuthRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final storage = ref.watch(authSecureStorageProvider);
  return QrAuthRepository(
    apiClient: apiClient,
    secureStorage: storage,
  );
});

/// NotifierProvider for Android TV QR pairing workflow.
final tvQrPairControllerProvider =
    NotifierProvider<TvQrPairNotifier, TvQrPairState>(() {
  return TvQrPairNotifier();
});
