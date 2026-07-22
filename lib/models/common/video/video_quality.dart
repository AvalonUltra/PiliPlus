enum VideoQuality {
  hdrVivid(129, 'HDR Vivid', 'HDR Vivid'),
  super8k(127, '8K 超高清', '8K'),
  dolbyVision(126, '杜比视界', '杜比'),
  hdr(125, 'HDR 真彩', 'HDR'),
  super4K(120, '4K 超高清', '4K'),
  high108060(116, '1080P 60帧', '1080P60'),
  high1080plus(112, '1080P 高码率', '1080P+'),
  high1080(80, '1080P 高清', '1080P'),
  high72060(74, '720P 60帧', '720P60'),
  high720(64, '720P 准高清', '720P'),
  clear480(32, '480P 标清', '480P'),
  fluent360(16, '360P 流畅', '360P'),
  speed240(6, '240P 极速', '240P'),
  ;

  final int code;
  final String desc;
  final String shortDesc;

  const VideoQuality(this.code, this.desc, this.shortDesc);

  static final _codeMap = {for (final i in values) i.code: i};

  static VideoQuality fromCode(int code) => _codeMap[code]!;

  /// “自动”画质的哨兵码(0 不对应任何真实清晰度),存入默认画质偏好中表示
  /// 按网速自适应选档。运行期一律解析为真实清晰度,不会出现在 [values] 里。
  static const int autoCode = 0;

  /// 供 UI 显示:哨兵码返回“自动”,否则返回对应清晰度描述。
  static String descOf(int code) =>
      code == autoCode ? '自动' : (_codeMap[code]?.desc ?? '自动');
}
