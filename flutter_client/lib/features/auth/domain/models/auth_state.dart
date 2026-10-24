import 'package:flutter/foundation.dart';
import 'user_identity.dart';

/// Authentication state lifecycle statuses.
enum AuthStatus {
  /// Startup phase prior to local storage inspection or `/api/auth/me` probe.
  initial,

  /// Active sign-in or session verification in flight.
  authenticating,

  /// Successfully signed in with an active, valid session.
  authenticated,

  /// Operating as a guest / unauthenticated.
  unauthenticated,

  /// Terminal or transient authentication error.
  error,
}

/// Immutable state container for client-wide authentication.
@immutable
class AuthState {
  final AuthStatus status;
  final UserIdentity? identity;
  final String? sessionToken;
  final String? activeAdminPin;
  final String? errorMessage;

  const AuthState({
    required this.status,
    this.identity,
    this.sessionToken,
    this.activeAdminPin,
    this.errorMessage,
  });

  /// Initial state at boot.
  static const AuthState initial = AuthState(
    status: AuthStatus.initial,
    identity: null,
    sessionToken: null,
    activeAdminPin: null,
    errorMessage: null,
  );

  /// Guest state (unauthenticated).
  static const AuthState unauthenticated = AuthState(
    status: AuthStatus.unauthenticated,
    identity: UserIdentity.guest,
    sessionToken: null,
    activeAdminPin: null,
    errorMessage: null,
  );

  /// Whether the user has an active, authenticated identity on the server.
  bool get isAuthenticated =>
      status == AuthStatus.authenticated && identity != null && identity!.role != 'guest';

  /// Whether the current session possesses Administrator privileges (either via Admin identity
  /// or active verified Admin PIN).
  bool get isAdmin =>
      (identity?.isAdmin == true) ||
      (activeAdminPin != null && activeAdminPin!.isNotEmpty);

  /// Whether the app is currently running in guest mode.
  bool get isGuest => !isAuthenticated;

  /// Whether an authentication or verification action is in flight.
  bool get isLoading => status == AuthStatus.authenticating || status == AuthStatus.initial;

  AuthState copyWith({
    AuthStatus? status,
    UserIdentity? identity,
    String? sessionToken,
    String? activeAdminPin,
    String? errorMessage,
    bool clearPin = false,
    bool clearToken = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      identity: identity ?? this.identity,
      sessionToken: clearToken ? null : (sessionToken ?? this.sessionToken),
      activeAdminPin: clearPin ? null : (activeAdminPin ?? this.activeAdminPin),
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuthState &&
          runtimeType == other.runtimeType &&
          status == other.status &&
          identity == other.identity &&
          sessionToken == other.sessionToken &&
          activeAdminPin == other.activeAdminPin &&
          errorMessage == other.errorMessage;

  @override
  int get hashCode => Object.hash(
        status,
        identity,
        sessionToken,
        activeAdminPin,
        errorMessage,
      );

  @override
  String toString() {
    return 'AuthState(status: $status, email: ${identity?.email}, isAdmin: $isAdmin)';
  }
}
