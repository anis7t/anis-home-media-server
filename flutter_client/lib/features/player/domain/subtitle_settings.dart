import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Subtitle font size presets matching the web/Android app.
enum SubtitleFontSize {
  small(24.0, '75% (Small)'),
  normal(32.0, '100% (Normal)'),
  medium(40.0, '125% (Medium)'),
  large(48.0, '150% (Large)'),
  huge(64.0, '200% (Huge)');

  final double size;
  final String label;
  const SubtitleFontSize(this.size, this.label);
}

/// Subtitle vertical position presets matching the web/Android app.
enum SubtitleVerticalPosition {
  lowered(EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 20.0), 'Lowered Bottom (Default)'),
  bottom(EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 48.0), 'Bottom'),
  raised(EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 80.0), 'Raised Bottom'),
  middle(EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 0.0), 'Center / Middle'),
  top(EdgeInsets.fromLTRB(16.0, 32.0, 16.0, 0.0), 'Top');

  final EdgeInsets padding;
  final String label;
  const SubtitleVerticalPosition(this.padding, this.label);
}

/// Subtitle horizontal alignment presets.
enum SubtitleHorizontalAlign {
  center(TextAlign.center, 'Center (Default)'),
  left(TextAlign.left, 'Left (20%)'),
  right(TextAlign.right, 'Right (80%)');

  final TextAlign align;
  final String label;
  const SubtitleHorizontalAlign(this.align, this.label);
}

/// Immutable subtitle configuration state.
class SubtitleSettings {
  final SubtitleFontSize fontSize;
  final SubtitleVerticalPosition verticalPosition;
  final SubtitleHorizontalAlign horizontalAlign;

  const SubtitleSettings({
    this.fontSize = SubtitleFontSize.normal,
    this.verticalPosition = SubtitleVerticalPosition.lowered,
    this.horizontalAlign = SubtitleHorizontalAlign.center,
  });

  SubtitleSettings copyWith({
    SubtitleFontSize? fontSize,
    SubtitleVerticalPosition? verticalPosition,
    SubtitleHorizontalAlign? horizontalAlign,
  }) {
    return SubtitleSettings(
      fontSize: fontSize ?? this.fontSize,
      verticalPosition: verticalPosition ?? this.verticalPosition,
      horizontalAlign: horizontalAlign ?? this.horizontalAlign,
    );
  }

  /// Converts this configuration to media_kit_video's [SubtitleViewConfiguration].
  SubtitleViewConfiguration toConfiguration() {
    return SubtitleViewConfiguration(
      style: TextStyle(
        height: 1.4,
        fontSize: fontSize.size,
        letterSpacing: 0.0,
        wordSpacing: 0.0,
        color: const Color(0xFFFFFFFF),
        fontWeight: FontWeight.normal,
        backgroundColor: const Color(0xAA000000),
      ),
      textAlign: horizontalAlign.align,
      padding: verticalPosition.padding,
    );
  }
}

/// Notifier managing persisted subtitle settings across sessions.
class SubtitleSettingsNotifier extends Notifier<SubtitleSettings> {
  static const _keySize = 'subtitle_font_size';
  static const _keyPos = 'subtitle_vertical_pos';
  static const _keyAlign = 'subtitle_horizontal_align';

  @override
  SubtitleSettings build() {
    _load();
    return const SubtitleSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sizeName = prefs.getString(_keySize);
      final posName = prefs.getString(_keyPos);
      final alignName = prefs.getString(_keyAlign);

      final size = SubtitleFontSize.values.firstWhere(
        (e) => e.name == sizeName,
        orElse: () => SubtitleFontSize.normal,
      );
      final pos = SubtitleVerticalPosition.values.firstWhere(
        (e) => e.name == posName,
        orElse: () => SubtitleVerticalPosition.lowered,
      );
      final align = SubtitleHorizontalAlign.values.firstWhere(
        (e) => e.name == alignName,
        orElse: () => SubtitleHorizontalAlign.center,
      );

      state = SubtitleSettings(
        fontSize: size,
        verticalPosition: pos,
        horizontalAlign: align,
      );
    } catch (_) {}
  }

  Future<void> setFontSize(SubtitleFontSize size) async {
    state = state.copyWith(fontSize: size);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keySize, size.name);
    } catch (_) {}
  }

  Future<void> setVerticalPosition(SubtitleVerticalPosition pos) async {
    state = state.copyWith(verticalPosition: pos);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyPos, pos.name);
    } catch (_) {}
  }

  Future<void> setHorizontalAlign(SubtitleHorizontalAlign align) async {
    state = state.copyWith(horizontalAlign: align);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyAlign, align.name);
    } catch (_) {}
  }
}

/// Global provider for subtitle size and position settings.
final subtitleSettingsProvider =
    NotifierProvider<SubtitleSettingsNotifier, SubtitleSettings>(
  SubtitleSettingsNotifier.new,
);
