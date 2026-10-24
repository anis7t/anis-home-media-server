import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/widgets/tv_focusable.dart';
import '../../../library/presentation/controllers/library_controller.dart';
import '../controllers/home_feed_controller.dart';

/// Ultra-translucent frosted obsidian slide-out drawer presenting a modern hierarchical tree
/// for instant catalog exploration across Movies, Genres, Decades, and System Settings.
class FrostedTreeDrawer extends ConsumerStatefulWidget {
  final ValueChanged<String>? onGenreSelected;
  final ValueChanged<String>? onDecadeSelected;

  const FrostedTreeDrawer({
    super.key,
    this.onGenreSelected,
    this.onDecadeSelected,
  });

  @override
  ConsumerState<FrostedTreeDrawer> createState() => _FrostedTreeDrawerState();
}

class _FrostedTreeDrawerState extends ConsumerState<FrostedTreeDrawer> {
  bool _isGenresExpanded = true;
  bool _isDecadesExpanded = false;

  @override
  Widget build(BuildContext context) {
    final feedState = ref.watch(homeFeedControllerProvider);
    final mediaQuery = MediaQuery.of(context);
    final drawerWidth = (mediaQuery.size.width * 0.82).clamp(300.0, 380.0);

    return ClipRRect(
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(20)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
        child: Container(
          width: drawerWidth,
          height: mediaQuery.size.height,
          decoration: BoxDecoration(
            color: const Color(0xDD090B10), // ~87% opacity obsidian
            border: const Border(
              right: BorderSide(color: AppColors.borderMedium, width: 1.2),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.55),
                blurRadius: 32,
                spreadRadius: 8,
              ),
              BoxShadow(
                color: AppColors.brandRedGlow.withValues(alpha: 0.25),
                blurRadius: 40,
                spreadRadius: 2,
              ),
            ],
          ),
          child: SafeArea(
            child: Column(
              children: [
                _buildHeader(context, feedState.totalMovieCount),
                const Divider(height: 1, color: AppColors.borderSubtle),
                Expanded(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    children: [
                      // Section 1: Primary Root Nodes
                      _buildTreeNode(
                        context: context,
                        icon: Icons.movie_outlined,
                        label: 'All Movies',
                        badge: '${feedState.totalMovieCount}',
                        onTap: () {
                          Navigator.of(context).pop();
                          ref.read(libraryControllerProvider.notifier).resetFilters();
                          context.go(AppRoutes.library);
                        },
                      ),
                      const SizedBox(height: 4),
                      _buildTreeNode(
                        context: context,
                        icon: Icons.access_time_rounded,
                        label: 'Recently Added',
                        badge: 'NEW',
                        badgeColor: AppColors.brandRed,
                        onTap: () {
                          Navigator.of(context).pop();
                          ref
                              .read(libraryControllerProvider.notifier)
                              .setSortOption(SortOption.recentlyAdded);
                          context.go(AppRoutes.library);
                        },
                      ),

                      const SizedBox(height: 16),
                      _buildTreeSectionHeader('HIERARCHICAL DISCOVERY'),
                      const SizedBox(height: 6),

                      // Section 2: Expandable Genres Branch
                      _buildExpandableBranch(
                        icon: Icons.category_outlined,
                        label: 'Genres',
                        count: feedState.allGenreSections.length,
                        isExpanded: _isGenresExpanded,
                        onToggle: () {
                          setState(() {
                            _isGenresExpanded = !_isGenresExpanded;
                          });
                        },
                        children: [
                          for (final section in feedState.allGenreSections)
                            _buildTreeLeaf(
                              context: context,
                              label: section.genre,
                              count: section.totalCount,
                              onTap: () {
                                Navigator.of(context).pop();
                                if (widget.onGenreSelected != null) {
                                  widget.onGenreSelected!(section.genre);
                                } else {
                                  ref
                                      .read(libraryControllerProvider.notifier)
                                      .setSelectedGenre(section.genre);
                                  context.go(AppRoutes.library);
                                }
                              },
                            ),
                        ],
                      ),

                      const SizedBox(height: 10),

                      // Section 3: Expandable Decades Branch
                      _buildExpandableBranch(
                        icon: Icons.date_range_outlined,
                        label: 'Release Eras',
                        count: feedState.decadeSections.length,
                        isExpanded: _isDecadesExpanded,
                        onToggle: () {
                          setState(() {
                            _isDecadesExpanded = !_isDecadesExpanded;
                          });
                        },
                        children: [
                          for (final decade in feedState.decadeSections)
                            _buildTreeLeaf(
                              context: context,
                              label: decade.label,
                              count: decade.count,
                              onTap: () {
                                Navigator.of(context).pop();
                                if (widget.onDecadeSelected != null) {
                                  widget.onDecadeSelected!(decade.label);
                                } else {
                                  // Set search query for era or navigate to library
                                  final query = decade.minYear != null
                                      ? decade.minYear!.toString().substring(0, 3)
                                      : '';
                                  ref
                                      .read(libraryControllerProvider.notifier)
                                      .setSearchQuery(query);
                                  context.go(AppRoutes.library);
                                }
                              },
                            ),
                        ],
                      ),

                      const SizedBox(height: 20),
                      const Divider(height: 1, color: AppColors.borderSubtle),
                      const SizedBox(height: 12),
                      _buildTreeSectionHeader('SYSTEM & MANAGEMENT'),
                      const SizedBox(height: 6),

                      // Section 4: System Navigation
                      _buildTreeNode(
                        context: context,
                        icon: Icons.tune_rounded,
                        label: 'Settings & Updates',
                        onTap: () {
                          Navigator.of(context).pop();
                          context.go(AppRoutes.settings);
                        },
                      ),
                      const SizedBox(height: 4),
                      _buildTreeNode(
                        context: context,
                        icon: Icons.admin_panel_settings_outlined,
                        label: 'Admin Management Hub',
                        badge: 'ADMIN',
                        badgeColor: AppColors.statusWarning,
                        onTap: () {
                          Navigator.of(context).pop();
                          context.push(AppRoutes.adminHub);
                        },
                      ),
                    ],
                  ),
                ),
                _buildFooter(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, int totalMovies) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
      child: Row(
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
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: const Center(
              child: Icon(
                Icons.account_tree_rounded,
                color: AppColors.brandRedLight,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Media Catalog Tree',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$totalMovies TITLES • HIERARCHICAL NAV',
                  style: AppTypography.labelSmall.copyWith(
                    color: AppColors.textMuted,
                    letterSpacing: 1.1,
                    fontSize: 9.5,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close Menu',
            icon: const Icon(
              Icons.close_rounded,
              color: AppColors.textSecondary,
              size: 20,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildTreeSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildTreeNode({
    required BuildContext context,
    required IconData icon,
    required String label,
    String? badge,
    Color? badgeColor,
    required VoidCallback onTap,
  }) {
    return TvFocusable(
      borderRadius: BorderRadius.circular(10),
      onPressed: onTap,
      builder: (context, isFocused, _) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isFocused
                ? AppColors.surfaceHighlight
                : Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isFocused ? AppColors.brandRed : AppColors.borderSubtle,
              width: isFocused ? 1.8 : 1.0,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: isFocused ? AppColors.brandRedLight : AppColors.textSecondary,
                size: 19,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: isFocused
                        ? AppColors.textPrimary
                        : AppColors.textPrimary.withValues(alpha: 0.9),
                    fontSize: 13.5,
                    fontWeight: isFocused ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ),
              if (badge != null) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                  decoration: BoxDecoration(
                    color: (badgeColor ?? AppColors.surfaceElevated)
                        .withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: (badgeColor ?? AppColors.borderMedium)
                          .withValues(alpha: 0.5),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    badge,
                    style: TextStyle(
                      color: badgeColor ?? AppColors.textSecondary,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildExpandableBranch({
    required IconData icon,
    required String label,
    required int count,
    required bool isExpanded,
    required VoidCallback onToggle,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        children: [
          TvFocusable(
            borderRadius: BorderRadius.circular(12),
            onPressed: onToggle,
            builder: (context, isFocused, _) {
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                decoration: BoxDecoration(
                  color: isFocused ? AppColors.surfaceHighlight : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      color: isFocused
                          ? AppColors.brandRedLight
                          : AppColors.textSecondary,
                      size: 19,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13.5,
                          fontWeight:
                              isFocused ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: Text(
                        '$count',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      isExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: AppColors.textSecondary,
                      size: 18,
                    ),
                  ],
                ),
              );
            },
          ),
          if (isExpanded) ...[
            Container(
              margin: const EdgeInsets.only(left: 20, right: 8, bottom: 8),
              padding: const EdgeInsets.only(left: 10),
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: AppColors.borderMedium, width: 1.2),
                ),
              ),
              child: Column(
                children: children,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTreeLeaf({
    required BuildContext context,
    required String label,
    required int count,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: TvFocusable(
        borderRadius: BorderRadius.circular(8),
        onPressed: onTap,
        builder: (context, isFocused, _) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: isFocused
                  ? AppColors.surfaceHighlight
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isFocused ? AppColors.brandRed : Colors.transparent,
                width: 1.2,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: isFocused
                        ? AppColors.brandRedLight
                        : AppColors.textMuted,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: isFocused
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                      fontSize: 12.5,
                      fontWeight:
                          isFocused ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  '$count',
                  style: TextStyle(
                    color: isFocused
                        ? AppColors.brandRedLight
                        : AppColors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: AppColors.statusSuccess,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'Connected Server',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const Text(
            'v1.4.0',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
