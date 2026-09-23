import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_typography.dart';
import '../controllers/connection_controller.dart';
import '../models/connection_state.dart';

class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key});

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    final initialState = ref.read(connectionControllerProvider);
    _urlController = TextEditingController(text: initialState.serverUrl);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(connectionControllerProvider);

    // Keep text controller in sync if state changed externally
    if (_urlController.text != state.serverUrl &&
        state.status != ConnectionStatus.testing) {
      _urlController.text = state.serverUrl;
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 32),
                  _buildConnectionCard(state),
                  const SizedBox(height: 20),
                  _buildDeviceIdentityCard(state),
                  const SizedBox(height: 24),
                  _buildActions(state),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.borderMedium),
            boxShadow: const [
              BoxShadow(
                color: AppColors.brandRedGlow,
                blurRadius: 24,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Center(
            child: Icon(
              Icons.play_arrow_rounded,
              color: AppColors.brandRed,
              size: 38,
            ),
          ),
        ),
        const SizedBox(height: 16),
        RichText(
          textAlign: TextAlign.center,
          text: const TextSpan(
            style: AppTypography.displayMedium,
            children: [
              TextSpan(text: "Anis' "),
              TextSpan(
                text: "Home Media Server",
                style: TextStyle(color: AppColors.brandRedLight),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'PLAY • ORGANIZE • ENJOY',
          style: AppTypography.labelSmall,
        ),
      ],
    );
  }

  Widget _buildConnectionCard(ServerConnectionState state) {
    return Card(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.borderSubtle),
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.dns_outlined,
                      size: 20,
                      color: AppColors.brandRedLight,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Server Origin',
                      style: AppTypography.titleMedium,
                    ),
                  ],
                ),
                _buildStatusBadge(state),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                hintText: 'http://127.0.0.1:8000',
                prefixIcon: const Icon(
                  Icons.link,
                  color: AppColors.textMuted,
                  size: 20,
                ),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Reset to default',
                  onPressed: () {
                    _urlController.text = 'http://127.0.0.1:8000';
                    ref
                        .read(connectionControllerProvider.notifier)
                        .updateUrl('http://127.0.0.1:8000');
                  },
                ),
              ),
              style: AppTypography.bodyLarge,
              onChanged: (val) {
                ref.read(connectionControllerProvider.notifier).updateUrl(val);
              },
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: state.status == ConnectionStatus.testing
                    ? null
                    : () {
                        ref
                            .read(connectionControllerProvider.notifier)
                            .testConnection();
                      },
                icon: state.status == ConnectionStatus.testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.brandRed,
                        ),
                      )
                    : const Icon(Icons.network_check_outlined, size: 18),
                label: Text(
                  state.status == ConnectionStatus.testing
                      ? 'Testing Connection...'
                      : 'Test Connection',
                ),
              ),
            ),
            if (state.status == ConnectionStatus.connected) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: Column(
                  children: [
                    _buildInfoRow('Status', 'Online (Ready)', AppColors.statusSuccess),
                    const SizedBox(height: 6),
                    _buildInfoRow('Latency', '${state.latencyMs ?? 0} ms', AppColors.textPrimary),
                    if (state.hostname != null) ...[
                      const SizedBox(height: 6),
                      _buildInfoRow('Host', state.hostname!, AppColors.textPrimary),
                    ],
                  ],
                ),
              ),
            ],
            if (state.status == ConnectionStatus.failed && state.errorMessage != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.statusError.withValues(alpha: 0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: AppColors.statusError,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        state.errorMessage!,
                        style: AppTypography.bodyMedium.copyWith(
                          color: AppColors.statusError,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceIdentityCard(ServerConnectionState state) {
    return Card(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.borderSubtle),
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.fingerprint,
                      size: 20,
                      color: AppColors.brandRedLight,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Client Device Identity',
                      style: AppTypography.titleMedium,
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.statusSuccess.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppColors.statusSuccess.withValues(alpha: 0.3),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 13,
                        color: AppColors.statusSuccess,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'CSPRNG Verified',
                        style: TextStyle(
                          color: AppColors.statusSuccess,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Cryptographically persistent identity attached as X-Device-Id on all requests. Reused across restarts.',
              style: AppTypography.bodyMedium,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.devices,
                    size: 18,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SelectableText(
                      state.deviceId,
                      style: AppTypography.mono.copyWith(
                        color: AppColors.brandRedLight,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16),
                    tooltip: 'Copy Device ID',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: state.deviceId));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Device ID copied to clipboard'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActions(ServerConnectionState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton(
          onPressed: state.isSaving
              ? null
              : () async {
                  final ok = await ref
                      .read(connectionControllerProvider.notifier)
                      .saveSettings();
                  if (ok && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Server configuration saved successfully'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                },
          child: state.isSaving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Save & Set Active Server'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () {
            context.push(AppRoutes.playerPoc);
          },
          icon: const Icon(Icons.movie_outlined, size: 18),
          label: const Text('Launch Player POC Test Harness (Phase 2)'),
        ),
      ],
    );
  }

  Widget _buildStatusBadge(ServerConnectionState state) {
    Color bg;
    Color fg;
    String text;

    switch (state.status) {
      case ConnectionStatus.connected:
        bg = AppColors.statusSuccess.withValues(alpha: 0.15);
        fg = AppColors.statusSuccess;
        text = 'Connected';
        break;
      case ConnectionStatus.failed:
        bg = AppColors.statusError.withValues(alpha: 0.15);
        fg = AppColors.statusError;
        text = 'Unreachable';
        break;
      case ConnectionStatus.testing:
        bg = AppColors.statusWarning.withValues(alpha: 0.15);
        fg = AppColors.statusWarning;
        text = 'Pinging...';
        break;
      case ConnectionStatus.untested:
        bg = AppColors.textMuted.withValues(alpha: 0.15);
        fg = AppColors.textSecondary;
        text = 'Not tested';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg.withValues(alpha: 0.3)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fg,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: AppTypography.bodyMedium),
        Text(
          value,
          style: AppTypography.bodyMedium.copyWith(
            color: valueColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
