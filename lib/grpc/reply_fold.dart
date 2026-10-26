import 'dart:convert';
import 'dart:typed_data';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/fold.pb.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/device.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/locale.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/network.pb.dart' as network;
import 'package:PiliPlus/grpc/bilibili/pagination.pb.dart';
import 'package:PiliPlus/grpc/grpc_req.dart';
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/grpc/url.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart' show GeneratedMessage;

/// 折叠评论(官方 App 里的「展开更多评论」)。
///
/// 服务端只向 7.80 及以上版本的手机客户端下发折叠卡片(MixedCard.fold),
/// 卡片里的分页令牌编码了被折叠评论的 rpid,FoldList 只认这个令牌。
/// PiliPlus 平时以 HD 客户端身份请求,收不到卡片,所以这里另以新版手机
/// 客户端身份、不带任何账号信息匿名请求一次,只用来取卡片和折叠列表。
abstract final class ReplyFoldGrpc {
  static const _build = 8600300;
  static const _versionName = '8.60.0';
  static const _mobiApp = 'android';
  static const _platform = 'android';
  static const _channel = 'master';
  static const _foldList = '${GrpcUrl.reply}/FoldList';
  static const _maxPages = 10;

  static final _options = Options(
    contentType: 'application/grpc',
    responseType: ResponseType.bytes,
    extra: {'account': const NoAccount()},
  );

  static Map<String, String> get _headers {
    final buvid = LoginUtils.buvid;
    return {
      'grpc-encoding': 'gzip',
      'gzip-accept-encoding': 'gzip,identity',
      'user-agent':
          'Mozilla/5.0 BiliDroid/$_versionName (bbcallen@gmail.com) '
          'os/android model/android mobi_app/$_mobiApp build/$_build '
          'channel/$_channel innerVer/$_build osVer/15 network/2',
      'x-bili-trace-id': Constants.traceId,
      'buvid': buvid,
      'bili-http-engine': 'cronet',
      'x-bili-device-bin': base64Encode(
        Device(
          appId: 1,
          build: _build,
          buvid: buvid,
          mobiApp: _mobiApp,
          platform: _platform,
          channel: _channel,
          brand: _platform,
          model: _platform,
          osver: '15',
          versionName: _versionName,
        ).writeToBuffer(),
      ),
      'x-bili-network-bin': base64Encode(
        network.Network(type: network.NetworkType.WIFI).writeToBuffer(),
      ),
      'x-bili-locale-bin': base64Encode(
        Locale(
          cLocale: LocaleIds(language: 'zh', region: 'CN', script: 'Hans'),
          sLocale: LocaleIds(language: 'zh', region: 'CN', script: 'Hans'),
          timezone: 'Asia/Shanghai',
        ).writeToBuffer(),
      ),
      'x-bili-metadata-bin': base64Encode(
        Metadata(
          mobiApp: _mobiApp,
          device: 'phone',
          build: _build,
          channel: _channel,
          buvid: buvid,
          platform: _platform,
        ).writeToBuffer(),
      ),
    };
  }

  /// 失败一律返回 null:这是附加功能,不应打扰正常的评论加载(不弹 toast)。
  static Future<T?> _call<T>(
    String url,
    GeneratedMessage request,
    T Function(Uint8List) parser,
  ) async {
    try {
      final response = await Request.dio.post<Uint8List>(
        HttpString.appBaseUrl + url,
        data: GrpcReq.compressProtobuf(request.writeToBuffer()),
        options: _options.copyWith(headers: _headers),
      );
      final data = response.data;
      if (response.headers.value('Grpc-Status') != '0' || data == null) {
        return null;
      }
      return parser(GrpcReq.decompressProtobuf(data));
    } catch (_) {
      return null;
    }
  }

  /// 主评论列表的折叠卡片(没有被折叠的评论时为 null)。
  static Future<FoldMixedCard?> mainCard({
    required int oid,
    required int type,
  }) async {
    final res = await _call(
      GrpcUrl.mainList,
      MainListReq(
        oid: Int64(oid),
        type: Int64(type),
        rpid: Int64.ZERO,
        cursor: CursorReq(mode: Mode.MAIN_LIST_HOT),
      ),
      MainListReply.fromBuffer,
    );
    if (res == null) return null;
    return mixedCardsOf(
      res,
      mainListMixedCardsTag,
    ).firstWhereOrNull((e) => e.isFold);
  }

  /// 楼中楼的折叠卡片。
  static Future<FoldMixedCard?> detailCard({
    required int oid,
    required int type,
    required int root,
  }) async {
    final res = await _call(
      GrpcUrl.detailList,
      DetailListReq(
        oid: Int64(oid),
        type: Int64(type),
        root: Int64(root),
        rpid: Int64.ZERO,
        scene: DetailListScene.REPLY,
      ),
      DetailListReply.fromBuffer,
    );
    if (res == null) return null;
    return mixedCardsOf(
      res,
      detailListMixedCardsTag,
    ).firstWhereOrNull((e) => e.isFold);
  }

  /// 展开卡片对应的全部折叠评论(已按用户的屏蔽规则过滤)。
  static Future<List<ReplyInfo>?> expand({
    required int oid,
    required int type,
    required FoldMixedCard card,
  }) async {
    final replies = <ReplyInfo>[];
    var pagination = card.fold.foldPagination;
    for (var i = 0; i < _maxPages; i++) {
      final res = await _call(
        _foldList,
        FoldListReq(
          oid: Int64(oid),
          type: Int64(type),
          pagination: pagination,
        ),
        FoldListResp.fromBuffer,
      );
      if (res == null) return replies.isEmpty ? null : replies;
      replies.addAll(res.replies);
      final next = res.paginationReply.nextOffset;
      if (!res.hasPaginationReply() || next.isEmpty) break;
      pagination = FeedPagination(offset: next);
    }
    return replies..removeWhere(ReplyGrpc.needRemoveGrpc);
  }
}
