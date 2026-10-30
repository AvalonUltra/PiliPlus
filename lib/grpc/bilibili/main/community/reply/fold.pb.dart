// Hand-written to match bilibili/main/community/reply/v1 (MixedCard as
// FoldMixedCard,
// FoldCard, FoldListReq, FoldListResp), which the bundled v1.pb.dart
// predates. Unlisted fields stay in unknownFields.

// ignore_for_file: annotate_overrides, non_constant_identifier_names

import 'dart:convert' show base64, base64Decode;
import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import '../../../pagination.pb.dart' as $2;
import 'v1.pb.dart';

/// `MainListReply.mixed_cards` / `DetailListReply.mixed_cards` field numbers.
const $core.int mainListMixedCardsTag = 27;
const $core.int detailListMixedCardsTag = 11;

/// Mixed cards of [msg] under [tag], parsed with the fold-aware definition.
/// The bundled v1.pb.dart may already know the repeated field (without
/// `fold`); its per-card unknown fields survive re-serialisation.
$core.List<FoldMixedCard> mixedCardsOf(
  $pb.GeneratedMessage msg,
  $core.int tag,
) {
  if (msg.info_.fieldInfo.containsKey(tag)) {
    final known = msg.getField(tag) as $core.List;
    return [
      for (final $pb.GeneratedMessage card in known)
        FoldMixedCard.fromBuffer(card.writeToBuffer()),
    ];
  }
  final field = msg.unknownFields.getField(tag);
  if (field == null) return const [];
  return field.lengthDelimited.map(FoldMixedCard.fromBuffer).toList();
}

class FoldCard extends $pb.GeneratedMessage {
  factory FoldCard() => FoldCard._();

  FoldCard._();

  factory FoldCard.fromBuffer($core.List<$core.int> data) =>
      FoldCard()..mergeFromBuffer(data);

  static final $pb.BuilderInfo _i =
      $pb.BuilderInfo(
          'FoldCard',
          package: const $pb.PackageName('bilibili.main.community.reply.v1'),
          createEmptyInstance: FoldCard._,
        )
        ..aOS(1, 'bottomText')
        ..aOM<$2.FeedPagination>(
          2,
          'foldPagination',
          subBuilder: $2.FeedPagination.$_createMessage,
        )
        ..hasRequiredFields = false;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.override
  FoldCard createEmptyInstance() => FoldCard._();

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FoldCard clone() => deepCopy();

  $core.String get bottomText => $_getSZ(0);
  $core.bool hasFoldPagination() => $_has(1);
  $2.FeedPagination get foldPagination => $_getN(1);
}

class FoldMixedCard extends $pb.GeneratedMessage {
  static const $core.int typeFold = 2;

  factory FoldMixedCard() => FoldMixedCard._();

  FoldMixedCard._();

  factory FoldMixedCard.fromBuffer($core.List<$core.int> data) =>
      FoldMixedCard()..mergeFromBuffer(data);

  static final $pb.BuilderInfo _i =
      $pb.BuilderInfo(
          'MixedCard',
          package: const $pb.PackageName('bilibili.main.community.reply.v1'),
          createEmptyInstance: FoldMixedCard._,
        )
        // enum Type { UNKNOWN = 0; QUESTION = 1; FOLD = 2; }
        ..aI(1, 'type')
        ..aOS(2, 'oid')
        ..aInt64(3, 'displayRank')
        ..aOM<FoldCard>(5, 'fold', subBuilder: FoldCard._)
        ..hasRequiredFields = false;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.override
  FoldMixedCard createEmptyInstance() => FoldMixedCard._();

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FoldMixedCard clone() => deepCopy();

  $core.int get type => $_getIZ(0);
  $core.String get oid => $_getSZ(1);
  $fixnum.Int64 get displayRank => $_getI64(2);
  $core.bool hasFold() => $_has(3);
  FoldCard get fold => $_getN(3);

  $core.bool get isFold =>
      type == typeFold && hasFold() && fold.hasFoldPagination();

  /// 分页令牌里编码的被折叠评论 rpid(令牌格式未公开:{3: {1: packed rpids}}),
  /// 解析失败时返回空集。
  $core.Set<$fixnum.Int64> get foldedRpids {
    try {
      final token = base64Decode(
        base64.normalize(fold.foldPagination.offset),
      );
      final outer = $pb.CodedBufferReader(token);
      while (!outer.isAtEnd()) {
        final tag = outer.readTag();
        if (tag >> 3 != 3 || tag & 7 != 2) {
          outer.skipField(tag);
          continue;
        }
        final rpids = <$fixnum.Int64>{};
        final inner = $pb.CodedBufferReader(outer.readBytes());
        while (!inner.isAtEnd()) {
          final t = inner.readTag();
          if (t >> 3 == 1 && t & 7 == 2) {
            final packed = $pb.CodedBufferReader(inner.readBytes());
            while (!packed.isAtEnd()) {
              rpids.add(packed.readInt64());
            }
          } else if (t >> 3 == 1 && t & 7 == 0) {
            rpids.add(inner.readInt64());
          } else {
            inner.skipField(t);
          }
        }
        return rpids;
      }
    } catch (_) {}
    return const {};
  }
}

class FoldListReq extends $pb.GeneratedMessage {
  factory FoldListReq({
    $fixnum.Int64? oid,
    $fixnum.Int64? type,
    $2.FeedPagination? pagination,
  }) {
    final result = FoldListReq._();
    if (oid != null) result.$_setInt64(0, oid);
    if (type != null) result.$_setInt64(1, type);
    if (pagination != null) result.setField(4, pagination);
    return result;
  }

  FoldListReq._();

  static final $pb.BuilderInfo _i =
      $pb.BuilderInfo(
          'FoldListReq',
          package: const $pb.PackageName('bilibili.main.community.reply.v1'),
          createEmptyInstance: FoldListReq._,
        )
        ..aInt64(1, 'oid')
        ..aInt64(2, 'type')
        ..aOS(3, 'extra')
        ..aOM<$2.FeedPagination>(
          4,
          'pagination',
          subBuilder: $2.FeedPagination.$_createMessage,
        )
        ..hasRequiredFields = false;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.override
  FoldListReq createEmptyInstance() => FoldListReq._();

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FoldListReq clone() => deepCopy();
}

class FoldListResp extends $pb.GeneratedMessage {
  factory FoldListResp() => FoldListResp._();

  FoldListResp._();

  factory FoldListResp.fromBuffer($core.List<$core.int> data) =>
      FoldListResp()..mergeFromBuffer(data);

  static final $pb.BuilderInfo _i =
      $pb.BuilderInfo(
          'FoldListResp',
          package: const $pb.PackageName('bilibili.main.community.reply.v1'),
          createEmptyInstance: FoldListResp._,
        )
        ..pPM<ReplyInfo>(1, 'replies', subBuilder: ReplyInfo.$_createMessage)
        ..aOM<$2.FeedPaginationReply>(
          2,
          'paginationReply',
          subBuilder: $2.FeedPaginationReply.$_createMessage,
        )
        ..aOS(3, 'title')
        ..hasRequiredFields = false;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.override
  FoldListResp createEmptyInstance() => FoldListResp._();

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FoldListResp clone() => deepCopy();

  $pb.PbList<ReplyInfo> get replies => $_getList(0);
  $core.bool hasPaginationReply() => $_has(1);
  $2.FeedPaginationReply get paginationReply => $_getN(1);
  $core.String get title => $_getSZ(2);
}
