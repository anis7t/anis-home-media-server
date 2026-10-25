import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/auth_state.dart';
import '../../data/auth_repository.dart';
import '../../data/auth_secure_storage.dart';

import '../providers/auth_providers.dart';

/// App-wide authentication controller managing session lifecycle, hydration,
/// PIN authentication, and role authorization.
class AuthNotifier extends Notifier<AuthState> {
  final AuthRepository? _injectedRepository;
  final AuthSecureStorage? _injectedStorage;

  AuthNotifier({
    AuthRepository? repository,
    AuthSecureStorage? storage,
  })  : _injectedRepository = repository,
        _injectedStorage = storage;

  AuthRepository get _repository =>
      _injectedRepository ?? ref.read(authRepositoryProvider);
  AuthSecureStorage get _storage =>
      _injectedStorage ?? ref.read(authSecureStorageProvider);

  @override
  AuthState build() {
    return AuthState.initial;
  }

  /// Hydrates the authentication state from local hardware secure storage
  /// and confirms validity against the remote `/api/auth/me` endpoint.
  Future<void> hydrate() async {
    state = state.copyWith(status: AuthStatus.authenticating, errorMessage: null);

    try {
      final token = await _storage.getSessionToken();
      final savedPin = await _storage.getAdminPin();

      if (token == null || token.isEmpty) {
        state = AuthState.unauthenticated.copyWith(
          activeAdminPin: savedPin,
        );
        return;
      }

      final identity = await _repository.getMe();
      if (identity.role != 'guest' && (identity.email != null || identity.isAdmin)) {
        state = AuthState(
          status: AuthStatus.authenticated,
          identity: identity,
          sessionToken: token,
          activeAdminPin: savedPin,
        );
      } else {
        // Token was rejected or is invalid on the server
        await _storage.clearSessionToken();
        state = AuthState.unauthenticated.copyWith(
          activeAdminPin: savedPin,
        );
      }
    } catch (e) {
      debugPrint('[AuthNotifier] Hydration failed: $e');
      state = state.copyWith(
        status: AuthStatus.unauthenticated,
        errorMessage: e.toString(),
      );
    }
  }

  /// Signs in using the server's Admin PIN.
  Future<bool> loginWithPin(String pin) async {
    state = state.copyWith(status: AuthStatus.authenticating, errorMessage: null);

    try {
      final result = await _repository.loginWithPin(pin);
      state = AuthState(
        status: AuthStatus.authenticated,
        identity: result.identity,
        sessionToken: result.sessionToken,
        activeAdminPin: pin,
      );
      return true;
    } catch (e) {
      debugPrint('[AuthNotifier] PIN login failed: $e');
      state = state.copyWith(
        status: AuthStatus.unauthenticated,
        errorMessage: e.toString(),
      );
      return false;
    }
  }

  /// Sets an externally minted session token (e.g. from Google OAuth deep link
  /// or Android TV QR code confirmation) and hydrates user profile.
  Future<bool> setSessionToken(String token) async {
    if (state.sessionToken == token && state.isAuthenticated) {
      return true;
    }

    state = state.copyWith(status: AuthStatus.authenticating, errorMessage: null);

    try {
      await _storage.saveSessionToken(token);
      final identity = await _repository.getMe();

      state = AuthState(
        status: AuthStatus.authenticated,
        identity: identity,
        sessionToken: token,
        activeAdminPin: state.activeAdminPin,
      );
      return true;
    } catch (e) {
      debugPrint('[AuthNotifier] setSessionToken failed: $e');
      await _storage.clearSessionToken();
      state = state.copyWith(
        status: AuthStatus.unauthenticated,
        errorMessage: e.toString(),
      );
      return false;
    }
  }

  /// Verifies an Admin PIN to unlock admin privileges for the current session.
  Future<bool> verifyAndUnlockAdminPin(String pin, {bool remember = false}) async {
    try {
      final isValid = await _repository.verifyAdminPin(pin);
      if (isValid) {
        if (remember) {
          await _storage.saveAdminPin(pin);
        }
        state = state.copyWith(activeAdminPin: pin);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[AuthNotifier] verifyAndUnlockAdminPin error: $e');
      return false;
    }
  }

  /// Clears transient or remembered Admin PIN.
  Future<void> clearAdminPin() async {
    await _storage.clearAdminPin();
    state = state.copyWith(clearPin: true);
  }

  /// Clears remote session and local secure credentials, resetting to guest state.
  Future<void> logout() async {
    state = state.copyWith(status: AuthStatus.authenticating);
    try {
      await _repository.logout();
    } finally {
      state = AuthState.unauthenticated;
    }
  }

  /// Invoked when an API request receives a 401 Unauthorized from the server.
  void handleUnauthorized() {
    if (state.isAuthenticated) {
      debugPrint('[AuthNotifier] Remote session invalidated (401 received). Resetting to guest.');
      _storage.clearSessionToken();
      state = AuthState.unauthenticated;
    }
  }
}
