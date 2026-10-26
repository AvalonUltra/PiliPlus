import 'package:PiliPlus/common/widgets/flutter/text_field/controller.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/fold.pb.dart'
    show FoldMixedCard;
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply, ReplyInfo, SubjectControl, Mode;
import 'package:PiliPlus/grpc/bilibili/pagination.pb.dart';
import 'package:PiliPlus/grpc/reply_fold.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/reply.dart';
import 'package:PiliPlus/models/common/reply/reply_sort_type.dart';
import 'package:PiliPlus/models_new/dynamic/dyn_mention/item.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/pages/common/publish/publish_route.dart';
import 'package:PiliPlus/pages/video/reply_new/view.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/reply_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract class ReplyController<R> extends CommonListController<R, ReplyInfo> {
  ReplyController({int count = -1}) : count = RxInt(count);

  late final RxInt count;

  late final Rx<ReplySortType> sortType;
  late Mode mode;

  final savedReplies = <Object, List<RichTextItem>?>{};

  Int64? upMid;
  Int64? cursorNext;
  SubjectControl? subjectControl;
  FeedPaginationReply? paginationReply;
  late bool hasUpTop = false;

  @override
  bool? get hasFooter => true;

  // comment antifraud
  late final _enableCommAntifraud = Pref.enableCommAntifraud;
  late final _biliSendCommAntifraud = Pref.biliSendCommAntifraud;
  bool get enableCommAntifraud =>
      _enableCommAntifraud || _biliSendCommAntifraud;
  dynamic get sourceId;

  @override
  void onInit() {
    super.onInit();
    final cacheSortType = Pref.replySortType;
    sortType = cacheSortType.obs;
    mode = cacheSortType == .time ? Mode.MAIN_LIST_TIME : Mode.MAIN_LIST_HOT;
  }

  @override
  void checkIsEnd(int length) {
    final count = this.count.value;
    if (count != -1 && length >= count) {
      isEnd = true;
    }
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<R> response) {
    final data = response.response as MainListReply;
    cursorNext = data.cursor.next;
    paginationReply = data.paginationReply;
    count.value = data.subjectControl.count.toInt();
    if (isRefresh) {
      subjectControl = data.subjectControl;
      upMid = data.subjectControl.upMid;
      if (hasUpTop = data.hasUpTop()) {
        data.replies.insert(0, data.upTop);
      }
      if (subjectControl?.title == ReplySortType.select.desc) {
        sortType.value = .select;
      }
    }
    isEnd = data.cursor.isEnd;
    return false;
  }

  @override
  Future<void> onRefresh() {
    cursorNext = null;
    subjectControl = null;
    paginationReply = null;
    return super.onRefresh();
  }

  // ---- 折叠评论(官方 App 的「展开更多评论」),见 ReplyFoldGrpc ----

  /// 请求折叠评论所需的 (oid, type, 楼中楼的 root);null 表示该列表不支持。
  (int, int, int?)? get foldTarget => null;

  FoldMixedCard? _foldCard;
  int _foldGen = 0;
  int? _foldExpandedAnchor;

  /// 0 无折叠评论 · 1 可展开 · 2 展开中 · 3 已展开
  final RxInt foldStatus = 0.obs;
  int foldCount = 0;
  String get foldText {
    final text = _foldCard?.fold.bottomText ?? '';
    return text.isEmpty ? '展开更多评论' : text;
  }

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    final refreshing = isRefresh && !isLoading;
    if (refreshing) _resetFold();
    await super.queryData(isRefresh);
    if (refreshing && loadingState.value is Success) _loadFoldCard();
  }

  void _resetFold() {
    _foldGen++;
    _foldCard = null;
    _foldExpandedAnchor = null;
    foldCount = 0;
    foldStatus.value = 0;
  }

  Future<void> _loadFoldCard() async {
    final target = foldTarget;
    if (target == null) return;
    final gen = _foldGen;
    final (oid, type, root) = target;
    final card = root == null
        ? await ReplyFoldGrpc.mainCard(oid: oid, type: type)
        : await ReplyFoldGrpc.detailCard(oid: oid, type: type, root: root);
    if (card == null || gen != _foldGen) return;
    _foldCard = card;
    foldStatus.value = 1;
    loadingState.refresh();
  }

  /// 折叠入口跟在哪条评论下面(列表下标);-1 表示不显示。
  int foldAnchor(int length) {
    if (foldStatus.value == 0 || length == 0) return -1;
    if (_foldExpandedAnchor case final anchor?) return anchor;
    final rank = _foldCard!.displayRank.toInt() + (hasUpTop ? 1 : 0);
    return (rank - 1).clamp(0, length - 1);
  }

  Future<void> expandFold() async {
    final card = _foldCard;
    final target = foldTarget;
    if (card == null || target == null || foldStatus.value != 1) return;
    final list = loadingState.value.dataOrNull;
    if (list == null) return;
    final gen = _foldGen;
    foldStatus.value = 2;
    final replies = await ReplyFoldGrpc.expand(
      oid: target.$1,
      type: target.$2,
      card: card,
    );
    if (gen != _foldGen) return;
    if (replies == null) {
      foldStatus.value = 1;
      SmartDialog.showToast('折叠评论加载失败');
      return;
    }
    final anchor = foldAnchor(list.length);
    _foldExpandedAnchor = anchor;
    list.insertAll(anchor + 1, replies);
    foldCount = replies.length;
    foldStatus.value = 3;
    loadingState.refresh();
  }

  // 排序搜索评论
  void queryBySort() {
    if (isLoading) return;
    switch (sortType.value) {
      case ReplySortType.time:
        sortType.value = ReplySortType.hot;
        mode = Mode.MAIN_LIST_HOT;
        break;
      case ReplySortType.hot:
        sortType.value = ReplySortType.time;
        mode = Mode.MAIN_LIST_TIME;
        break;
      case ReplySortType.select:
        return;
    }
    feedBack();
    onReload();
  }

  (bool inputDisable, String? hint) get replyHint {
    String? hint;
    bool inputDisable = false;
    try {
      if (subjectControl case final subjectControl?) {
        inputDisable = subjectControl.inputDisable;
        if (subjectControl.hasRootText()) {
          final rootText = subjectControl.rootText;
          if (inputDisable) {
            SmartDialog.showToast(rootText);
          }
          if (rootText.contains('可发') || rootText.contains('可见')) {
            hint = rootText;
          }
        }
      }
    } catch (_) {}
    return (inputDisable, hint);
  }

  void onReply(
    ReplyInfo? replyItem, {
    int? oid,
    int? replyType,
    MentionItem? mentionItem,
  }) {
    if (loadingState.value case Error(:final errMsg, :final code)) {
      if (errMsg != null && (code == 12061 || code == 12002)) {
        SmartDialog.showToast(errMsg);
        return;
      }
    }

    assert(replyItem != null || (oid != null && replyType != null));

    final (bool inputDisable, String? hint) = replyHint;
    if (inputDisable) {
      return;
    }

    final key = oid ?? replyItem!.oid + replyItem.id;
    Get.key.currentState!
        .push(
          PublishRoute(
            pageBuilder: (buildContext, animation, secondaryAnimation) {
              return ReplyPage(
                hint: hint,
                oid: oid ?? replyItem!.oid.toInt(),
                root: oid != null ? 0 : replyItem!.id.toInt(),
                parent: oid != null ? 0 : replyItem!.id.toInt(),
                replyType: replyItem?.type.toInt() ?? replyType!,
                replyItem: replyItem,
                mentionItem: mentionItem,
                items: savedReplies[key],

                /// hd api deprecated
                // canUploadPic: canUploadPic,
                onSave: (reply) {
                  if (reply.isEmpty) {
                    savedReplies.remove(key);
                  } else {
                    savedReplies[key] = reply.toList();
                  }
                },
              );
            },
            settings: RouteSettings(arguments: Get.arguments),
          ),
        )
        .then(
          (replyInfo) {
            if (replyInfo is ReplyInfo) {
              savedReplies.remove(key);
              if (loadingState.value case Success(:final response)) {
                if (response == null) {
                  loadingState.value = Success([replyInfo]);
                } else {
                  if (oid != null) {
                    response.insert(hasUpTop ? 1 : 0, replyInfo);
                  } else {
                    replyItem!
                      ..count += 1
                      ..replies.add(replyInfo);
                  }
                  loadingState.refresh();
                }
              } else {
                loadingState.value = Success([replyInfo]);
              }
              count.value += 1;

              // check reply
              if (enableCommAntifraud) {
                onCheckReply(replyInfo, isManual: false);
              }
            }
          },
        );
  }

  void onRemove(int index, ReplyInfo item, int? subIndex) {
    if (subIndex == null) {
      loadingState.value.data!.removeAt(index);
    } else {
      item
        ..count -= 1
        ..replies.removeAt(subIndex);
    }
    count.value -= 1;
    loadingState.refresh();
  }

  void onCheckReply(ReplyInfo replyInfo, {bool isManual = true}) {
    ReplyUtils.onCheckReply(
      replyInfo: replyInfo,
      biliSendCommAntifraud: _biliSendCommAntifraud,
      sourceId: sourceId,
      isManual: isManual,
    );
  }

  Future<void> onToggleTop(
    ReplyInfo item,
    int index,
    oid,
    int type,
  ) async {
    bool isUpTop = item.replyControl.isUpTop;
    final res = await ReplyHttp.replyTop(
      oid: oid,
      type: type,
      rpid: item.id,
      isUpTop: isUpTop,
    );
    if (res.isSuccess) {
      item.replyControl.isUpTop = !isUpTop;
      if (!isUpTop && index != 0) {
        final list = loadingState.value.data!;
        list
          ..first.replyControl.isUpTop = false
          ..insert(0, list.removeAt(index));
      }
      loadingState.refresh();
      SmartDialog.showToast('${isUpTop ? '取消' : ''}置顶成功');
    } else {
      res.toast();
    }
  }

  @override
  void onClose() {
    savedReplies.clear();
    super.onClose();
  }
}
