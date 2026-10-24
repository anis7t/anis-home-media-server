import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../controllers/library_controller.dart';

/// Modal bottom sheet for customizing library sorting and filtering.
///
/// Designed with obsidian glass styling and high touch targets (>= 48dp)
/// for responsive Android and desktop interaction.
class SortFilterSheet extends ConsumerWidget {
  const SortFilterSheet({super.key});

  /// Displays the modal sort and filter bottom sheet.
  static Future<void> show({required BuildContext context}) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => const SortFilterSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(libraryControllerProvider);
    final notifier = ref.read(libraryControllerProvider.notifier);
    final genres = state.availableGenres;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: Color(0xFF141822),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        border: Border(top: BorderSide(color: Color(0x33FFFFFF), width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle pill
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 12, 10),
              child: Row(
                children: [
                  const Icon(
                    Icons.filter_list_rounded,
                    color: AppColors.brandRed,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Sort & Filter',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (state.hasActiveFilters) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.brandRed,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${state.activeFilterCount}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (state.hasActiveFilters)
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () => notifier.resetFilters(),
                      child: const Text(
                        'Reset All',
                        style: TextStyle(
                          color: AppColors.brandRedLight,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white70,
                      size: 20,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0x1FFFFFFF), height: 1),

            // Scrollable Content
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Section 1: Watch Status
                    _buildSectionHeader('Watch Status'),
                    const SizedBox(height: 8),
                    _buildWatchStatusFilter(state, notifier),
                    const SizedBox(height: 20),

                    // Section 2: Genres
                    if (genres.isNotEmpty) ...[
                      _buildSectionHeader('Genre'),
                      const SizedBox(height: 8),
                      _buildGenreFilter(state, notifier, genres),
                      const SizedBox(height: 20),
                    ],

                    // Section 3: Sort Options
                    _buildSectionHeader('Sort By'),
                    const SizedBox(height: 8),
                    _buildSortOptions(state, notifier),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title.toUpperCase(),
      style: const TextStyle(
        color: AppColors.textMuted,
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _buildWatchStatusFilter(
    LibraryState state,
    LibraryController notifier,
  ) {
    final options = [
      (WatchStatusFilter.all, 'All'),
      (WatchStatusFilter.inProgress, 'In Progress'),
      (WatchStatusFilter.unwatched, 'Unwatched'),
      (WatchStatusFilter.completed, 'Completed'),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((opt) {
        final isSelected = state.watchStatusFilter == opt.$1;
        return _buildChip(
          label: opt.$2,
          isSelected: isSelected,
          onTap: () => notifier.setWatchStatusFilter(opt.$1),
        );
      }).toList(),
    );
  }

  Widget _buildGenreFilter(
    LibraryState state,
    LibraryController notifier,
    List<String> genres,
  ) {
    final currentGenre = state.selectedGenre;
    final isAll = currentGenre == null || currentGenre.isEmpty;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _buildChip(
          label: 'All Genres',
          isSelected: isAll,
          onTap: () => notifier.setSelectedGenre(null),
        ),
        ...genres.map((g) {
          final isSelected = currentGenre?.toLowerCase() == g.toLowerCase();
          return _buildChip(
            label: g,
            isSelected: isSelected,
            onTap: () => notifier.setSelectedGenre(isSelected ? null : g),
          );
        }),
      ],
    );
  }

  Widget _buildChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.brandRed.withValues(alpha: 0.20)
                : AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected ? AppColors.brandRed : AppColors.borderSubtle,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? Colors.white : AppColors.textSecondary,
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSortOptions(LibraryState state, LibraryController notifier) {
    final options = [
      (SortOption.titleAsc, 'Title (A → Z)', Icons.sort_by_alpha_rounded),
      (SortOption.titleDesc, 'Title (Z → A)', Icons.sort_by_alpha_rounded),
      (
        SortOption.yearDesc,
        'Release Year (Newest first)',
        Icons.calendar_today_rounded,
      ),
      (
        SortOption.yearAsc,
        'Release Year (Oldest first)',
        Icons.history_rounded,
      ),
      (SortOption.ratingDesc, 'Rating (Highest first)', Icons.star_rounded),
      (
        SortOption.progressDesc,
        'Watch Progress (% completed)',
        Icons.play_circle_outline_rounded,
      ),
      (SortOption.recentlyAdded, 'Recently Added', Icons.schedule_rounded),
    ];

    return Column(
      children: options.map((opt) {
        final isSelected = state.sortOption == opt.$1;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => notifier.setSortOption(opt.$1),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.surfaceElevated
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected
                      ? AppColors.brandRed.withValues(alpha: 0.4)
                      : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    opt.$3,
                    color: isSelected
                        ? AppColors.brandRed
                        : AppColors.textMuted,
                    size: 18,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      opt.$2,
                      style: TextStyle(
                        color: isSelected
                            ? Colors.white
                            : AppColors.textPrimary,
                        fontSize: 13.5,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                  if (isSelected)
                    const Icon(
                      Icons.check_rounded,
                      color: AppColors.brandRed,
                      size: 20,
                    ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
