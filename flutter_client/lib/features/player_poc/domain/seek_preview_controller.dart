import 'dart:async';

/// Callback signature for resolving a thumbnail URL or network fetch for a frame.
typedef PreviewUrlResolver = Future<String> Function(int frameIndex, int sequenceId);

/// State of the seek preview manager.
class SeekPreviewState {
  final int? targetFrameIndex;
  final int? displayedFrameIndex;
  final String? displayedImageUrl;
  final int latestSequenceId;
  final int lastCommittedSequenceId;
  final bool isPendingDebounce;

  const SeekPreviewState({
    this.targetFrameIndex,
    this.displayedFrameIndex,
    this.displayedImageUrl,
    this.latestSequenceId = 0,
    this.lastCommittedSequenceId = 0,
    this.isPendingDebounce = false,
  });

  SeekPreviewState copyWith({
    int? targetFrameIndex,
    int? displayedFrameIndex,
    String? displayedImageUrl,
    int? latestSequenceId,
    int? lastCommittedSequenceId,
    bool? isPendingDebounce,
  }) {
    return SeekPreviewState(
      targetFrameIndex: targetFrameIndex ?? this.targetFrameIndex,
      displayedFrameIndex: displayedFrameIndex ?? this.displayedFrameIndex,
      displayedImageUrl: displayedImageUrl ?? this.displayedImageUrl,
      latestSequenceId: latestSequenceId ?? this.latestSequenceId,
      lastCommittedSequenceId:
          lastCommittedSequenceId ?? this.lastCommittedSequenceId,
      isPendingDebounce: isPendingDebounce ?? this.isPendingDebounce,
    );
  }
}

/// Controller managing seek-preview frame requests, UI debouncing, and stale-response suppression.
///
/// Designed to operate completely independently of video playback state.
class SeekPreviewController {
  final Duration debounceDuration;
  final PreviewUrlResolver? urlResolver;
  final void Function(SeekPreviewState state)? onStateChanged;

  Timer? _debounceTimer;
  int _sequenceCounter = 0;
  int _lastCommittedSequence = 0;

  SeekPreviewState _state = const SeekPreviewState();
  SeekPreviewState get state => _state;

  SeekPreviewController({
    this.debounceDuration = const Duration(milliseconds: 80),
    this.urlResolver,
    this.onStateChanged,
  });

  /// Request a frame thumbnail for [frameIndex].
  ///
  /// Cancels any pending debounce timer and increments the request sequence counter.
  void requestFrame(int frameIndex) {
    _debounceTimer?.cancel();
    _sequenceCounter++;
    final currentSeq = _sequenceCounter;

    _state = _state.copyWith(
      targetFrameIndex: frameIndex,
      latestSequenceId: currentSeq,
      isPendingDebounce: true,
    );
    onStateChanged?.call(_state);

    _debounceTimer = Timer(debounceDuration, () async {
      _state = _state.copyWith(isPendingDebounce: false);
      onStateChanged?.call(_state);

      if (urlResolver != null) {
        try {
          final url = await urlResolver!(frameIndex, currentSeq);
          commitPreview(
            sequenceId: currentSeq,
            frameIndex: frameIndex,
            imageUrl: url,
          );
        } catch (_) {
          // Network errors do not overwrite state
        }
      }
    });
  }

  /// Commits a resolved preview image to the state.
  ///
  /// Rejects stale or out-of-order responses where [sequenceId] < [_lastCommittedSequence].
  bool commitPreview({
    required int sequenceId,
    required int frameIndex,
    required String imageUrl,
  }) {
    // Stale response rejection: an older request cannot overwrite a newer committed preview
    if (sequenceId < _lastCommittedSequence) {
      return false;
    }

    _lastCommittedSequence = sequenceId;
    _state = _state.copyWith(
      displayedFrameIndex: frameIndex,
      displayedImageUrl: imageUrl,
      lastCommittedSequenceId: sequenceId,
    );
    onStateChanged?.call(_state);
    return true;
  }

  void cancelPending() {
    _debounceTimer?.cancel();
    if (_state.isPendingDebounce) {
      _state = _state.copyWith(isPendingDebounce: false);
      onStateChanged?.call(_state);
    }
  }

  void dispose() {
    _debounceTimer?.cancel();
  }
}
