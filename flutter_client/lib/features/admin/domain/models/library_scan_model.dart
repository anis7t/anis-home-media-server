import 'package:flutter/foundation.dart';

/// Telemetry report from media scanner.
@immutable
class LibraryScanStatus {
  final String status;
  final bool busy;
  final int filesDiscovered;
  final int unindexedDiscovered;
  final int moviesIndexed;
  final int orphansPruned;
  final int subtitlesAcquired;
  final int errors;

  const LibraryScanStatus({
    required this.status,
    required this.busy,
    required this.filesDiscovered,
    required this.unindexedDiscovered,
    required this.moviesIndexed,
    required this.orphansPruned,
    required this.subtitlesAcquired,
    required this.errors,
  });

  bool get isScanning => busy || status == 'scanning';

  factory LibraryScanStatus.fromJson(Map<String, dynamic> json) {
    return LibraryScanStatus(
      status: (json['status'] as String?) ?? 'idle',
      busy: (json['busy'] as bool?) ?? false,
      filesDiscovered: (json['files_discovered'] as num?)?.toInt() ?? 0,
      unindexedDiscovered:
          (json['unindexed_discovered'] as num?)?.toInt() ?? 0,
      moviesIndexed: (json['movies_indexed'] as num?)?.toInt() ?? 0,
      orphansPruned: (json['orphans_pruned'] as num?)?.toInt() ?? 0,
      subtitlesAcquired: (json['subtitles_acquired'] as num?)?.toInt() ?? 0,
      errors: (json['errors'] as num?)?.toInt() ?? 0,
    );
  }
}
