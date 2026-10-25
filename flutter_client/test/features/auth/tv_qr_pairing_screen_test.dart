import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/auth/domain/models/qr_pair_session.dart';
import 'package:media_server_client/features/auth/data/auth_secure_storage.dart';
import 'package:media_server_client/features/auth/data/qr_auth_repository.dart';
import 'package:media_server_client/features/auth/presentation/controllers/tv_qr_pair_controller.dart';
import 'package:media_server_client/features/auth/presentation/providers/auth_providers.dart';
import 'package:media_server_client/features/auth/presentation/widgets/tv_qr_pairing_screen.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'auth_secure_storage_test.dart';

class _FakeQrAuthRepository extends Fake implements QrAuthRepository {
  QrPairStatus currentStatus = QrPairStatus.pending;
  bool shouldThrow = false;

  @override
  Future<QrPairSession> createPairSession() async {
    if (shouldThrow) throw Exception('Network offline');
    return QrPairSession(
      qrId: 'qr-tv-test',
      code: 'K9X2P',
      sig: 'sig-test',
      expiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120,
      qrUrl: 'http://test.invalid:8000/remotelogin?qr_id=qr-tv-test&code=K9X2P',
      loginUrl: 'http://test.invalid:8000/remotelogin',
      secret: 'secret-123',
    );
  }

  @override
  Future<QrPairStatus> getPairStatus(String qrId) async {
    return currentStatus;
  }

  @override
  Future<String> finalizePairSession(String qrId, String? secret) async {
    return 'tv-finalized-session-token';
  }
}

class _PreloadedTvQrPairNotifier extends TvQrPairNotifier {
  final TvQrPairState _preloadedState;

  _PreloadedTvQrPairNotifier(this._preloadedState);

  @override
  TvQrPairState build() => _preloadedState;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSecureStorage mockSecureStorage;
  late AuthSecureStorage authSecureStorage;
  late _FakeQrAuthRepository fakeQrRepository;

  setUp(() {
    mockSecureStorage = MockSecureStorage();
    authSecureStorage = AuthSecureStorage(secureStorage: mockSecureStorage);
    fakeQrRepository = _FakeQrAuthRepository();
  });

  Widget buildTestableWidget({TvQrPairState? preloadedState, VoidCallback? onDismiss}) {
    return ProviderScope(
      overrides: [
        authSecureStorageProvider.overrideWithValue(authSecureStorage),
        qrAuthRepositoryProvider.overrideWithValue(fakeQrRepository),
        if (preloadedState != null)
          tvQrPairControllerProvider.overrideWith(
            () => _PreloadedTvQrPairNotifier(preloadedState),
          ),
      ],
      child: MaterialApp(
        home: TvQrPairingScreen(onDismiss: onDismiss),
      ),
    );
  }

  group('TvQrPairingScreen Widget', () {
    testWidgets('renders QR code and 5-character pairing code in waiting state', (tester) async {
      await tester.pumpWidget(buildTestableWidget());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text('K  9  X  2  P'), findsOneWidget);
      expect(find.text('Scan with your phone camera'), findsOneWidget);
      expect(find.text('FAST TV SIGN-IN'), findsOneWidget);
      expect(find.text('Admin PIN Pad'), findsOneWidget);
    });

    testWidgets('toggling Admin PIN Pad switches view to TvAdminPinPad', (tester) async {
      await tester.pumpWidget(buildTestableWidget());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Admin PIN Pad'));
      await tester.pumpAndSettle();

      expect(find.text('Admin PIN Sign-In'), findsOneWidget);
      expect(find.text('Use your remote control to enter the server PIN'), findsOneWidget);
    });

    testWidgets('renders expired state with retry and PIN options', (tester) async {
      await tester.pumpWidget(buildTestableWidget(
        preloadedState: const TvQrPairState.expired(),
      ));
      await tester.pump();

      expect(find.text('Pairing Code Expired'), findsOneWidget);
      expect(find.text('↻ Generate New Code'), findsOneWidget);
      expect(find.text('Enter Admin PIN'), findsOneWidget);
    });

    testWidgets('renders confirmed state with success feedback', (tester) async {
      final session = QrPairSession(
        qrId: 'qr-1',
        code: 'K9X2P',
        sig: 'sig',
        expiresAt: 9999999999,
        qrUrl: 'http://test.invalid:8000',
        loginUrl: 'http://test.invalid:8000',
      );

      await tester.pumpWidget(buildTestableWidget(
        preloadedState: TvQrPairState.confirmed(session),
      ));
      await tester.pump();

      expect(find.text('Device Paired Successfully!'), findsOneWidget);
      expect(find.text('Signing in to your Media Server...'), findsOneWidget);
    });
  });
}
