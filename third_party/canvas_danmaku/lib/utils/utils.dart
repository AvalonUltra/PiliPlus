import 'dart:math';
import 'dart:ui' as ui;

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:flutter/material.dart';

abstract final class DmUtils {
  static const maxRasterizeSize = 8192.0;

  /// 弹幕主字体。弹幕经 dart:ui 的 ParagraphBuilder 直接绘制,不走 Flutter
  /// 主题,故需宿主 App 显式指定。
  ///
  /// 必须与 [fontFamilyFallback] 配套设置:ParagraphBuilder.pushStyle 会把
  /// `fontFamily ?? ''` 无条件放在字体链首位,而引擎会跳过空串,导致回退链
  /// 的第一项被当成主字体使用(整体字形被回退字体接管)。
  static String? fontFamily;

  /// 弹幕字体回退链:系统字体缺字时补齐生僻字(如打包的 BabelStone Han)。
  /// 描边与内容必须使用同一字体,否则两层会因宽度不一致而错位。
  static List<String>? fontFamilyFallback;

  /// 回退字体(BabelStone Han 一类的全覆盖字体)体积巨大、字形数以万计,
  /// 挂给每一条弹幕会让字形图集持续膨胀 —— 直播间这种高频、长时间、字符
  /// 高度分散的场景下会一路涨到渲染失败,表现为弹幕滚一阵后不再滚动。
  /// 因此只对确实含生僻字的弹幕启用回退链,其余弹幕保持系统默认字体。
  static bool _needsFallback(String text) {
    for (final rune in text.runes) {
      // CJK 扩展 A(BMP 内)与扩展 B 及以上(增补平面)——系统字体常缺这些
      if ((rune >= 0x3400 && rune <= 0x4DBF) ||
          (rune >= 0x20000 && rune <= 0x3FFFF)) {
        return true;
      }
    }
    return false;
  }

  /// 返回该条弹幕应使用的 (主字体, 回退链);普通弹幕返回 (null, null),
  /// 与未接入回退字体前的行为完全一致。
  static (String?, List<String>?) _fontsFor(String text) {
    final fallback = fontFamilyFallback;
    if (fallback == null || fallback.isEmpty || !_needsFallback(text)) {
      return (null, null);
    }
    return (fontFamily, fallback);
  }

  static double devicePixelRatio = 1;
  static final Paint _selfSendPaint = Paint()
    ..style = PaintingStyle.stroke
    ..color = Colors.green;

  static void updateSelfSendPaint(double strokeWidth) {
    _selfSendPaint.strokeWidth = strokeWidth;
  }

