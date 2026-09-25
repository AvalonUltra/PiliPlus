import 'package:flutter/foundation.dart' show ValueChanged;
import 'package:flutter_volume_controller/flutter_volume_controller.dart';

/// 全局唯一的系统音量监听。
///
/// flutter_volume_controller 在 iOS 上取消监听时会 `setActive(false)`,
/// 把正在出声的播放器静音(画面继续、声音没了);插件本身也只允许一个监听,
/// 新监听会先取消旧的。播放器视图在切换画质/重建后端时会反复销毁重建,
/// 因此原生监听只注册一次、永不取消,各视图在 Dart 侧挂回调。
abstract final class VolumeListener {
  static final Set<ValueChanged<double>> _callbacks = {};
  static bool _registered = false;

  static void add(ValueChanged<double> callback) {
    _callbacks.add(callback);
    if (!_registered) {
      _registered = true;
      try {
        FlutterVolumeController.addListener(
          _dispatch,
          // The plugin defaults to ambient and overwrites AVAudioSession.
          // Keep media playback audible regardless of listener/mpv init order.
          category: AudioSessionCategory.playback,
          emitOnStart: false,
        );
      } catch (_) {
        _registered = false;
      }
    }
  }

  static void remove(ValueChanged<double> callback) =>
      _callbacks.remove(callback);

  static void _dispatch(double value) {
    for (final callback in _callbacks.toList()) {
      callback(value);
    }
  }
}
