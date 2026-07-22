import 'package:PiliPlus/utils/path_utils.dart';
import 'package:path/path.dart' as path;

/// 一个可选画质变体,用于 iOS 原生播放器的多 variant ABR(无缝自动切档)。
class HdrVariant {
  final String url;
  final int? qualityCode;
  final double? frameRate;
  final int? width;
  final int? height;

  const HdrVariant({
    required this.url,
    this.qualityCode,
    this.frameRate,
    this.width,
    this.height,
  });

  Map<String, dynamic> toMap() => {
    'url': url,
    if (qualityCode != null) 'qualityCode': qualityCode,
    if (frameRate != null) 'frameRate': frameRate,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
  };
}

sealed class DataSource {
  final String videoSource;
  final String? audioSource;
  final int? qualityCode;
  final String? frameRate;

  /// 多画质变体(仅 iOS 原生 ABR 用):非空且 >1 时,原生后端会生成多
  /// variant master 播放列表,由 AVPlayer 按网速无缝切档。
  final List<HdrVariant>? videoVariants;

  DataSource({
    required this.videoSource,
    required this.audioSource,
    this.qualityCode,
    this.frameRate,
    this.videoVariants,
  });
}

class NetworkSource extends DataSource {
  NetworkSource({
    required super.videoSource,
    required super.audioSource,
    super.qualityCode,
    super.frameRate,
    super.videoVariants,
  });
}

class FileSource extends DataSource {
  final String dir;
  final bool isMp4;
  final String typeTag;

  FileSource({
    required this.dir,
    required this.isMp4,
    required bool hasDashAudio,
    required this.typeTag,
  }) : super(
         videoSource: path.join(
           dir,
           typeTag,
           isMp4 ? PathUtils.videoNameType1 : PathUtils.videoNameType2,
         ),
         audioSource: isMp4 || !hasDashAudio
             ? null
             : path.join(dir, typeTag, PathUtils.audioNameType2),
         qualityCode: int.tryParse(typeTag),
       );
}
