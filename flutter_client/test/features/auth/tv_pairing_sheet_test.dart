import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/errors/app_exception.dart';
import 'package:media_server_client/features/auth/domain/models/qr_pair_session.dart';
import 'package:media_server_client/features/auth/data/auth_secure_storage.dart';
import 'package:media_server_client/features/auth/data/qr_auth_repository.dart';
import 'package:media_server_client/features/auth/presentation/providers/auth_providers.dart';
import 'package:media_server_client/features/auth/presentation/widgets/tv_pairing_sheet.dart';
import 'auth_secure_storage_test.dart';

class _FakeQrAuthRepository extends Fake implements QrAuthRepository {
  bool lookupSuccess = true;
  bool confirmSuccess = true;
  String? confirmedQrId;
  String? confirmedDeviceName;
  String? confirmedCode;

  @override
  Future<QrLookupResult> lookupPairCode(String code) async {
    if (!lookupSuccess) {
      throw const ValidationException('Pairing code not found or expired');
    }
    return QrLookupResult(qrId: 'qr-123', code: code.toUpperCase());
  }

  @override
  Future<bool> confirmPairSession({
    required String qrId,
    required String deviceName,
    String? code,
    String? sig,
  }) async {
    if (!confirmSuccess) {
      throw const AppException('Confirmation failed', statusCode: 500);
    }
    confirmedQrId = qrId;
    confirmedDeviceName = deviceName;
    confirmedCode = code;
    return true;
  }
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

  Widget buildTestableWidget() {
    return ProviderScope(
      overrides: [
        authSecureStorageProvider.overrideWithValue(authSecureStorage),
        qrAuthRepositoryProvider.overrideWithValue(fakeQrRepository),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: TvPairingSheet(),
        ),
      ),
    );
  }

  group('TvPairingSheet Widget', () {
    testWidgets('renders Link Android TV title, pairing code and device name inputs', (tester) async {
      await tester.pumpWidget(buildTestableWidget());
      await tester.pumpAndSettle();

      expect(find.text('Link Android TV'), findsOneWidget);
      expect(find.text('Enter the 5-character code from your TV screen'), findsOneWidget);
      expect(find.text('Pairing Code'), findsOneWidget);
      expect(find.text('TV or Device Name'), findsOneWidget);
      expect(find.text('Confirm & Link TV'), findsOneWidget);
    });

    testWidgets('shows validation error when pairing code is less than 5 characters', (tester) async {
      await tester.pumpWidget(buildTestableWidget());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'ABC');
      await tester.tap(find.text('Confirm & Link TV'));
      await tester.pumpAndSettle();

      expect(find.text('Pairing code must be 5 characters'), findsOneWidget);
    });

    testWidgets('successfully links TV when valid 5-character code is entered', (tester) async {
      await tester.pumpWidget(buildTestableWidget());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'K9X2P');
      await tester.enterText(find.byType(TextField).last, 'Living Room Sony TV');
      await tester.tap(find.text('Confirm & Link TV'));
      await tester.pump();

      expect(fakeQrRepository.confirmedQrId, equals('qr-123'));
      expect(fakeQrRepository.confirmedDeviceName, equals('Living Room Sony TV'));
      expect(fakeQrRepository.confirmedCode, equals('K9X2P'));

      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('TV Paired! Your TV will sign in automatically.'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(milliseconds: 1500));
    });

    testWidgets('displays error message when lookup fails', (tester) async {
      fakeQrRepository.lookupSuccess = false;

      await tester.pumpWidget(buildTestableWidget());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'BADCD');
      await tester.tap(find.text('Confirm & Link TV'));
      await tester.pumpAndSettle();

      expect(find.text('Pairing code not found or expired'), findsOneWidget);
    });
  });
}
