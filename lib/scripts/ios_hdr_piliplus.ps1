$ErrorActionPreference = "Stop"

function Replace-Checked {
    param(
        [string]$Path,
        [string]$Old,
        [string]$New,
        [string]$Marker,
        [string]$Label
    )

    $text = Get-Content -Path $Path -Raw
    if ($text.Contains($Marker)) {
        Write-Host "$Label already applied"
        return
    }

    $index = $text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($index -lt 0) {
        throw "Unable to apply $Label: expected block not found in $Path"
    }

    $updated = $text.Substring(0, $index) + $New + $text.Substring($index + $Old.Length)
    Set-Content -Path $Path -Value $updated -NoNewline -Encoding utf8
    Write-Host "$Label applied"
}

Replace-Checked `
    -Path "lib/pages/setting/models/play_settings.dart" `
    -Label "iOS HDR settings entry" `
    -Marker "SettingBoxKey.iosHdrPlayback" `
    -Old @'
  const SwitchModel(
    title: '自动播放',
    subtitle: '进入详情页自动播放',
    leading: Icon(Icons.motion_photos_auto_outlined),
    setKey: SettingBoxKey.autoPlayEnable,
    defaultVal: false,
  ),
  const SwitchModel(
    title: '全屏显示锁定按钮',
'@ `
    -New @'
  const SwitchModel(
    title: '自动播放',
    subtitle: '进入详情页自动播放',
    leading: Icon(Icons.motion_photos_auto_outlined),
    setKey: SettingBoxKey.autoPlayEnable,
    defaultVal: false,
  ),
  if (Platform.isIOS)
    const SwitchModel(
      title: '原生 HDR/杜比播放',
      subtitle: '播放 HDR 真彩、杜比视界、HDR Vivid 画质时使用 iOS AVPlayer 输出；关闭后回退 media_kit',
      leading: Icon(Icons.hdr_on_outlined),
      setKey: SettingBoxKey.iosHdrPlayback,
      defaultVal: true,
    ),
  const SwitchModel(
    title: '全屏显示锁定按钮',
'@

Replace-Checked `
    -Path "lib/pages/video/controller.dart" `
    -Label "pass video quality to player" `
    -Marker "qualityCode: firstVideo.quality.code" `
    -Old @'
      duration: data.timeLength == null
          ? null
          : Duration(milliseconds: data.timeLength!),
      isVertical: isVertical.value,
'@ `
    -New @'
      duration: data.timeLength == null
          ? null
          : Duration(milliseconds: data.timeLength!),
      qualityCode: firstVideo.quality.code,
      isVertical: isVertical.value,
'@

$controller = "lib/plugin/pl_player/controller.dart"

Replace-Checked `
    -Path $controller `
    -Label "import iOS HDR backend" `
    -Marker "ios_hdr_playback_backend.dart" `
    -Old @'
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
'@ `
    -New @'
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/models/ios_hdr_playback_backend.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
'@

Replace-Checked `
    -Path $controller `
    -Label "add iOS HDR backend field" `
    -Marker "IosHdrPlaybackBackend? _iosHdrBackend" `
    -Old @'
class PlPlayerController with BlockConfigMixin {
  Player? _videoPlayerController;
  VideoController? _videoController;

  static PlPlayerController? _instance;
'@ `
    -New @'
class PlPlayerController with BlockConfigMixin {
  Player? _videoPlayerController;
  VideoController? _videoController;
  IosHdrPlaybackBackend? _iosHdrBackend;

  static PlPlayerController? _instance;
'@

Replace-Checked `
    -Path $controller `
    -Label "add iOS HDR backend accessors" `
    -Marker "buildVideoView({required Color fill, required VideoFitType fit})" `
    -Old @'
  /// [videoController] instance of Player
  VideoController? get videoController => _videoController;

  bool isMuted = false;
'@ `
    -New @'
  /// [videoController] instance of Player
  VideoController? get videoController => _videoController;

  IosHdrPlaybackBackend? get iosHdrBackend => _iosHdrBackend;

  bool get isIosHdrBackend => _iosHdrBackend != null;

  bool get hasVideoView => _videoController != null || _iosHdrBackend != null;

  Widget? buildVideoView({required Color fill, required VideoFitType fit}) =>
      _iosHdrBackend?.buildView(fill: fill, fit: fit);

  bool isMuted = false;
'@

Replace-Checked `
    -Path $controller `
    -Label "add qualityCode parameter" `
    -Marker "int? qualityCode," `
    -Old @'
    int? width,
    int? height,
    Duration? duration,
    // 方向
'@ `
    -New @'
    int? width,
    int? height,
    Duration? duration,
    int? qualityCode,
    // 方向
'@

Replace-Checked `
    -Path $controller `
    -Label "forward qualityCode to create video controller" `
    -Marker "qualityCode: qualityCode" `
    -Old @'
      // 配置Player 音轨、字幕等等
      await _createVideoController(dataSource, seekTo, volume);
'@ `
    -New @'
      // 配置Player 音轨、字幕等等
      await _createVideoController(
        dataSource,
        seekTo,
        volume,
        qualityCode: qualityCode,
      );
'@

Replace-Checked `
    -Path $controller `
    -Label "add iOS HDR selection helpers" `
    -Marker "_shouldUseIosHdrBackend" `
    -Old @'
    return player;
  }

  Map<String, String>? _buffer;
'@ `
    -New @'
    return player;
  }

  Future<void> _disposeIosHdrBackend() async {
    final backend = _iosHdrBackend;
    _iosHdrBackend = null;
    await backend?.dispose();
  }

  Future<bool> _shouldUseIosHdrBackend(
    DataSource dataSource,
    int? qualityCode,
  ) async {
    if (!Platform.isIOS ||
        isLive ||
        onlyPlayAudio.value ||
        !Pref.iosHdrPlayback ||
        dataSource.videoSource.isEmpty) {
      return false;
    }
    return IosHdrPlaybackBackend.supportsHdr(qualityCode: qualityCode);
  }

  Map<String, String>? _buffer;
'@

Replace-Checked `
    -Path $controller `
    -Label "accept qualityCode in create video controller" `
    -Marker "int? qualityCode,`n  }) async" `
    -Old @'
  Future<void> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume,
  ) async {
'@ `
    -New @'
  Future<void> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume, {
    int? qualityCode,
  }) async {
'@

Replace-Checked `
    -Path $controller `
    -Label "select iOS HDR backend" `
    -Marker "final useIosHdrBackend = await _shouldUseIosHdrBackend" `
    -Old @'
    var player = _videoPlayerController;

    if (player == null) {
'@ `
    -New @'
    var player = _videoPlayerController;

    final useIosHdrBackend = await _shouldUseIosHdrBackend(
      dataSource,
      qualityCode,
    );
    if (!useIosHdrBackend) {
      await _disposeIosHdrBackend();
    }

    if (player == null) {
'@

Replace-Checked `
    -Path $controller `
    -Label "route media_kit to audio during iOS HDR playback" `
    -Marker "onlyPlayAudio.value || useIosHdrBackend" `
    -Old @'
      if (onlyPlayAudio.value) {
'@ `
    -New @'
      if (onlyPlayAudio.value || useIosHdrBackend) {
'@

Replace-Checked `
    -Path $controller `
    -Label "open native iOS HDR player" `
    -Marker "await backend.open(" `
    -Old @'
    await player.open(
      Media(
        video,
        start: seekTo,
        extras: extras.isEmpty ? null : extras,
      ),
      play: false,
    );
  }
'@ `
    -New @'
    await player.open(
      Media(
        video,
        start: seekTo,
        extras: extras.isEmpty ? null : extras,
      ),
      play: false,
    );

    if (useIosHdrBackend) {
      await player.setVideoTrack(VideoTrack.no());
      final backend = _iosHdrBackend ??= IosHdrPlaybackBackend();
      await backend.open(
        dataSource,
        start: seekTo,
        headers: {
          'User-Agent': BrowserUa.pc,
          'Referer': HttpString.baseUrl,
        },
        fit: videoFit.value,
        qualityCode: qualityCode,
      );
    } else {
      await player.setVideoTrack(VideoTrack.auto());
    }
  }
'@

Replace-Checked `
    -Path $controller `
    -Label "sync native iOS HDR position" `
    -Marker "_iosHdrBackend?.syncTo(position);" `
    -Old @'
          makeHeartBeat(posInSeconds);
'@ `
    -New @'
          makeHeartBeat(posInSeconds);
          _iosHdrBackend?.syncTo(position);
'@

Replace-Checked `
    -Path $controller `
    -Label "seek native iOS HDR player" `
    -Marker "await _iosHdrBackend?.seek(position);" `
    -Old @'
        await _videoPlayerController?.seek(position);
'@ `
    -New @'
        await _videoPlayerController?.seek(position);
        await _iosHdrBackend?.seek(position);
'@

Replace-Checked `
    -Path $controller `
    -Label "speed native iOS HDR player" `
    -Marker "await _iosHdrBackend?.setPlaybackSpeed(speed);" `
    -Old @'
    await _videoPlayerController?.setRate(speed);
'@ `
    -New @'
    await _videoPlayerController?.setRate(speed);
    await _iosHdrBackend?.setPlaybackSpeed(speed);
'@

Replace-Checked `
    -Path $controller `
    -Label "play native iOS HDR player" `
    -Marker "await iosHdrBackend.play();" `
    -Old @'
    await _videoPlayerController?.play();

    audioSessionHandler?.setActive(true);
'@ `
    -New @'
    await _videoPlayerController?.play();

    final iosHdrBackend = _iosHdrBackend;
    if (iosHdrBackend != null) {
      await iosHdrBackend.syncTo(
        _videoPlayerController?.state.position ?? Duration.zero,
      );
      await iosHdrBackend.play();
    }

    audioSessionHandler?.setActive(true);
'@

Replace-Checked `
    -Path $controller `
    -Label "pause native iOS HDR player" `
    -Marker "await _iosHdrBackend?.pause();" `
    -Old @'
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    await _videoPlayerController?.pause();
'@ `
    -New @'
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    await _iosHdrBackend?.pause();
    await _videoPlayerController?.pause();
'@

Replace-Checked `
    -Path $controller `
    -Label "fit native iOS HDR player on toggle" `
    -Marker "_iosHdrBackend?.setFit(value);" `
    -Old @'
    _prefFit = videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, value.index);
'@ `
    -New @'
    _prefFit = videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, value.index);
    _iosHdrBackend?.setFit(value);
'@

Replace-Checked `
    -Path $controller `
    -Label "fit native iOS HDR player on init" `
    -Marker "_iosHdrBackend?.setFit(videoFit.value);" `
    -Old @'
    } else {
      videoFit.value = _prefFit;
    }
  }
