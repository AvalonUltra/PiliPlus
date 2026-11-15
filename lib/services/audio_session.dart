import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:audio_session/audio_session.dart';

class AudioSessionHandler {
  late AudioSession _session;
  bool _shouldResume = false;

  Future<void> _pending = Future.value();
  bool? _targetActive;

  /// 串行执行,且只落地最后一次请求的状态。
  /// 插件在后台并发队列里调用 AVAudioSession,不排队的话先发出的停用
  /// 可能晚于后发出的激活生效,把刚开始播放的声音掐掉。
  Future<void> setActive(bool active) {
    _targetActive = active;
    return _pending = _pending.then((_) async {
      if (_targetActive != active) return;
      try {
        await _session.setActive(active);
      } catch (_) {}
    });
  }

  AudioSessionHandler() {
    initSession();
  }

  Future<void> initSession() async {
    _session = await AudioSession.instance;
    _session.configure(const AudioSessionConfiguration.music());

    _session.interruptionEventStream.listen(_onInterrupted);

    // 耳机拔出暂停
    _session.becomingNoisyEventStream.listen((_) {
      videoPlayerServiceHandler?.onPause?.call() ??
          PlPlayerController.pauseIfExists();
    });
  }

  void _onInterrupted(AudioInterruptionEvent event) {
    if (event.begin) {
      final player = PlPlayerController.instance;
      switch (event.type) {
        case .duck:
          if (player != null && player.playerStatus.isPlaying) {
            player.setVolume(player.volume.value * 0.5, showIndicator: false);
          }
        case .pause:
        case .unknown:
          final isAudioPlaying = videoPlayerServiceHandler?.isPlaying;
          if (isAudioPlaying != null) {
            if (isAudioPlaying()) {
              _shouldResume = true;
              videoPlayerServiceHandler?.onPause?.call();
            }
          } else if (player != null && player.playerStatus.isPlaying) {
            _shouldResume = true;
            player.pause(isInterrupt: true);
          }
      }
    } else {
      switch (event.type) {
        case .duck:
          final player = PlPlayerController.instance;
          player?.setVolume(player.volume.value * 2, showIndicator: false);
        case .pause:
          if (_shouldResume) {
            _shouldResume = false;
            videoPlayerServiceHandler?.onPlay?.call() ??
                PlPlayerController.instance?.play();
          }
        case .unknown:
      }
    }
  }
}
