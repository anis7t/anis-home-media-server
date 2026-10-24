import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../providers/admin_providers.dart';

class ChangePinSheet extends ConsumerStatefulWidget {
  const ChangePinSheet({super.key});

  @override
  ConsumerState<ChangePinSheet> createState() => _ChangePinSheetState();
}

class _ChangePinSheetState extends ConsumerState<ChangePinSheet> {
  final _currentPinController = TextEditingController();
  final _newPinController = TextEditingController();
  final _confirmPinController = TextEditingController();

  String? _errorMessage;
  bool _isLoading = false;

  @override
  void dispose() {
    _currentPinController.dispose();
    _newPinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    final current = _currentPinController.text.trim();
    final next = _newPinController.text.trim();
    final confirm = _confirmPinController.text.trim();

    if (current.isEmpty || next.isEmpty || confirm.isEmpty) {
      setState(() => _errorMessage = 'Please complete all PIN fields');
      return;
    }
    if (next.length < 4) {
      setState(() => _errorMessage = 'New PIN must be at least 4 digits');
      return;
    }
    if (next != confirm) {
      setState(() => _errorMessage = 'New PIN and confirmation do not match');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final success = await ref
        .read(libraryMaintenanceControllerProvider.notifier)
        .changeAdminPin(current, next);

    if (!mounted) return;

    if (success) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Admin PIN successfully updated')),
      );
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to update PIN. Please verify your current PIN.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        24,
        20,
        24,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: AppColors.borderMedium)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.borderMedium,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.brandRed.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.brandRed.withValues(alpha: 0.3)),
                ),
                child: const Center(
                  child: Icon(Icons.password_rounded, color: AppColors.brandRed, size: 20),
                ),
              ),
              const SizedBox(width: 12),
              Text('Change Admin PIN', style: AppTypography.titleLarge),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Updating the PIN will require all viewers to use the new PIN for administrative actions.',
            style: AppTypography.labelSmall.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 18),
          _buildPinField(
            controller: _currentPinController,
            label: 'Current PIN',
            hint: 'Enter existing PIN',
          ),
          const SizedBox(height: 12),
          _buildPinField(
            controller: _newPinController,
            label: 'New PIN',
            hint: 'Enter 4+ digit PIN',
          ),
          const SizedBox(height: 12),
          _buildPinField(
            controller: _confirmPinController,
            label: 'Confirm New PIN',
            hint: 'Re-enter new PIN',
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              style: AppTypography.labelSmall.copyWith(color: AppColors.brandRed),
            ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.brandRed,
                foregroundColor: AppColors.textOnBrand,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _isLoading ? null : _handleSubmit,
              child: _isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textOnBrand),
                    )
                  : const Text(
                      'Update PIN',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPinField({
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      obscureText: true,
      style: AppTypography.bodyMedium,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: AppColors.textSecondary),
        hintText: hint,
        hintStyle: TextStyle(color: AppColors.textMuted),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.borderSubtle),
        ),
      ),
    );
  }
}
