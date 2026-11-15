part of 'package:PiliPlus/pages/live_room/controller.dart';

mixin _LiveDMStreamMixin
    on
        GetxController,
        _LiveDMTrimMixin,
        _LiveSCMixin,
        _LiveDMMixin,
        _LiveBlockMixin {
  LiveMessageStream? _msgStream;
  LiveMessageStream? get msgStream => _msgStream;

  late final headerKey = GlobalKey<TimeBatteryMixin>();
  late final RxString title = ''.obs;
  late final RxnString onlineCount = RxnString();
  late final RxnString watchedShow = RxnString();
  Widget get watchedWidget => Obx(() {
    if (watchedShow.value case final watchedShow?) {
      return Text(
        watchedShow,
        style: const TextStyle(
          fontSize: 12,
          color: Colors.white,
        ),
      );
    }
    return const SizedBox.shrink();
  });

  void startLiveMsgStream() {
    if (messages.isEmpty) {
      prefetchDM();
      if (showSuperChat) getSuperChatMsg();
    }
    // 仅当连接确实还活着才跳过:已断开的流对象不能算数,否则永不重连
    if (_msgStream case final stream?) {
      if (stream.isActive) {
        return;
      }
      stream.close();
      _msgStream = null;
    }
    if (dmInfo != null) {
      initDm(dmInfo!);
      return;
    }
    LiveHttp.liveRoomGetDanmakuToken(roomId: roomId).then((res) {
      if (res case Success(:final response)) {
        initDm(dmInfo = response);
      }
    });
  }

  Future<void> initDm(LiveDmInfoData info) async {
    if (info.hostList.isEmpty) return;
    _msgStream =
        LiveMessageStream(
            streamToken: info.token,
            roomId: roomId,
            uid: Accounts.heartbeat.mid,
            servers: info.hostList
                .map((host) => 'wss://${host.host}:${host.wssPort}/sub')
                .toList(),
          )
          ..addEventListener(_danmakuListener)
          ..onDisconnect = _onMsgStreamDisconnect
          ..init();
  }

  Timer? _msgReconnectTimer;

  /// 弹幕长连接断开后自动重连。此前断线只是把连接清理掉,而 [_msgStream]
  /// 引用仍非空,导致 [startLiveMsgStream] 认为“流还在”而直接返回 —— 弹幕与
  /// 聊天列表就此永久停住,切走再回来也恢复不了。
  void _onMsgStreamDisconnect() {
    _msgStream = null;
    _msgReconnectTimer?.cancel();
    _msgReconnectTimer = Timer(const Duration(seconds: 2), () {
      if (isClosed || _msgStream != null) return;
      // token 可能已失效,丢弃缓存让 startLiveMsgStream 重新申请
      dmInfo = null;
      startLiveMsgStream();
    });
  }

  void addDm(dynamic msg, [DanmakuContentItem<DanmakuExtra>? item]) {
    _trimDm();

    if (plPlayerController.showDanmaku) {
      if (item != null && plPlayerController.enableShowLiveDanmaku.value) {
        // 单条弹幕渲染失败(字形光栅化等)不能中断整条消息流:上游
        // _danmakuListener 用 catch 吞异常,一旦抛出,这批数据包的
        // 后续消息连同下面的聊天列表都会被静默丢弃,表现为弹幕突然
        // 不再滚动且无法自行恢复。
        try {
          danmakuController?.addDanmaku(item);
        } catch (e, s) {
          if (kDebugMode) {
            debugPrint('addDanmaku failed: $e\n$s');
          }
        }
      }
      if (autoScroll && !disableAutoScroll.value) {
        messages.add(msg);
        scrollToBottom();
        return;
      }
    }

    messages.addOnly(msg);
  }

  @pragma('vm:notify-debugger-on-exception')
  void _danmakuListener(dynamic obj) {
    try {
      // logger.i(' 原始弹幕消息 ======> ${jsonEncode(obj)}');
      switch (obj['cmd']) {
        case 'DANMU_MSG':
          final info = obj['info'];
          final first = info[0];
          final content = first[15];
          final user = content['user'];
          // final midHash = first[7];
          final uid = user['uid'] as int;
          final msg = info[1];
          if (isBlocked(msg, uid)) {
            return;
          }
          final Map<String, dynamic> extra = jsonDecode(content['extra']);
          final name = user['base']['name'];
          BaseEmote? uemote;
          if (first[13] case Map<String, dynamic> map) {
            uemote = BaseEmote.fromJson(map);
          }
          final checkInfo = info[9];
          final liveExtra = LiveDanmaku(
            id: extra['id_str'],
            mid: uid,
            dmType: extra['dm_type'],
            ts: checkInfo['ts'],
            ct: checkInfo['ct'],
          );
          Owner? reply;
          final replyMid = extra['reply_mid'];
          if (replyMid != null && replyMid != 0) {
            reply = Owner(
              mid: replyMid,
              name: extra['reply_uname'],
            );
          }
          addDm(
            DanmakuMsg(
              name: name,
              text: msg,
              emots: (extra['emots'] as Map<String, dynamic>?)?.map(
                (k, v) => MapEntry(k, BaseEmote.fromJson(v)),
              ),
              uemote: uemote,
              extra: liveExtra,
              reply: reply,
              medalInfo: GlobalData().showMedal
                  ? UinfoMedal.lightMedal(user['medal'])
                  : null,
            ),
            DanmakuContentItem(
              msg,
              color: DanmakuOptions.blockColorful
                  ? Colors.white
                  : DmUtils.decimalToColor(extra['color']),
              type: DmUtils.getPosition(extra['mode']),
              // extra['send_from_me'] is invalid
              selfSend: isMainLogin && uid == mid,
              extra: liveExtra,
            ),
          );
          break;
        case 'SUPER_CHAT_MESSAGE' when showSuperChat:
          final item = SuperChatItem.fromJson(obj['data'], roomId);
          superChatMsg.insert(0, item);
          addDm(item);
          if (!enableFSSC) return;
          if (Platform.isAndroid && AndroidHelper.isPipMode) return;
          if (plPlayerController.showDanmaku &&
              (isFullScreen || plPlayerController.isDesktopPip)) {
            fsSC.value = item.copyWith(
              endTime: math.min(
                item.endTime,
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 10,
              ),
            );
          }
          break;
        // case 'SUPER_CHAT_MESSAGE_DELETE' when showSuperChat:
        //   if (obj['roomid'] == roomId) {
        //     final ids = obj['data']?['ids'] as List?;
        //     if (ids != null && ids.isNotEmpty) {
        //       if (superChatType == .valid) {
        //         superChatMsg.removeWhere((e) => ids.contains(e.id));
        //       } else {
        //         bool? refresh;
        //         for (final id in ids) {
        //           if (superChatMsg.firstWhereOrNull((e) => e.id == id)
        //               case final item?) {
        //             item.deleted = true;
        //             refresh ??= true;
        //           }
        //         }
        //         if (refresh ?? false) {
        //           superChatMsg.refresh();
        //         }
        //       }
        //     }
        //   }
        case 'WATCHED_CHANGE':
          watchedShow.value = obj['data']['text_large'];
          break;
        case 'ONLINE_RANK_COUNT':
          onlineCount.value = NumUtils.numFormat(obj['data']['count']);
          break;
        case 'ROOM_CHANGE':
          title.value = obj['data']['title'];
          break;
        case 'MESSAGEBOX_USER_MEDAL_CHANGE':
          if (kDebugMode) {
            debugPrint(Utils.jsonEncoder.convert(obj));
          }
          if (isMainLogin) {
            final json = obj['data']['uinfo_medal'];
            final updateRuid = json['ruid'];
            final medalRuid = medal.rawValue?.ruid;
            if (medalRuid == updateRuid ||
                (medalRuid == null && updateRuid == ruid)) {
              medal.value = .fromJson(json);
            }
          }
          break;
      }
    } catch (e, s) {
      if (kDebugMode) {
        Utils.reportError(e, s);
      }
    }
  }

  void stopLiveMsgStream() {
    _msgReconnectTimer?.cancel();
    _msgReconnectTimer = null;
    _msgStream?.close();
    _msgStream = null;
  }
}
