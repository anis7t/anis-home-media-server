import 'dart:math';

/// Immutable representation of an active QR pairing session created by a TV or browser.
class QrPairSession {
  final String qrId;
  final String code;
  final String sig;
  final int expiresAt;
  final String qrUrl;
  final String loginUrl;
  final String? secret;

  const QrPairSession({
    required this.qrId,
    required this.code,
    required this.sig,
    required this.expiresAt,
    required this.qrUrl,
    required this.loginUrl,
    this.secret,
  });

  factory QrPairSession.fromJson(Map<String, dynamic> json, {String? secret}) {
    return QrPairSession(
      qrId: json['qr_id'] as String? ?? '',
      code: json['code'] as String? ?? '',
      sig: json['sig'] as String? ?? '',
      expiresAt: (json['expires_at'] as num?)?.toInt() ?? 0,
      qrUrl: json['qr_url'] as String? ?? '',
      loginUrl: json['login_url'] as String? ?? '',
      secret: secret,
    );
  }

  /// Calculates remaining seconds before session expiration based on current epoch time.
  int get remainingSeconds {
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return max(0, expiresAt - nowEpoch);
  }

  /// True if the session has exceeded its expiration timestamp.
  bool get isExpired => remainingSeconds <= 0;

  QrPairSession copyWith({
    String? qrId,
    String? code,
    String? sig,
    int? expiresAt,
    String? qrUrl,
    String? loginUrl,
    String? secret,
  }) {
    return QrPairSession(
      qrId: qrId ?? this.qrId,
      code: code ?? this.code,
      sig: sig ?? this.sig,
      expiresAt: expiresAt ?? this.expiresAt,
      qrUrl: qrUrl ?? this.qrUrl,
      loginUrl: loginUrl ?? this.loginUrl,
      secret: secret ?? this.secret,
    );
  }
}

/// Pairing session lifecycle status reported by `/api/auth/qr/{id}/status`.
enum QrPairStatus {
  pending,
  confirmed,
  expired;

  static QrPairStatus fromString(String? value) {
    switch (value?.toLowerCase()) {
      case 'confirmed':
        return QrPairStatus.confirmed;
      case 'expired':
        return QrPairStatus.expired;
      case 'pending':
      default:
        return QrPairStatus.pending;
    }
  }
}

/// Resolution result for phone manual pairing code lookup (`POST /api/auth/qr/lookup`).
class QrLookupResult {
  final String qrId;
  final String code;

  const QrLookupResult({
    required this.qrId,
    required this.code,
  });

  factory QrLookupResult.fromJson(Map<String, dynamic> json) {
    return QrLookupResult(
      qrId: json['qr_id'] as String? ?? '',
      code: json['code'] as String? ?? '',
    );
  }
}
