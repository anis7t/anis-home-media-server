import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/admin_providers.dart';
import '../widgets/storage_pool_hud.dart';

class StorageManagementView extends ConsumerWidget {
  const StorageManagementView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      onRefresh: () => ref.read(storageControllerProvider.notifier).refresh(),
      child: const SingleChildScrollView(
        physics: AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: StoragePoolHud(),
      ),
    );
  }
}
