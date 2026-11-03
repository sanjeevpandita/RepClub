import 'package:flutter/material.dart';

import '../shared/common.dart';

/// Line graph of weight check-ins (oldest first). One point per check-in.
class WeightChart extends StatelessWidget {
  const WeightChart({super.key, required this.logs});
  final List<Map<String, dynamic>> logs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final values =
        [for (final l in logs) double.parse(l['weight_kg'].toString())];
    final last = logs.last;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${last['weight_kg']} kg',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(color: theme.colorScheme.primary)),
          Text('Latest, ${showIso(last['logged_on'])}'),
          const SizedBox(height: 12),
          if (values.length < 2)
            const Text('Log one more weight to see your graph.')
          else ...[
            SizedBox(
              height: 160,
              width: double.infinity,
              child: CustomPaint(
                painter: _ChartPainter(
                  values,
                  line: theme.colorScheme.primary,
                  grid: theme.dividerColor,
                  text: theme.textTheme.bodySmall?.color ?? Colors.white70,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(showIso(logs.first['logged_on']),
                    style: theme.textTheme.bodySmall),
                Text(showIso(last['logged_on']),
                    style: theme.textTheme.bodySmall),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.v,
      {required this.line, required this.grid, required this.text});
  final List<double> v;
  final Color line, grid, text;

  @override
  void paint(Canvas canvas, Size size) {
    var lo = v.reduce((a, b) => a < b ? a : b);
    var hi = v.reduce((a, b) => a > b ? a : b);
    if (hi - lo < 1) {
      lo -= 0.5;
      hi += 0.5;
    }
    final pad = (hi - lo) * 0.1;
    lo -= pad;
    hi += pad;
    const left = 40.0;
    final w = size.width - left;
    Offset pt(int i) => Offset(left + w * i / (v.length - 1),
        size.height * (1 - (v[i] - lo) / (hi - lo)));

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final f in [0.0, 0.5, 1.0]) {
      final y = size.height * f;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), gridPaint);
      final value = hi - (hi - lo) * f;
      final tp = TextPainter(
        text: TextSpan(
            text: value.toStringAsFixed(1),
            style: TextStyle(color: text, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, (y - tp.height / 2).clamp(0, size.height - tp.height)));
    }

    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < v.length; i++) {
      path.lineTo(pt(i).dx, pt(i).dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round);
    final dot = Paint()..color = line;
    for (var i = 0; i < v.length; i++) {
      canvas.drawCircle(pt(i), 4, dot);
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) => old.v != v;
}
