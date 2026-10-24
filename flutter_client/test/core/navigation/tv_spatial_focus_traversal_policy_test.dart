import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/navigation/tv_spatial_focus_traversal_policy.dart';

void main() {
  group('TvSpatialFocusTraversalPolicy Unit & Geometry Tests', () {
    late TvSpatialFocusTraversalPolicy policy;

    setUp(() {
      policy = TvSpatialFocusTraversalPolicy();
    });

    testWidgets('findFirstFocusInDirection selects correct initial edge node', (
      WidgetTester tester,
    ) async {
      final nodeTopLeft = FocusNode(debugLabel: 'top_left');
      final nodeTopRight = FocusNode(debugLabel: 'top_right');
      final nodeBottom = FocusNode(debugLabel: 'bottom');
      addTearDown(() {
        nodeTopLeft.dispose();
        nodeTopRight.dispose();
        nodeBottom.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusTraversalGroup(
              policy: policy,
              child: FocusScope(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 100,
                          height: 40,
                          child: Focus(focusNode: nodeTopLeft, child: const Text('Top Left')),
                        ),
                        SizedBox(
                          width: 100,
                          height: 40,
                          child: Focus(focusNode: nodeTopRight, child: const Text('Top Right')),
                        ),
                      ],
                    ),
                    SizedBox(
                      width: 200,
                      height: 40,
                      child: Focus(focusNode: nodeBottom, child: const Text('Bottom')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final firstDown = policy.findFirstFocusInDirection(nodeTopLeft, TraversalDirection.down);
      expect(firstDown, equals(nodeTopLeft));

      final firstUp = policy.findFirstFocusInDirection(nodeTopLeft, TraversalDirection.up);
      expect(firstUp, equals(nodeBottom));

      final firstRight = policy.findFirstFocusInDirection(nodeTopLeft, TraversalDirection.right);
      expect(firstRight, equals(nodeTopLeft));

      final firstLeft = policy.findFirstFocusInDirection(nodeTopLeft, TraversalDirection.left);
      expect(firstLeft, equals(nodeTopRight));
    });

    testWidgets('Vertical navigation reaches horizontally offset adjacent row without skipping to farther element', (
      WidgetTester tester,
    ) async {
      // Simulates wrapped preset chips (e.g. WAN & LAN on row 1, Localhost on row 2, Test Connection below)
      final nodeWan = FocusNode(debugLabel: 'wan');
      final nodeLan = FocusNode(debugLabel: 'lan');
      final nodeLocalhost = FocusNode(debugLabel: 'localhost');
      final nodeTestButton = FocusNode(debugLabel: 'test_button');
      addTearDown(() {
        nodeWan.dispose();
        nodeLan.dispose();
        nodeLocalhost.dispose();
        nodeTestButton.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusTraversalGroup(
              policy: policy,
              child: FocusScope(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Row 1: WAN (left) and LAN (middle)
                    Row(
                      children: [
                        SizedBox(
                          width: 120,
                          height: 36,
                          child: Focus(focusNode: nodeWan, child: const Text('WAN')),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 120,
                          height: 36,
                          child: Focus(focusNode: nodeLan, child: const Text('LAN')),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // Row 2: Localhost (wrapped to left side)
                    SizedBox(
                      width: 100,
                      height: 36,
                      child: Focus(focusNode: nodeLocalhost, child: const Text('Localhost')),
                    ),
                    const SizedBox(height: 30),
                    // Row 3: Wide Test Button spanning across the bottom
                    SizedBox(
                      width: 300,
                      height: 48,
                      child: Focus(focusNode: nodeTestButton, child: const Text('Test Button')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Focus on LAN (offset to right: X: 128..248, Y: 0..36)
      nodeLan.requestFocus();
      await tester.pump();
      expect(nodeLan.hasFocus, isTrue);

      // Press Down: MUST land on Localhost (Row 2, X: 0..100, Y: 46..82) rather than jumping over to Test Button (Row 3, Y: 112..160)
      final movedDown = policy.inDirection(nodeLan, TraversalDirection.down);
      await tester.pump();
      expect(movedDown, isTrue);
      expect(nodeLocalhost.hasFocus, isTrue, reason: 'Pressing Down from LAN must not skip the adjacent Localhost row');

      // Now press Down from Localhost: moves to Test Button
      final movedDownToButton = policy.inDirection(nodeLocalhost, TraversalDirection.down);
      await tester.pump();
      expect(movedDownToButton, isTrue);
      expect(nodeTestButton.hasFocus, isTrue);

      // Now press Up from Test Button: moves back to Localhost (nearest row above)
      final movedUpFromButton = policy.inDirection(nodeTestButton, TraversalDirection.up);
      await tester.pump();
      expect(movedUpFromButton, isTrue);
      expect(nodeLocalhost.hasFocus, isTrue, reason: 'Pressing Up from Test Button must land on Localhost rather than skipping it');
    });

    testWidgets('Does not navigate Down/Up between side-by-side elements in the same row', (
      WidgetTester tester,
    ) async {
      final nodeA = FocusNode(debugLabel: 'itemA');
      final nodeB = FocusNode(debugLabel: 'itemB');
      addTearDown(() {
        nodeA.dispose();
        nodeB.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusTraversalGroup(
              policy: policy,
              child: FocusScope(
                child: Row(
                  children: [
                    SizedBox(
                      width: 100,
                      height: 40,
                      child: Focus(focusNode: nodeA, child: const Text('A')),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 100,
                      height: 40,
                      child: Focus(focusNode: nodeB, child: const Text('B')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      nodeA.requestFocus();
      await tester.pump();
      expect(nodeA.hasFocus, isTrue);

      // Down should return false because there is no row below
      final movedDown = policy.inDirection(nodeA, TraversalDirection.down);
      expect(movedDown, isFalse);
      expect(nodeA.hasFocus, isTrue);

      // Right moves to B
      final movedRight = policy.inDirection(nodeA, TraversalDirection.right);
      await tester.pump();
      expect(movedRight, isTrue);
      expect(nodeB.hasFocus, isTrue);
    });

    testWidgets('Key navigation through Settings stack works vertically without skipping', (
      WidgetTester tester,
    ) async {
      final cardServer = FocusNode(debugLabel: 'server');
      final cardDeviceId = FocusNode(debugLabel: 'device_id');
      final cardProdChannel = FocusNode(debugLabel: 'prod_channel');
      final cardDevChannel = FocusNode(debugLabel: 'dev_channel');
      final btnCheckUpdate = FocusNode(debugLabel: 'check_update');
      addTearDown(() {
        cardServer.dispose();
        cardDeviceId.dispose();
        cardProdChannel.dispose();
        cardDevChannel.dispose();
        btnCheckUpdate.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusTraversalGroup(
              policy: policy,
              child: FocusScope(
                child: ListView(
                  children: [
                    SizedBox(height: 60, child: Focus(focusNode: cardServer, child: const Text('Server'))),
                    const SizedBox(height: 10),
                    SizedBox(height: 40, child: Focus(focusNode: cardDeviceId, child: const Text('Device ID'))),
                    const SizedBox(height: 16),
                    SizedBox(height: 50, child: Focus(focusNode: cardProdChannel, child: const Text('Prod Channel'))),
                    const SizedBox(height: 8),
                    SizedBox(height: 50, child: Focus(focusNode: cardDevChannel, child: const Text('Dev Channel'))),
                    const SizedBox(height: 16),
                    SizedBox(height: 44, child: Focus(focusNode: btnCheckUpdate, child: const Text('Check Update'))),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      cardServer.requestFocus();
      await tester.pump();
      expect(cardServer.hasFocus, isTrue);

      // Down sequence through all cards
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(cardDeviceId.hasFocus, isTrue, reason: 'Down from Server reaches Device ID');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(cardProdChannel.hasFocus, isTrue, reason: 'Down from Device ID reaches Prod Channel');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(cardDevChannel.hasFocus, isTrue, reason: 'Down from Prod Channel reaches Dev Channel');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(btnCheckUpdate.hasFocus, isTrue, reason: 'Down from Dev Channel reaches Check Update');

      // Up sequence backwards
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(cardDevChannel.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(cardProdChannel.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(cardDeviceId.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(cardServer.hasFocus, isTrue);
    });
  });
}
