import 'package:PiliPlus/pages/common/reply_controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 在折叠锚点那条评论下面接上「展开更多评论」入口;展开后折叠评论紧随其后。
Widget withReplyFold(
  ReplyController controller,
  int index,
  int length,
  Widget child,
) {
  if (index != controller.foldAnchor(length)) return child;
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      child,
      ReplyFoldEntry(controller: controller),
    ],
  );
}

class ReplyFoldEntry extends StatelessWidget {
  const ReplyFoldEntry({super.key, required this.controller});

  final ReplyController controller;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final hint = TextStyle(fontSize: 12, color: colorScheme.outline);
    return Obx(() {
      final status = controller.foldStatus.value;
      final Widget content;
      switch (status) {
        case 1:
          content = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                controller.foldText,
                style: TextStyle(fontSize: 13, color: colorScheme.primary),
              ),
              Icon(
                Icons.keyboard_arrow_down,
                size: 18,
                color: colorScheme.primary,
              ),
            ],
          );
        case 2:
          content = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
              const SizedBox(width: 8),
              Text('正在展开…', style: hint),
            ],
          );
        case 3:
          content = Text(
            controller.foldCount == 0
                ? '折叠的评论均已被屏蔽规则过滤'
                : '已为您展开以下 ${controller.foldCount} 条折叠评论',
            style: hint,
          );
        default:
          return const SizedBox.shrink();
      }
      return InkWell(
        onTap: status == 1 ? controller.expandFold : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(child: content),
        ),
      );
    });
  }
}
