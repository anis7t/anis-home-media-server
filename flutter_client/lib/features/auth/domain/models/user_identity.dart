import 'package:flutter/foundation.dart';

/// User identity details returned by `/api/auth/me` or `/api/auth/login-pin`.
@immutable
class UserIdentity {
  final int? id;
  final String? email;
  final String? name;
  final String? pictureUrl;
  final String role; // 'admin' | 'viewer' | 'guest'
  final bool isAdmin;
  final bool oauthConfigured;

  const UserIdentity({
    this.id,
    this.email,
    this.name,
    this.pictureUrl,
    required this.role,
    required this.isAdmin,
    this.oauthConfigured = false,
  });

  /// Guest identity when unauthenticated.
  static const UserIdentity guest = UserIdentity(
    role: 'guest',
    isAdmin: false,
    oauthConfigured: false,
  );

  /// Deserializes JSON payload from `GET /api/auth/me`.
  factory UserIdentity.fromAccountJson(Map<String, dynamic> json) {
    final isAdmin = json['is_admin'] == true || json['role'] == 'admin';
    final role = (json['role'] as String?)?.toLowerCase() ??
        (isAdmin ? 'admin' : (json['authenticated'] == true ? 'viewer' : 'guest'));

    return UserIdentity(
      id: json['id'] is num ? (json['id'] as num).toInt() : null,
      email: json['email'] as String?,
      name: json['name'] as String?,
      pictureUrl: json['picture'] as String? ?? json['picture_url'] as String?,
      role: role,
      isAdmin: isAdmin,
      oauthConfigured: json['oauth_configured'] == true,
    );
  }

  /// Deserializes user object from `POST /api/auth/login-pin`.
  factory UserIdentity.fromLoginPinJson(Map<String, dynamic> json) {
    final user = json['user'] is Map<String, dynamic>
        ? json['user'] as Map<String, dynamic>
        : json;

    return UserIdentity(
      id: user['id'] is num ? (user['id'] as num).toInt() : null,
      email: user['email'] as String?,
      name: user['name'] as String?,
      pictureUrl: user['picture_url'] as String?,
      role: (user['role'] as String?)?.toLowerCase() ?? 'admin',
      isAdmin: user['is_admin'] == true || user['role'] == 'admin',
      oauthConfigured: true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      if (email != null) 'email': email,
      if (name != null) 'name': name,
      if (pictureUrl != null) 'picture_url': pictureUrl,
      'role': role,
      'is_admin': isAdmin,
      'oauth_configured': oauthConfigured,
    };
  }

  UserIdentity copyWith({
    int? id,
    String? email,
    String? name,
    String? pictureUrl,
    String? role,
    bool? isAdmin,
    bool? oauthConfigured,
  }) {
    return UserIdentity(
      id: id ?? this.id,
      email: email ?? this.email,
      name: name ?? this.name,
      pictureUrl: pictureUrl ?? this.pictureUrl,
      role: role ?? this.role,
      isAdmin: isAdmin ?? this.isAdmin,
      oauthConfigured: oauthConfigured ?? this.oauthConfigured,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserIdentity &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          email == other.email &&
          name == other.name &&
          pictureUrl == other.pictureUrl &&
          role == other.role &&
          isAdmin == other.isAdmin &&
          oauthConfigured == other.oauthConfigured;

  @override
  int get hashCode => Object.hash(
        id,
        email,
        name,
        pictureUrl,
        role,
        isAdmin,
        oauthConfigured,
      );

  @override
  String toString() {
    return 'UserIdentity(email: $email, role: $role, isAdmin: $isAdmin)';
  }
}
