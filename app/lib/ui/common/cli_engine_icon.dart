import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../theme/app_icons.dart';

/// 各 CLI 引擎在多 CLI 工作台中的代表色。
Color cliEngineAccent(CliEngine engine, ColorScheme scheme) => switch (engine) {
  CliEngine.antigravity => const Color(0xFF4285F4),
  CliEngine.claude => const Color(0xFFD97757),
  CliEngine.codex => const Color(0xFF6366F1),
  CliEngine.dsh => scheme.primary,
};

/// 渲染各 CLI 引擎的品牌小图标（Antigravity / Claude / Codex / DSH）。
class CliEngineIcon extends StatelessWidget {
  const CliEngineIcon({
    super.key,
    required this.engine,
    this.size = 16,
    this.dshColor,
  });

  final CliEngine engine;
  final double size;

  /// 当 [engine] 为 [CliEngine.dsh] 时的前景色；默认取 [ColorScheme.primary]。
  final Color? dshColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (engine == CliEngine.dsh) {
      return Icon(AppIcons.chat, size: size, color: dshColor ?? scheme.primary);
    }
    return SizedBox.square(
      key: ValueKey('cli-icon-${engine.wire}'),
      dimension: size,
      child: CustomPaint(
        painter: switch (engine) {
          CliEngine.antigravity => _AntigravityPainter(),
          CliEngine.claude => _ClaudeStarburstPainter(),
          CliEngine.codex => _CodexKnotPainter(),
          CliEngine.dsh => null,
        },
      ),
    );
  }
}

/// Antigravity（Google Gemini 官方四角星 Logo）：精确四分之一圆弧内切轮廓 + 官方四色渐变。
class _AntigravityPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final r = math.min(w, h) * 0.46;
    const k = 0.55228475;
    final c = r * k;
    final cx = w / 2;
    final cy = h / 2;

    final path = Path()
      ..moveTo(cx, cy - r)
      ..cubicTo(cx, cy - r + c, cx + r - c, cy, cx + r, cy)
      ..cubicTo(cx + r - c, cy, cx, cy + r - c, cx, cy + r)
      ..cubicTo(cx, cy + r - c, cx - r + c, cy, cx - r, cy)
      ..cubicTo(cx - r + c, cy, cx, cy - r + c, cx, cy - r)
      ..close();

    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = const SweepGradient(
        center: Alignment.center,
        startAngle: -math.pi * 0.5,
        endAngle: math.pi * 1.5,
        colors: [
          Color(0xFFEA4335), // 上红
          Color(0xFFFBBC04), // 右黄
          Color(0xFF34A853), // 下绿
          Color(0xFF4285F4), // 左蓝
          Color(0xFFEA4335), // 闭合回上红
        ],
        stops: [0.0, 0.25, 0.5, 0.75, 1.0],
      ).createShader(rect)
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Claude 暖橙色 12 瓣星芒图标。
class _ClaudeStarburstPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outer = size.width * 0.45;
    final inner = size.width * 0.14;
    final paint = Paint()
      ..color = const Color(0xFFD97757)
      ..strokeWidth = math.max(1.2, size.width * 0.11)
      ..strokeCap = StrokeCap.round;

    const rays = 10;
    for (var i = 0; i < rays; i++) {
      final angle = (math.pi * 2 / rays) * i;
      final r = i.isEven ? outer : outer * 0.84;
      canvas.drawLine(
        center + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        center + Offset(math.cos(angle) * r, math.sin(angle) * r),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Codex 蓝紫色多瓣编织花结图标。
class _CodexKnotPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.26;
    final orbit = size.width * 0.17;
    final paint = Paint()
      ..color = const Color(0xFF6366F1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.1, size.width * 0.09);

    const petals = 6;
    for (var i = 0; i < petals; i++) {
      final angle = (math.pi * 2 / petals) * i;
      final c = center + Offset(math.cos(angle) * orbit, math.sin(angle) * orbit);
      canvas.drawCircle(c, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
