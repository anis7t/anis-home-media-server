/// Release and update channels for Anis' Home Media Server.
enum AppChannel {
  production('production', 'Production', 'Stable releases for normal daily use.'),
  developer('developer', 'Developer', 'Latest development builds with active changes.');

  final String id;
  final String displayName;
  final String description;

  const AppChannel(this.id, this.displayName, this.description);

  /// Resolves an [AppChannel] from a string identifier (case-insensitive).
  /// Falls back to [production] if unrecognized.
  static AppChannel fromString(String? value) {
    if (value == null) return AppChannel.production;
    final normalized = value.trim().toLowerCase();
    if (normalized == 'developer' || normalized == 'dev') {
      return AppChannel.developer;
    }
    return AppChannel.production;
  }

  /// Initial default channel determined at compile time via `--dart-define=APP_CHANNEL=...`.
  /// Used solely as the initial default when no persisted user selection exists.
  static AppChannel get compileTimeDefault {
    const defined = String.fromEnvironment('APP_CHANNEL', defaultValue: 'production');
    return fromString(defined);
  }
}