  static ui.Paragraph generateParagraph({
    required DanmakuContentItem content,
    required double fontSize,
    required int fontWeight,
  }) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      textAlign: TextAlign.left,
      fontWeight: FontWeight.values[fontWeight],
      textDirection: TextDirection.ltr,
      maxLines: 1,
    ));

    final (family, fallback) = _fontsFor(content.text);

    if (content.count case final count?) {
      builder
        ..pushStyle(ui.TextStyle(
          color: content.color,
          fontSize: fontSize * 0.6,
          fontFamily: family,
          fontFamilyFallback: fallback,
        ))
        ..addText('($count)')
        ..pop();
    }

    builder
      ..pushStyle(ui.TextStyle(
        color: content.color,
        fontSize: fontSize,
        fontFamily: family,
        fontFamilyFallback: fallback,
      ))
      ..addText(content.text);

    return builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
  }

  static ui.Image recordDanmakuImage({
    required ui.Paragraph contentParagraph,
    required DanmakuContentItem content,
    required double fontSize,
    required int fontWeight,
    required double strokeWidth,
  }) {
    double w = contentParagraph.maxIntrinsicWidth + strokeWidth;
    double h = contentParagraph.height + strokeWidth;

    final offset = Offset(
      (strokeWidth / 2.0) + (content.selfSend ? 2.0 : 0.0),
      strokeWidth / 2.0,
    );

    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    if (devicePixelRatio != 1) {
      canvas.scale(devicePixelRatio);
    }

    if (strokeWidth != 0) {
      final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
        textAlign: TextAlign.left,
        fontWeight: FontWeight.values[fontWeight],
        textDirection: TextDirection.ltr,
        maxLines: 1,
      ));
      final Paint strokePaint = Paint()
        ..shader = content.isColorful
            ? const LinearGradient(
                    colors: [Color(0xFFF2509E), Color(0xFF308BCD)])
                .createShader(Rect.fromLTWH(0, 0, w, h))
            : null
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth;

      if (!content.isColorful) {
        strokePaint.color = Colors.black;
      }

      // 必须与内容层解析出同一套字体,否则描边与文字宽度不一致会错位
      final (family, fallback) = _fontsFor(content.text);

      if (content.count case final count?) {
        builder
          ..pushStyle(ui.TextStyle(
            fontSize: fontSize * 0.6,
            foreground: strokePaint,
            fontFamily: family,
            fontFamilyFallback: fallback,
          ))
          ..addText('($count)')
          ..pop();
      }

      builder
        ..pushStyle(ui.TextStyle(
          fontSize: fontSize,
          foreground: strokePaint,
          fontFamily: family,
          fontFamilyFallback: fallback,
        ))
        ..addText(content.text);

      final strokeParagraph = builder.build()
        ..layout(const ui.ParagraphConstraints(width: double.infinity));

      canvas.drawParagraph(strokeParagraph, offset);
      strokeParagraph.dispose();
    }

    canvas.drawParagraph(contentParagraph, offset);

    if (content.selfSend) {
      w += 4;
      canvas.drawRect(Rect.fromLTRB(0, 0, w, h), _selfSendPaint);
    }

    final pic = rec.endRecording();
    final img = pic.toImageSync(
      (w * devicePixelRatio).ceil(),
      (h * devicePixelRatio).ceil(),
    );
    pic.dispose();
    return img;
  }

  static ui.Image recordSpecialDanmakuImg({
    required SpecialDanmakuContentItem content,
    required int fontWeight,
    required double strokeWidth,
  }) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      textAlign: TextAlign.left,
      fontWeight: FontWeight.values[fontWeight],
      textDirection: TextDirection.ltr,
      fontSize: content.fontSize,
    ))
      ..pushStyle(ui.TextStyle(
        color: content.color,
        fontSize: content.fontSize,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        shadows: content.hasStroke
            ? [Shadow(color: Colors.black, blurRadius: strokeWidth)]
            : null,
      ))
      ..addText(content.text);

    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));

    final strokeOffset = strokeWidth / 2;
    final totalWidth = paragraph.maxIntrinsicWidth + strokeWidth;
    final totalHeight = paragraph.height + strokeWidth;

    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);

    Rect rect;

    if (content.rotateZ != 0 || content.matrix != null) {
      rect = _calculateRotatedBounds(
        totalWidth,
        totalHeight,
        content.rotateZ,
        content.matrix,
      );

      if (devicePixelRatio != 1) {
        canvas.scale(devicePixelRatio);
      }
      canvas.translate(strokeOffset - rect.left, strokeOffset - rect.top);

      if (content.matrix case final matrix?) {
        canvas.transform(matrix.storage);
      } else {
        canvas.rotate(content.rotateZ);
      }
      canvas.drawParagraph(paragraph, Offset.zero);
    } else {
      rect = Rect.fromLTRB(0, 0, totalWidth, totalHeight);

      if (devicePixelRatio != 1) {
        canvas.scale(devicePixelRatio);
      }
      canvas.drawParagraph(paragraph, Offset(strokeOffset, strokeOffset));
    }
    paragraph.dispose();

    double width = rect.width * devicePixelRatio;
    double height = rect.height * devicePixelRatio;
    if (width > maxRasterizeSize || height > maxRasterizeSize) {
      final scaledMaxSize = maxRasterizeSize / devicePixelRatio;
      final left = rect.left;
      final top = rect.top;
      double right = rect.right;
      double bottom = rect.bottom;

      if (width > maxRasterizeSize) {
        right = left + scaledMaxSize;
        width = maxRasterizeSize;
      }

      if (height > maxRasterizeSize) {
        bottom = top + scaledMaxSize;
        height = maxRasterizeSize;
      }

      rect = Rect.fromLTRB(left, top, right, bottom);
    }

    content.rect = rect;

    final pic = rec.endRecording();
    final img = pic.toImageSync(width.ceil(), height.ceil());
    pic.dispose();

    return img;
  }

  static Rect _calculateRotatedBounds(
    double w,
    double h,
    double rotateZ,
    Matrix4? matrix,
  ) {
    final double cosZ;
    final double cosY;
    final double sinZ;
    if (matrix == null) {
      cosZ = cos(rotateZ);
      sinZ = sin(rotateZ);
      cosY = 1;
    } else {
      cosZ = matrix[5];
      sinZ = matrix[1];
      cosY = matrix[10];
    }

    final wx = w * cosZ * cosY;
    final wy = w * sinZ;
    final hx = -h * sinZ * cosY;
    final hy = h * cosZ;

    final minX = _min4(0.0, wx, hx, wx + hx);
    final maxX = _max4(0.0, wx, hx, wx + hx);
    final minY = _min4(0.0, wy, hy, wy + hy);
    final maxY = _max4(0.0, wy, hy, wy + hy);

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  @pragma("vm:prefer-inline")
  static double _min4(double a, double b, double c, double d) {
    final ab = a < b ? a : b;
    final cd = c < d ? c : d;
    return ab < cd ? ab : cd;
  }

  @pragma("vm:prefer-inline")
  static double _max4(double a, double b, double c, double d) {
    final ab = a > b ? a : b;
    final cd = c > d ? c : d;
    return ab > cd ? ab : cd;
  }
}
