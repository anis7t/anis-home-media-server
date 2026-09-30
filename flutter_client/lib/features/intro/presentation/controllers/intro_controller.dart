import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

bool get _isInTest => !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

class IntroState {
  final bool hasSeenIntro;
  final bool isPlaying;

  const IntroState({
    this.hasSeenIntro = false,
    this.isPlaying = true,
  });

  IntroState copyWith({
    bool? hasSeenIntro,
    bool? isPlaying,
  }) {
    return IntroState(
      hasSeenIntro: hasSeenIntro ?? this.hasSeenIntro,
      isPlaying: isPlaying ?? this.isPlaying,
    );
  }
}

class IntroController extends Notifier<IntroState> {
  @override
  IntroState build() {
    final autoPlay = !_isInTest;
    return IntroState(
      hasSeenIntro: _isInTest,
      isPlaying: autoPlay,
    );
  }

  void markFinished() {
    state = state.copyWith(hasSeenIntro: true, isPlaying: false);
  }

  void replay() {
    state = state.copyWith(isPlaying: true);
  }
}

final introControllerProvider =
    NotifierProvider<IntroController, IntroState>(() => IntroController());
