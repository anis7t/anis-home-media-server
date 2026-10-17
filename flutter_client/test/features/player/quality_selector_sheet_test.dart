import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/domain/quality_option.dart';
import 'package:media_server_client/features/player/presentation/widgets/quality_selector_sheet.dart';

void main() {
  final sampleLadder = [
    const QualityOption(
      label: '4K UHD',
      quality: '4k',
      height: 2160,
      width: 3840,
      bitrate: 18000000,
      isDirect: false,
      isReady: false,
    ),
    const QualityOption(
      label: '1080p FHD',
      quality: '1080p',
      height: 1080,
      width: 1920,
      bitrate: 4500000,
      isDirect: false,
      isReady: true,
    ),
    const QualityOption(
      label: '720p HD',
      quality: '720p',
      height: 720,
      width: 1280,
      bitrate: 2200000,
      isDirect: false,
      isReady: false,
    ),
  ];

  Widget buildTestWidget({
    required List<QualityOption> qualityLadder,
    required String selectedQuality,
    required ValueChanged<QualityOption> onQualitySelected,
    bool supportsDirectPlay = true,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: QualitySelectorSheet(
          qualityLadder: qualityLadder,
          selectedQuality: selectedQuality,
          onQualitySelected: onQualitySelected,
          supportsDirectPlay: supportsDirectPlay,
        ),
      ),
    );
  }

  group('QualitySelectorSheet Widget Tests', () {
    testWidgets('renders Playback Quality title and default options', (tester) async {
      await tester.pumpWidget(
        buildTestWidget(
          qualityLadder: sampleLadder,
          selectedQuality: 'auto',
          onQualitySelected: (_) {},
          supportsDirectPlay: true,
        ),
      );

      expect(find.text('Playback Quality'), findsOneWidget);
      expect(find.text('Auto (Adaptive Stream)'), findsOneWidget);
      expect(find.text('Original (Direct Play)'), findsOneWidget);
      expect(find.text('1080p FHD'), findsOneWidget);
      expect(find.text('720p HD'), findsOneWidget);
      expect(find.text('4K UHD'), findsOneWidget);
    });

    testWidgets('omits Original Direct Play when supportsDirectPlay is false', (tester) async {
      await tester.pumpWidget(
        buildTestWidget(
          qualityLadder: sampleLadder,
          selectedQuality: 'auto',
          onQualitySelected: (_) {},
          supportsDirectPlay: false,
        ),
      );

      expect(find.text('Auto (Adaptive Stream)'), findsOneWidget);
      expect(find.text('Original (Direct Play)'), findsNothing);
      expect(find.text('1080p FHD'), findsOneWidget);
    });

    testWidgets('renders ON-DEMAND badge for non-ready tiers', (tester) async {
      await tester.pumpWidget(
        buildTestWidget(
          qualityLadder: sampleLadder,
          selectedQuality: 'auto',
          onQualitySelected: (_) {},
          supportsDirectPlay: false,
        ),
      );

      // 4K and 720p are isReady=false -> ON-DEMAND (2 widgets)
      expect(find.text('ON-DEMAND'), findsNWidgets(2));
    });

    testWidgets('triggers onQualitySelected on tap', (tester) async {
      QualityOption? selected;
      await tester.pumpWidget(
        buildTestWidget(
          qualityLadder: sampleLadder,
          selectedQuality: 'auto',
          onQualitySelected: (opt) => selected = opt,
          supportsDirectPlay: true,
        ),
      );

      await tester.tap(find.text('1080p FHD'));
      await tester.pump();

      expect(selected, isNotNull);
      expect(selected!.quality, '1080p');
      expect(selected!.height, 1080);
      expect(selected!.isReady, isTrue);
    });
  });
}