'@ `
    -New @'
    } else {
      videoFit.value = _prefFit;
    }
    _iosHdrBackend?.setFit(videoFit.value);
  }
'@

Replace-Checked `
    -Path $controller `
    -Label "route double-tap through controller wrapper" `
    -Marker "playerStatus.isPlaying ? await pause() : await play();" `
    -Old @'
  Future<void> onDoubleTapCenter() async {
    if (!isLive && isCompleted) {
      await videoPlayerController!.seek(Duration.zero);
      videoPlayerController!.play();
    } else {
      videoPlayerController!.playOrPause();
    }
  }
'@ `
    -New @'
  Future<void> onDoubleTapCenter() async {
    if (!isLive && isCompleted) {
      await seekTo(Duration.zero, isSeek: false);
      await play();
    } else {
      playerStatus.isPlaying ? await pause() : await play();
    }
  }
'@

Replace-Checked `
    -Path $controller `
    -Label "dispose native iOS HDR player" `
    -Marker "_iosHdrBackend = null;`n    _videoPlayerController?.dispose();" `
    -Old @'
    if (kDebugMode) {
      debugPrint('dispose player');
    }
    _videoPlayerController?.dispose();
'@ `
    -New @'
    if (kDebugMode) {
      debugPrint('dispose player');
    }
    _iosHdrBackend?.dispose();
    _iosHdrBackend = null;
    _videoPlayerController?.dispose();
