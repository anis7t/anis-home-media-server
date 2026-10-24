import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/widgets/tv_focusable.dart';

/// Notifier tracking whether the TV side navigation rail is currently expanded.
class TvRailExpandedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setExpanded(bool value) => state = value;
  void expand() => state = true;
  void collapse() => state = false;
}

/// Riverpod provider tracking whether the TV side navigation rail is currently expanded.
final tvRailExpandedProvider =
    NotifierProvider<TvRailExpandedNotifier, bool>(TvRailExpandedNotifier.new);

/// Riverpod provider managing focus nodes for the TV rail items:
/// [0] Home, [1] Library, [2] Settings.
final tvRailFocusNodesProvider = Provider<List<FocusNode>>((ref) {
  final nodes = [
    FocusNode(debugLabel: 'tv_rail_home'),
    FocusNode(debugLabel: 'tv_rail_library'),
    FocusNode(debugLabel: 'tv_rail_settings'),
  ];
  ref.onDispose(() {
    for (final node in nodes) {
      node.dispose();
    }
  });
  return nodes;
});

/// Riverpod provider managing the TV content focus scope.
///
/// When navigating from the TV rail back to content (via D-pad Right, Left, or Back),
/// requesting focus on this scope automatically restores focus to the previously
/// focused widget in the active branch.
final tvContentFocusScopeProvider = Provider<FocusScopeNode>((ref) {
  final scope = FocusScopeNode(debugLabel: 'tv_content_scope');
  ref.onDispose(scope.dispose);
  return scope;
});

/// 10-foot collapsible obsidian side navigation rail for Android TV and Fire TV Stick.
///
/// Remains in collapsed icon-only mode (~68dp) while browsing content, and smoothly
/// expands to ~220dp with labels when navigation focus enters the rail via D-pad Left.
class TvSideNavigationRail extends ConsumerStatefulWidget {
  final StatefulNavigationShell navigationShell;

  const TvSideNavigationRail({
    super.key,
    required this.navigationShell,
  });

  @override
  ConsumerState<TvSideNavigationRail> createState() => _TvSideNavigationRailState();
}

class _TvSideNavigationRailState extends ConsumerState<TvSideNavigationRail> {
  void _onDestinationSelected(int index) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  void _collapseRail() {
    ref.read(tvRailExpandedProvider.notifier).setExpanded(false);
  }

  void _moveToContent() {
    _collapseRail();
    final contentScope = ref.read(tvContentFocusScopeProvider);
    contentScope.requestFocus();
    if (contentScope.focusedChild == null) {
      contentScope.nextFocus();
    }
  }

