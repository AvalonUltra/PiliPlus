import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' hide Uint8List;

class IosHdrPlaybackBackend {
  IosHdrPlaybackBackend();

  static const MethodChannel _channel = MethodChannel('PiliPlus/IosHdrPlayer');
  static const String _viewType = 'com.example.piliplus/ios_hdr_player_view';

  int? _sessionId;
  DateTime _lastSync = DateTime.fromMillisecondsSinceEpoch(0);

  int? get sessionId => _sessionId;

  Future<void> open(
    DataSource dataSource, {
    Duration? start,
    Map<String, String>? headers,
    VideoFitType fit = VideoFitType.contain,
    int? qualityCode,
  }) async {
    if (!Platform.isIOS) return;
    final id = _sessionId ?? await _channel.invokeMethod<int>('create');
    if (id == null) {
      throw StateError('failed to create iOS HDR player session');
    }
    _sessionId = id;
    await _channel.invokeMethod<void>('open', {
      'sessionId': id,
      'videoUrl': dataSource.videoSource,
      'isFileSource': dataSource is FileSource,
      'startMs': start?.inMilliseconds ?? 0,
      'headers': headers ?? const <String, String>{},
      'fitMode': _fitModeName(fit),
      'qualityCode': qualityCode,
    });
  }

  Future<void> play() => _invoke('play');

  Future<void> pause() => _invoke('pause');

  Future<void> seek(Duration position) => _invoke(
    'seekTo',
    {'positionMs': position.inMilliseconds},
  );

  Future<void> setPlaybackSpeed(double speed) => _invoke(
    'setPlaybackSpeed',
    {'speed': speed},
  );

  Future<void> setFit(VideoFitType fit) => _invoke(
    'setFitMode',
    {'fitMode': _fitModeName(fit)},
  );

  Future<void> syncTo(Duration position) {
    final now = DateTime.now();
    if (now.difference(_lastSync) < const Duration(milliseconds: 700)) {
      return Future.value();
    }
    _lastSync = now;
    return _invoke('syncTo', {'positionMs': position.inMilliseconds});
  }

  Future<ui.Image?> screenshot() async {
    final id = _sessionId;
    if (id == null) return null;
    final bytes = await _channel.invokeMethod<Uint8List>('screenshot', {
      'sessionId': id,
    });
    if (bytes == null || bytes.isEmpty) return null;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  Widget buildView({required Color fill, required VideoFitType fit}) {
    final id = _sessionId;
    if (id == null || !Platform.isIOS) return ColoredBox(color: fill);
    return UiKitView(
      viewType: _viewType,
      layoutDirection: TextDirection.ltr,
      creationParams: {'sessionId': id},
      creationParamsCodec: const StandardMessageCodec(),
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
    );
  }

  Future<void> dispose() async {
    final id = _sessionId;
    _sessionId = null;
    if (id != null) {
      await _channel.invokeMethod<void>('dispose', {'sessionId': id});
    }
  }

  Future<void> _invoke(String method, [Map<String, Object?>? args]) {
    final id = _sessionId;
    if (id == null) return Future.value();
    return _channel.invokeMethod<void>(method, {'sessionId': id, ...?args});
  }

  static Future<bool> supportsHdr({int? qualityCode}) async {
    if (!Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('supportsHdr', {
            'qualityCode': qualityCode,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static String _fitModeName(VideoFitType fit) => switch (fit) {
    VideoFitType.fill => 'fill',
    VideoFitType.cover => 'cover',
    VideoFitType.fitWidth => 'fitWidth',
    VideoFitType.fitHeight => 'fitHeight',
    _ => 'contain',
  };
}