'@

Replace-Checked `
    -Path $controller `
    -Label "disable native iOS HDR player in audio-only mode" `
    -Marker "if (onlyPlayAudio.value) {`n      _iosHdrBackend?.dispose();" `
    -Old @'
  void setOnlyPlayAudio() {
    onlyPlayAudio.value = !onlyPlayAudio.value;
    videoPlayerController?.setVideoTrack(
'@ `
    -New @'
  void setOnlyPlayAudio() {
    onlyPlayAudio.value = !onlyPlayAudio.value;
    if (onlyPlayAudio.value) {
      _iosHdrBackend?.dispose();
      _iosHdrBackend = null;
    }
    videoPlayerController?.setVideoTrack(
'@

Replace-Checked `
    -Path $controller `
    -Label "prefer native iOS HDR screenshot" `
    -Marker "var image = await _iosHdrBackend?.screenshot();" `
    -Old @'
    final image = await videoPlayerController?.screenshot();
'@ `
    -New @'
    var image = await _iosHdrBackend?.screenshot();
    image ??= await videoPlayerController?.screenshot();
'@

$view = "lib/plugin/pl_player/view/view.dart"

Replace-Checked `
    -Path $view `
    -Label "make subtitle video controller nullable" `
    -Marker "VideoController? videoController" `
    -Old @'
  late AnimationController _animationController;
  late VideoController videoController;
'@ `
    -New @'
  late AnimationController _animationController;
  VideoController? videoController;
'@

Replace-Checked `
    -Path $view `
    -Label "read nullable subtitle video controller" `
    -Marker "videoController = plPlayerController.videoController;" `
    -Old @'
    videoController = plPlayerController.videoController!;
'@ `
    -New @'
    videoController = plPlayerController.videoController;
'@

Replace-Checked `
    -Path $view `
    -Label "pause through player controller on background" `
    -Marker "plPlayerController.playerStatus.isPlaying" `
    -Old @'
        if (player != null && player.state.playing) {
'@ `
    -New @'
        if (player != null && plPlayerController.playerStatus.isPlaying) {
'@

Replace-Checked `
    -Path $view `
    -Label "pause iOS HDR backend on background" `
    -Marker "plPlayerController.pause();" `
    -Old @'
          player.pause();
'@ `
    -New @'
          plPlayerController.pause();
'@

Replace-Checked `
    -Path $view `
    -Label "resume iOS HDR backend on foreground" `
    -Marker "plPlayerController.play();" `
    -Old @'
          player?.play();
'@ `
    -New @'
          plPlayerController.play();
'@

Replace-Checked `
    -Path $view `
    -Label "use controller progress fallback" `
    -Marker "plPlayerController.positionInMilliseconds ~/ 1000" `
    -Old @'
      plPlayerController.position.value =
          plPlayerController.videoPlayerController?.state.position.inSeconds ??
          0;
'@ `
    -New @'
      plPlayerController.position.value =
          plPlayerController.positionInMilliseconds ~/ 1000;
'@

Replace-Checked `
    -Path $view `
    -Label "skip native subtitle overlay when no media_kit controller" `
    -Marker "if (!isLive && videoController != null)" `
    -Old @'
        if (!isLive)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !plPlayerController.enableDragSubtitle,
              child: Obx(
                () => SubtitleView(
                  controller: videoController,
'@ `
    -New @'
        if (!isLive && videoController != null)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !plPlayerController.enableDragSubtitle,
              child: Obx(
                () => SubtitleView(
                  controller: videoController!,
'@

Replace-Checked `
    -Path $view `
    -Label "render native iOS HDR video view" `
    -Marker "final nativeVideo = plPlayerController.buildVideoView" `
    -Old @'
                final videoFit = plPlayerController.videoFit.value;
                return Transform.flip(
                  flipX: plPlayerController.flipX.value,
                  flipY: plPlayerController.flipY.value,
                  child: FittedBox(
                    fit: videoFit.boxFit,
                    alignment: widget.alignment,
                    child: SimpleVideo(
                      controller: plPlayerController.videoController!,
                      fill: widget.fill,
                      aspectRatio: videoFit.aspectRatio,
                    ),
                  ),
                );
'@ `
    -New @'
                final videoFit = plPlayerController.videoFit.value;
                final nativeVideo = plPlayerController.buildVideoView(
                  fill: widget.fill,
                  fit: videoFit,
                );
                return Transform.flip(
                  flipX: plPlayerController.flipX.value,
                  flipY: plPlayerController.flipY.value,
                  child: nativeVideo == null
                      ? FittedBox(
                          fit: videoFit.boxFit,
                          alignment: widget.alignment,
                          child: SimpleVideo(
                            controller: plPlayerController.videoController!,
                            fill: widget.fill,
                            aspectRatio: videoFit.aspectRatio,
                          ),
                        )
                      : SizedBox(
                          width: maxWidth,
                          height: maxHeight,
                          child: nativeVideo,
                        ),
                );
'@

Replace-Checked `
    -Path "lib/utils/storage_key.dart" `
    -Label "add iOS HDR setting key" `
    -Marker "iosHdrPlayback = 'iosHdrPlayback'" `
    -Old @'
      angleDegrees = 'angleDegrees',
      liveStream = 'liveStream';
'@ `
    -New @'
      angleDegrees = 'angleDegrees',
      liveStream = 'liveStream',
      iosHdrPlayback = 'iosHdrPlayback';
'@

Replace-Checked `
    -Path "lib/utils/storage_pref.dart" `
    -Label "add iOS HDR setting preference" `
    -Marker "static bool get iosHdrPlayback" `
    -Old @'
  static String get autosync => _setting.get(
    SettingBoxKey.autosync,
    defaultValue: Platform.isAndroid ? '30' : '0',
  );

  static CDNService get defaultCDNService {
'@ `
    -New @'
  static String get autosync => _setting.get(
    SettingBoxKey.autosync,
    defaultValue: Platform.isAndroid ? '30' : '0',
  );

  static bool get iosHdrPlayback =>
      Platform.isIOS &&
      _setting.get(SettingBoxKey.iosHdrPlayback, defaultValue: true);

  static CDNService get defaultCDNService {
'@
