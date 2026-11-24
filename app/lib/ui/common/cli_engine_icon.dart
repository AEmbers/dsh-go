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

/// Antigravity（Gemini 官方四角星）：蓝紫青渐变流体四角星。
class _AntigravityPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF1C7EFF),
          Color(0xFF4285F4),
          Color(0xFF8B5CF6),
          Color(0xFFC084FC),
        ],
      ).createShader(rect)
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(w * 0.50, h * 0.04)
      ..cubicTo(w * 0.50, h * 0.36, w * 0.64, h * 0.50, w * 0.96, h * 0.50)
      ..cubicTo(w * 0.64, h * 0.50, w * 0.50, h * 0.64, w * 0.50, h * 0.96)
      ..cubicTo(w * 0.50, h * 0.64, w * 0.36, h * 0.50, w * 0.04, h * 0.50)
      ..cubicTo(w * 0.36, h * 0.50, w * 0.50, h * 0.36, w * 0.50, h * 0.04)
      ..close();
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
