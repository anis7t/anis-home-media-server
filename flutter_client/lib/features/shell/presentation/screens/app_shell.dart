import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../core/device/infrastructure/device_capability_service.dart';
import '../../../intro/presentation/controllers/intro_controller.dart';
import '../../../intro/presentation/widgets/brand_intro_overlay.dart';
import '../widgets/tv_exit_dialog.dart';
import '../widgets/tv_side_navigation_rail.dart';

/// Persistent application shell hosting either a collapsible side navigation rail
/// (on Android TV / Fire TV) or a bottom navigation bar (on mobile phones/tablets)
/// across Home, Library, and Settings branches.
class AppShell extends ConsumerStatefulWidget {
  final StatefulNavigationShell navigationShell;
  final bool autoFinishIntroOnError;

  const AppShell({
    super.key,
    required this.navigationShell,
    this.autoFinishIntroOnError = true,
  });

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  DateTime? _lastBackTime;

  void _onDestinationSelected(int index) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  Future<void> _handleBack(BuildContext context) async {
    final now = DateTime.now();
    if (_lastBackTime != null && now.difference(_lastBackTime!).inMilliseconds < 350) {
      return;
    }
    _lastBackTime = now;

    final introState = ref.read(introControllerProvider);
    final isTv = ref.read(isTvModeProvider);
    final isRailExpanded = ref.read(tvRailExpandedProvider);
    final railNodes = ref.read(tvRailFocusNodesProvider);
    final hasRailFocus = isRailExpanded || railNodes.any((n) => n.hasFocus);

    if (introState.isPlaying) {
      ref.read(introControllerProvider.notifier).markFinished();
      return;
    }

    // 1. If TV side navigation rail is expanded or focused, collapse it and return focus to content
    if (isTv && hasRailFocus) {
      ref.read(tvRailExpandedProvider.notifier).collapse();
      final contentScope = ref.read(tvContentFocusScopeProvider);
      contentScope.requestFocus();
      if (contentScope.focusedChild == null) {
        contentScope.nextFocus();
      }
      return;
    }

    // 2. If on Library or Settings tab, return to the Home tab
    if (widget.navigationShell.currentIndex != 0) {
      widget.navigationShell.goBranch(0);
      return;
    }

    // 3. If at root Home screen on TV, prompt TV-friendly exit confirmation
    if (isTv) {
      final shouldExit = await TvExitDialog.show(context);
      if (shouldExit) {
        await SystemNavigator.pop();
      }
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final introState = ref.watch(introControllerProvider);
    final isTv = ref.watch(isTvModeProvider);

    return PopScope(
      canPop: !isTv && widget.navigationShell.currentIndex == 0 && !introState.isPlaying,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _handleBack(context);
      },
      child: Focus(
        autofocus: isTv,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.escape ||
                  event.logicalKey == LogicalKeyboardKey.goBack)) {
            _handleBack(context);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
          if (isTv)
            Scaffold(
              backgroundColor: AppColors.background,
              body: Row(
                children: [
                  TvSideNavigationRail(navigationShell: widget.navigationShell),
                  Expanded(
                    child: Actions(
                      actions: <Type, Action<Intent>>{
                        DirectionalFocusIntent: TvDirectionalFocusAction(
                          ref: ref,
                          navigationShell: widget.navigationShell,
                        ),
                      },
                      child: FocusScope(
                        node: ref.watch(tvContentFocusScopeProvider),
                        child: widget.navigationShell,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            Scaffold(
              backgroundColor: AppColors.background,
              body: widget.navigationShell,
              bottomNavigationBar: Container(
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  border: Border(
                    top: BorderSide(
                      color: AppColors.borderSubtle,
                      width: 1.0,
                    ),
                  ),
                ),
                child: NavigationBarTheme(
                  data: NavigationBarThemeData(
                    height: 64,
                    backgroundColor: AppColors.surface,
                    indicatorColor: AppColors.brandRed.withValues(alpha: 0.16),
                    iconTheme: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return const IconThemeData(
                          color: AppColors.brandRedLight,
                          size: 24,
                        );
                      }
                      return const IconThemeData(
                        color: AppColors.textMuted,
                        size: 24,
                      );
                    }),
                    labelTextStyle: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          letterSpacing: 0.2,
                        );
                      }
                      return const TextStyle(
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                        letterSpacing: 0.2,
                      );
                    }),
                  ),
                  child: NavigationBar(
                    selectedIndex: widget.navigationShell.currentIndex,
                    onDestinationSelected: _onDestinationSelected,
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.home_outlined),
                        selectedIcon: Icon(Icons.home_rounded),
                        label: 'Home',
                        tooltip: 'Home Dashboard',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.video_library_outlined),
                        selectedIcon: Icon(Icons.video_library_rounded),
                        label: 'Library',
                        tooltip: 'Movie Catalog',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.settings_outlined),
                        selectedIcon: Icon(Icons.settings_rounded),
                        label: 'Settings',
                        tooltip: 'Settings & Updates',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (introState.isPlaying)
            BrandIntroOverlay(
              autoFinishOnError: widget.autoFinishIntroOnError,
              onFinished: () =>
                  ref.read(introControllerProvider.notifier).markFinished(),
            ),
        ],
      ),
    ),
  );
}
}

/// Action intercepting directional D-pad focus intents within the TV content area.
///
/// When the user presses D-pad Left and directional focus traversal cannot find any
/// focusable candidate to the left (i.e. at the leftmost boundary of the content),
/// this action cleanly bridges focus to the active TV side navigation rail item and
/// expands the rail.
class TvDirectionalFocusAction extends Action<DirectionalFocusIntent> {
  final WidgetRef ref;
  final StatefulNavigationShell navigationShell;

  TvDirectionalFocusAction({
    required this.ref,
    required this.navigationShell,
  });

  @override
  Object? invoke(DirectionalFocusIntent intent) {
    if (intent.direction == TraversalDirection.left) {
      final moved = primaryFocus?.focusInDirection(TraversalDirection.left) ?? false;
      if (!moved) {
        // Leftmost boundary reached: transfer focus to side navigation rail
        final railNodes = ref.read(tvRailFocusNodesProvider);
        final currentBranch = navigationShell.currentIndex;
        if (currentBranch >= 0 && currentBranch < railNodes.length) {
          railNodes[currentBranch].requestFocus();
          ref.read(tvRailExpandedProvider.notifier).expand();
          return true;
        }
      }
      return moved;
    }
    return primaryFocus?.focusInDirection(intent.direction);
  }
}
