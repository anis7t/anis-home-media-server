import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/theme/app_colors.dart';

/// Persistent mobile application shell hosting bottom navigation bar
/// across Home, Library, and Settings branches.
class AppShell extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const AppShell({
    super.key,
    required this.navigationShell,
  });

  void _onDestinationSelected(int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: navigationShell.currentIndex == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && navigationShell.currentIndex != 0) {
          // Navigating back from Library or Settings returns to the Home tab
          navigationShell.goBranch(0);
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: navigationShell,
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
              selectedIndex: navigationShell.currentIndex,
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
    );
  }
}
