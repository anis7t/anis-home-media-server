import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

bool get _isInTest => !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

/// The intro's state.
///
/// There is exactly one field, and that is deliberate.
class IntroState {
  const IntroState({this.isPlaying = false});

  /// Whether the sequence is playing.
  final bool isPlaying;

  IntroState copyWith({bool? isPlaying}) {
    return IntroState(isPlaying: isPlaying ?? this.isPlaying);
  }
}

/// Owns the opening sequence's lifecycle.
///
/// ## The intro plays on EVERY LAUNCH, and that is the design
///
/// The canonical specification says so: the web's intro plays once per browser
/// session, and the Android client's plays on **every launch**
/// (`docs/OPENING_SEQUENCE.md` Part I section 10).
///
/// That used to be **accidental**. This controller carried a `hasSeenIntro`
/// flag, which `markFinished()` set and which nothing ever read and nothing
/// ever persisted - so the behaviour was a property of the implementation
/// rather than a decision, and the flag was a lie. It is gone. The behaviour
/// is now stated, and the test environment's `isPlaying: false` is the only
/// exception.
///
/// There is deliberately **no Replay path** (decision D4): no Replay action in
/// the Settings screen (removed in Slice 11.1a), and no way to bring the
/// sequence back once it has run.
class IntroController extends Notifier<IntroState> {
  @override
  IntroState build() {
    return IntroState(isPlaying: !_isInTest);
  }

  /// The sequence has finished. The overlay is removed and the app takes over.
  void markFinished() {
    state = state.copyWith(isPlaying: false);
  }
}

final introControllerProvider =
    NotifierProvider<IntroController, IntroState>(() => IntroController());
