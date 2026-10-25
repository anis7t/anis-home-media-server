import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/qr_pair_session.dart';
import '../../data/qr_auth_repository.dart';
import '../providers/auth_providers.dart';
import 'auth_notifier.dart';

/// State of an active Android TV QR pairing workflow.
enum TvQrStateStatus {
  loading,
  waiting,
  confirmed,
  expired,
  error,
}

class TvQrPairState {
  final TvQrStateStatus status;
  final QrPairSession? session;
  final int remainingSeconds;
  final String? errorMessage;

  const TvQrPairState({
    required this.status,
    this.session,
    this.remainingSeconds = 0,
    this.errorMessage,
  });

  const TvQrPairState.loading()
      : status = TvQrStateStatus.loading,
        session = null,
        remainingSeconds = 0,
        errorMessage = null;

  const TvQrPairState.waiting({
    required this.session,
    required this.remainingSeconds,
  })  : status = TvQrStateStatus.waiting,
        errorMessage = null;

  const TvQrPairState.confirmed(this.session)
      : status = TvQrStateStatus.confirmed,
        remainingSeconds = 0,
        errorMessage = null;

  const TvQrPairState.expired({this.session})
      : status = TvQrStateStatus.expired,
        remainingSeconds = 0,
        errorMessage = null;

  const TvQrPairState.error(String message, {this.session})
      : status = TvQrStateStatus.error,
        remainingSeconds = 0,
        errorMessage = message;
}

/// Riverpod controller managing the lifecycle, countdown timer, and polling of TV QR pairing.
class TvQrPairNotifier extends Notifier<TvQrPairState> {
  final QrAuthRepository? _injectedRepository;
  final AuthNotifier? _injectedAuthNotifier;

  Timer? _countdownTimer;
  Timer? _pollingTimer;
  int _consecutivePollErrors = 0;

  TvQrPairNotifier({
    QrAuthRepository? repository,
    AuthNotifier? authNotifier,
  })  : _injectedRepository = repository,
        _injectedAuthNotifier = authNotifier;

  QrAuthRepository get repository =>
      _injectedRepository ?? ref.read(qrAuthRepositoryProvider);
  AuthNotifier get authNotifier =>
      _injectedAuthNotifier ?? ref.read(authNotifierProvider.notifier);

  @override
  TvQrPairState build() {
    ref.onDispose(() {
      _cancelTimers();
    });

    // Automatically initialize pairing session on first read
    Future.microtask(() => startSession());
    return const TvQrPairState.loading();
  }

  void _cancelTimers() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  /// Generates a fresh QR pair session and starts timers.
  Future<void> startSession() async {
    _cancelTimers();
    _consecutivePollErrors = 0;
    state = const TvQrPairState.loading();

    try {
      final session = await repository.createPairSession();
      final remaining = session.remainingSeconds;

      if (remaining <= 0) {
        state = TvQrPairState.expired(session: session);
        return;
      }

      state = TvQrPairState.waiting(
        session: session,
        remainingSeconds: remaining,
      );

      _startCountdown(session);
      _startPolling(session);
    } catch (e) {
      state = TvQrPairState.error(
        'Failed to generate QR pairing session: $e',
      );
    }
  }

  void _startCountdown(QrPairSession session) {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remaining = session.remainingSeconds;
      if (remaining <= 0) {
        _cancelTimers();
        state = TvQrPairState.expired(session: session);
      } else {
        if (state.status == TvQrStateStatus.waiting) {
          state = TvQrPairState.waiting(
            session: session,
            remainingSeconds: remaining,
          );
        }
      }
    });
  }

  void _startPolling(QrPairSession session) {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 2500), (timer) async {
      if (state.status != TvQrStateStatus.waiting) return;

      try {
        final pairStatus = await repository.getPairStatus(session.qrId);
        _consecutivePollErrors = 0;

        switch (pairStatus) {
          case QrPairStatus.confirmed:
            _cancelTimers();
            state = TvQrPairState.confirmed(session);
            await _finalizeSession(session);
            break;
          case QrPairStatus.expired:
            _cancelTimers();
            state = TvQrPairState.expired(session: session);
            break;
          case QrPairStatus.pending:
            break;
        }
      } catch (e) {
        _consecutivePollErrors++;
        if (_consecutivePollErrors >= 4) {
          _cancelTimers();
          state = TvQrPairState.error(
            'Connection lost while waiting for device pairing.',
            session: session,
          );
        }
      }
    });
  }

  Future<void> _finalizeSession(QrPairSession session) async {
    try {
      final sessionToken = await repository.finalizePairSession(
        session.qrId,
        session.secret,
      );
      await authNotifier.setSessionToken(sessionToken);
    } catch (e) {
      state = TvQrPairState.error(
        'Failed to finalize signed-in session: $e',
        session: session,
      );
    }
  }
}
