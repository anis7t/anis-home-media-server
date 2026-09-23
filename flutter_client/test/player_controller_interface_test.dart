import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player_poc/domain/player_controller_interface.dart';

/// A mock implementation of PlayerControllerInterface for testing pure domain logic & contracts
class MockPlayerController implements PlayerControllerInterface {
  Duration _position = Duration.zero;
  Duration _duration = const Duration(minutes: 120);
  PlayerPlaybackState _state = PlayerPlaybackState.idle;
  bool _isBuffering = false;
  double _rate = 1.0;
  double _volume = 100.0;
  PlayerTrackInfo _trackInfo = const PlayerTrackInfo();
  VideoDimensions _dimensions = VideoDimensions.zero;

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _stateController = StreamController<PlayerPlaybackState>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _tracksController = StreamController<PlayerTrackInfo>.broadcast();
  final _dimensionsController = StreamController<VideoDimensions>.broadcast();

  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  PlayerPlaybackState get state => _state;
  @override
  bool get isBuffering => _isBuffering;
  @override
  double get rate => _rate;
  @override
  double get volume => _volume;

  @override
  Stream<Duration> get positionStream => _positionController.stream;
  @override
  Stream<Duration> get durationStream => _durationController.stream;
  @override
  Stream<PlayerPlaybackState> get stateStream => _stateController.stream;
  @override
  Stream<bool> get bufferingStream => _bufferingController.stream;
  @override
  Stream<PlayerTrackInfo> get tracksStream => _tracksController.stream;
  @override
  Stream<VideoDimensions> get dimensionsStream => _dimensionsController.stream;

  @override
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Duration? startPosition,
    String? externalSubtitleUrl,
  }) async {
    _state = PlayerPlaybackState.opening;
    _stateController.add(_state);
    if (startPosition != null) {
      _position = startPosition;
      _positionController.add(_position);
    }
    _state = PlayerPlaybackState.playing;
    _stateController.add(_state);
  }

  @override
  Future<void> play() async {
    _state = PlayerPlaybackState.playing;
    _stateController.add(_state);
  }

  @override
  Future<void> pause() async {
    _state = PlayerPlaybackState.paused;
    _stateController.add(_state);
  }

  @override
  Future<void> seek(Duration target) async {
    _position = target;
    _positionController.add(_position);
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
  }

  @override
  Future<void> setSubtitleTrack(PlayerSubtitleTrack track) async {
    _trackInfo = PlayerTrackInfo(
      subtitleTracks: _trackInfo.subtitleTracks,
      currentSubtitleTrack: track,
    );
    _tracksController.add(_trackInfo);
  }

  @override
  Future<void> stop() async {
    _state = PlayerPlaybackState.idle;
    _stateController.add(_state);
  }

  @override
  Future<void> dispose() async {
    await _positionController.close();
    await _durationController.close();
    await _stateController.close();
    await _bufferingController.close();
    await _tracksController.close();
    await _dimensionsController.close();
  }
}

void main() {
  group('Player Domain Models & Decoupled Contract', () {
    test('VideoDimensions stores width and height properly', () {
      const dim = VideoDimensions(1920, 1080);
      expect(dim.width, 1920);
      expect(dim.height, 1080);
      expect(VideoDimensions.zero.width, 0);
      expect(VideoDimensions.zero.height, 0);
    });

    test('PlayerSubtitleTrack defaults and static factories', () {
      expect(PlayerSubtitleTrack.no.id, 'no');
      expect(PlayerSubtitleTrack.no.title, 'Off');
      expect(PlayerSubtitleTrack.auto.id, 'auto');
      expect(PlayerSubtitleTrack.auto.title, 'Auto');

      const customTrack = PlayerSubtitleTrack(
        id: 'eng_1',
        title: 'English (SDH)',
        language: 'eng',
        isExternal: true,
      );
      expect(customTrack.id, 'eng_1');
      expect(customTrack.title, 'English (SDH)');
      expect(customTrack.language, 'eng');
      expect(customTrack.isExternal, isTrue);
    });

    test('PlayerTrackInfo manages tracks list and active track selection', () {
      const t1 = PlayerSubtitleTrack(id: '1', title: 'English');
      const t2 = PlayerSubtitleTrack(id: '2', title: 'Spanish');
      const info = PlayerTrackInfo(
        subtitleTracks: [PlayerSubtitleTrack.no, t1, t2],
        currentSubtitleTrack: t1,
      );

      expect(info.subtitleTracks.length, 3);
      expect(info.currentSubtitleTrack.id, '1');
    });

    test('MockPlayerController respects PlayerControllerInterface contracts', () async {
      final controller = MockPlayerController();

      expect(controller.state, PlayerPlaybackState.idle);
      expect(controller.position, Duration.zero);

      final states = <PlayerPlaybackState>[];
      final sub = controller.stateStream.listen(states.add);

      await controller.open('http://127.0.0.1:8000/media/test.mp4', startPosition: const Duration(seconds: 45));
      expect(controller.position, const Duration(seconds: 45));

      await controller.pause();
      expect(controller.state, PlayerPlaybackState.paused);

      await controller.seek(const Duration(seconds: 120));
      expect(controller.position, const Duration(seconds: 120));

      await controller.setRate(1.5);
      expect(controller.rate, 1.5);

      await controller.setVolume(85.0);
      expect(controller.volume, 85.0);

      await controller.stop();
      expect(controller.state, PlayerPlaybackState.idle);

      await sub.cancel();
      await controller.dispose();
    });
  });
}
