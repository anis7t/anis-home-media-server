import 'package:flutter/material.dart';

/// Obsidian dark color palette matching Anis' Home Media Server brand identity.
class AppColors {
  AppColors._();

  // Background & Surfaces
  static const Color background = Color(0xFF090B10);
  static const Color surface = Color(0xFF141822);
  static const Color surfaceElevated = Color(0xFF1C2230);
  static const Color surfaceHighlight = Color(0xFF252D3D);

  // Brand Accents
  static const Color brandRed = Color(0xFFE50914);
  static const Color brandRedLight = Color(0xFFFF334B);
  static const Color brandRedGlow = Color(0x33E50914);

  // Borders & Dividers
  static const Color borderSubtle = Color(0x14FFFFFF); // 8% white
  static const Color borderMedium = Color(0x24FFFFFF); // 14% white
  static const Color borderFocus = Color(0x80E50914); // 50% brand red

  // Typography
  static const Color textPrimary = Color(0xFFF0F2F5);
  static const Color textSecondary = Color(0xFF8A93A5);
  static const Color textMuted = Color(0xFF555E70);
  static const Color textOnBrand = Colors.white;

  // Status Indicators
  static const Color statusSuccess = Color(0xFF22C55E);
  static const Color statusWarning = Color(0xFFF59E0B);
  static const Color statusError = Color(0xFFEF4444);
  static const Color statusInfo = Color(0xFF3B82F6);
}