  void _collapseAndReturn() {
    _collapseRail();
    final contentScope = ref.read(tvContentFocusScopeProvider);
    contentScope.requestFocus();
    if (contentScope.focusedChild == null) {
      contentScope.nextFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = widget.navigationShell.currentIndex;
    final isExpanded = ref.watch(tvRailExpandedProvider);
    final railFocusNodes = ref.watch(tvRailFocusNodesProvider);

    return Focus(
      onFocusChange: (hasNavFocus) {
        if (!hasNavFocus && isExpanded) {
          _collapseRail();
        }
      },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          width: isExpanded ? 220 : 68,
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.95),
            border: const Border(
              right: BorderSide(
                color: AppColors.borderSubtle,
                width: 1.0,
              ),
            ),
            boxShadow: isExpanded
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 24,
                      spreadRadius: 4,
                    ),
                  ]
                : null,
          ),
          child: SafeArea(
            right: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),
                // Brand Header
                _buildBrandHeader(isExpanded),
                const SizedBox(height: 24),

                // Navigation Destinations
                _TvRailItem(
                  index: 0,
                  focusNode: railFocusNodes[0],
                  isSelected: currentIndex == 0,
                  isExpanded: isExpanded,
                  icon: Icons.home_outlined,
                  selectedIcon: Icons.home_rounded,
                  label: 'Home',
                  onTap: () => _onDestinationSelected(0),
                  onGainFocus: () {
                    ref.read(tvRailExpandedProvider.notifier).setExpanded(true);
                  },
                  onRight: _moveToContent,
                  onLeft: _collapseAndReturn,
                ),
                const SizedBox(height: 8),
                _TvRailItem(
                  index: 1,
                  focusNode: railFocusNodes[1],
                  isSelected: currentIndex == 1,
                  isExpanded: isExpanded,
                  icon: Icons.video_library_outlined,
                  selectedIcon: Icons.video_library_rounded,
                  label: 'Library',
                  onTap: () => _onDestinationSelected(1),
                  onGainFocus: () {
                    ref.read(tvRailExpandedProvider.notifier).setExpanded(true);
                  },
                  onRight: _moveToContent,
                  onLeft: _collapseAndReturn,
                ),
                const SizedBox(height: 8),
                _TvRailItem(
                  index: 2,
                  focusNode: railFocusNodes[2],
                  isSelected: currentIndex == 2,
                  isExpanded: isExpanded,
                  icon: Icons.settings_outlined,
                  selectedIcon: Icons.settings_rounded,
                  label: 'Settings',
                  onTap: () => _onDestinationSelected(2),
                  onGainFocus: () {
                    ref.read(tvRailExpandedProvider.notifier).setExpanded(true);
                  },
                  onRight: _moveToContent,
                  onLeft: _collapseAndReturn,
                ),

                const Spacer(),

                // TV D-Pad hint at bottom when expanded
                if (isExpanded)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const NeverScrollableScrollPhysics(),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.arrow_forward_rounded,
                            size: 14,
                            color: AppColors.textMuted,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Right to content',
                            style: AppTypography.labelSmall.copyWith(
                              color: AppColors.textMuted,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
  }

  Widget _buildBrandHeader(bool isExpanded) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.borderMedium),
                boxShadow: const [
                  BoxShadow(
                    color: AppColors.brandRedGlow,
                    blurRadius: 14,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: const Center(
                child: Icon(
                  Icons.play_arrow_rounded,
                  color: AppColors.brandRed,
                  size: 24,
                ),
              ),
            ),
            if (isExpanded) ...[
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'AHMS',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Text(
                    'MEDIA SERVER',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.labelSmall.copyWith(
                      color: AppColors.brandRedLight,
                      fontWeight: FontWeight.w700,
                      fontSize: 8.5,
                      letterSpacing: 1.0,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TvRailItem extends StatelessWidget {
  final int index;
  final FocusNode focusNode;
  final bool isSelected;
  final bool isExpanded;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final VoidCallback onTap;
  final VoidCallback onGainFocus;
  final VoidCallback onRight;
  final VoidCallback onLeft;

  const _TvRailItem({
    required this.index,
    required this.focusNode,
    required this.isSelected,
    required this.isExpanded,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.onTap,
    required this.onGainFocus,
    required this.onRight,
    required this.onLeft,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: TvFocusable(
        focusNode: focusNode,
        borderRadius: BorderRadius.circular(12),
        onPressed: onTap,
        autoScroll: false,
        onFocusChange: (focused) {
          if (focused) {
            onGainFocus();
          }
        },
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              onRight();
              return KeyEventResult.handled;
            } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              onLeft();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        builder: (context, isFoc, _) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            decoration: BoxDecoration(
              color: isFoc
                  ? AppColors.brandRed.withValues(alpha: 0.22)
                  : isSelected
                      ? AppColors.surfaceElevated
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isFoc
                    ? AppColors.brandRed
                    : isSelected
                        ? AppColors.borderSubtle
                        : Colors.transparent,
                width: isFoc ? 2.5 : 1.0,
              ),
              boxShadow: isFoc
                  ? [
                      BoxShadow(
                        color: AppColors.brandRedGlow.withValues(alpha: 0.6),
                        blurRadius: 16,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isSelected ? selectedIcon : icon,
                    size: 24,
                    color: isFoc || isSelected
                        ? AppColors.brandRedLight
                        : AppColors.textMuted,
                  ),
                  if (isExpanded) ...[
                    const SizedBox(width: 14),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isFoc || isSelected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                        fontWeight:
                            isSelected ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 14,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
