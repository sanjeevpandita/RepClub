import 'dart:math';

import 'package:flutter/material.dart';

import 'evaluation.dart';

// Design space of the figure: 280 wide (centre x = 140), 700 tall.
const _cx = 140.0;
const _designW = 280.0;
const _designH = 700.0;

// Right half of the outline (viewer's right), top to bottom, as (offset from centre, y).
// The left half is the mirror image.
const _half = <Offset>[
  Offset(14, 92), Offset(14, 108), Offset(50, 118), Offset(74, 128),
  Offset(88, 150), Offset(92, 200), Offset(98, 262), Offset(106, 310),
  Offset(112, 340), Offset(120, 374), Offset(110, 388), Offset(98, 372),
  Offset(88, 340), Offset(80, 300), Offset(72, 260), Offset(62, 215),
  Offset(52, 165), Offset(46, 200), Offset(44, 262), Offset(54, 330),
  Offset(56, 360), Offset(46, 430), Offset(42, 500), Offset(46, 560),
  Offset(36, 640), Offset(40, 670), Offset(24, 684), Offset(8, 676),
  Offset(8, 660), Offset(10, 640), Offset(6, 560), Offset(4, 500),
  Offset(6, 430), Offset(4, 385),
];

/// Where each measurement sits on the figure: (side of the label, dx from centre, y).
/// "Right" limbs are on the viewer's left, as on a person facing you.
const _anchors = <String, ({bool left, double dx, double y})>{
  'neck_cm': (left: true, dx: -12, y: 100),
  'shoulders_cm': (left: false, dx: 60, y: 128),
  'chest_cm': (left: true, dx: -34, y: 172),
  'bicep_right_cm': (left: true, dx: -76, y: 205),
  'bicep_left_cm': (left: false, dx: 76, y: 205),
  'waist_cm': (left: false, dx: 30, y: 262),
  'forearm_right_cm': (left: true, dx: -93, y: 300),
  'forearm_left_cm': (left: false, dx: 93, y: 300),
  'hips_cm': (left: true, dx: -38, y: 340),
  'thigh_upper_right_cm': (left: true, dx: -28, y: 410),
  'thigh_upper_left_cm': (left: false, dx: 28, y: 410),
  'thigh_mid_right_cm': (left: true, dx: -24, y: 470),
  'thigh_mid_left_cm': (left: false, dx: 24, y: 470),
  'calf_right_cm': (left: true, dx: -26, y: 560),
  'calf_left_cm': (left: false, dx: 26, y: 560),
};

class _Item {
  _Item(this.field, this.value, this.delta, this.anchor);
  final EvalField field;
  final double value;
  final double? delta; // change since the previous evaluation
  final ({bool left, double dx, double y}) anchor;
  double labelY = 0; // px, centre of the chip
  Offset target = Offset.zero; // px, point on the body
}

/// A body figure with each tape measurement linked to its body part by an arrow,
/// and an up/down arrow showing the change since the previous evaluation.
class BodyMap extends StatelessWidget {
  const BodyMap({super.key, required this.data, this.previous});
  final Map<String, dynamic> data;
  final Map<String, dynamic>? previous;

  static const _labelW = 86.0;
  static const _chipH = 32.0;
  // Label and number are the same size; the number is bold. Tight line height (1.15)
  // keeps each label right above its number.
  static const _label = TextStyle(fontSize: 11, height: 1.15);
  static const _number =
      TextStyle(fontSize: 12, height: 1.15, fontWeight: FontWeight.w600);
  static const _unit = TextStyle(fontSize: 9, height: 1.15);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = <_Item>[];
    for (final f in evalTape) {
      final a = _anchors[f.key];
      final v = data[f.key];
      if (a == null || v == null) continue;
      final value = double.parse(v.toString());
      final p = previous?[f.key];
      items.add(_Item(
          f, value, p == null ? null : value - double.parse(p.toString()), a));
    }
    if (items.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final bodyW = w - 2 * _labelW;
      final s = bodyW / _designW;
      final h = _designH * s;
      final ox = _labelW; // body area starts after the left label column

      for (final side in [true, false]) {
        final list = items.where((i) => i.anchor.left == side).toList()
          ..sort((a, b) => a.anchor.y.compareTo(b.anchor.y));
        var minY = _chipH / 2;
        for (final i in list) {
          i.target = Offset(ox + (_cx + i.anchor.dx) * s, i.anchor.y * s);
          i.labelY = max(i.anchor.y * s, minY);
          minY = i.labelY + _chipH + 2;
        }
      }
      final height = max(h, items.fold<double>(0, (m, i) => max(m, i.labelY + _chipH / 2)));

      return SizedBox(
        height: height,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _BodyPainter(
                  items: items,
                  scale: s,
                  offsetX: ox,
                  width: w,
                  fill: theme.colorScheme.surfaceContainerHighest,
                  line: theme.colorScheme.primary,
                  arrowColor: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            for (final i in items) _chip(theme, i, w),
          ],
        ),
      );
    });
  }

  Widget _chip(ThemeData theme, _Item i, double w) {
    final left = i.anchor.left;
    return Positioned(
      top: i.labelY - _chipH / 2,
      left: left ? 0 : w - _labelW,
      width: _labelW - 4,
      height: _chipH,
      // Large phone text settings (common on iPhone) would make the labels overlap,
      // so the body map caps the text scaling.
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.1,
        child: Column(
          crossAxisAlignment:
              left ? CrossAxisAlignment.start : CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(i.field.label.replaceAll(' right', ' R').replaceAll(' left', ' L'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _label.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            Text.rich(TextSpan(children: [
              TextSpan(text: evalNumber(i.value), style: _number),
              TextSpan(text: ' ${i.field.unit}', style: _unit),
            ])),
          ],
        ),
      ),
    );
  }
}

class _BodyPainter extends CustomPainter {
  _BodyPainter({
    required this.items,
    required this.scale,
    required this.offsetX,
    required this.width,
    required this.fill,
    required this.line,
    required this.arrowColor,
  });
  final List<_Item> items;
  final double scale;
  final double offsetX;
  final double width;
  final Color fill;
  final Color line;
  final Color arrowColor;

  Offset _p(Offset o) => Offset(offsetX + (_cx + o.dx) * scale, o.dy * scale);

  /// Smooth closed curve through [pts] (Catmull-Rom converted to Beziers).
  Path _smooth(List<Offset> pts) {
    final n = pts.length;
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (var i = 0; i < n; i++) {
      final p0 = pts[(i - 1 + n) % n];
      final p1 = pts[i];
      final p2 = pts[(i + 1) % n];
      final p3 = pts[(i + 2) % n];
      final c1 = p1 + (p2 - p0) / 6;
      final c2 = p2 - (p3 - p1) / 6;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final right = [for (final o in _half) _p(o)];
    final leftSide = [
      for (final o in _half.reversed) _p(Offset(-o.dx, o.dy))
    ];
    final body = _smooth([...right, _p(const Offset(0, 392)), ...leftSide]);
    final fillPaint = Paint()..color = fill;
    final edge = Paint()
      ..color = line.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawPath(body, fillPaint);
    canvas.drawPath(body, edge);
    final head = Rect.fromCenter(
        center: _p(const Offset(0, 52)), width: 52 * scale, height: 70 * scale);
    canvas.drawOval(head, fillPaint);
    canvas.drawOval(head, edge);

    final stroke = Paint()
      ..color = arrowColor
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final i in items) {
      final from = Offset(i.anchor.left ? _labelWidth() : width - _labelWidth(),
          i.labelY);
      canvas.drawLine(from, i.target, stroke);
      // Arrowhead pointing at the body part.
      final dir = (i.target - from);
      final len = dir.distance;
      if (len > 0) {
        final u = dir / len;
        final n = Offset(-u.dy, u.dx);
        final tip = i.target;
        final base = tip - u * 7;
        canvas.drawPath(
          Path()
            ..moveTo(tip.dx, tip.dy)
            ..lineTo(base.dx + n.dx * 3.5, base.dy + n.dy * 3.5)
            ..lineTo(base.dx - n.dx * 3.5, base.dy - n.dy * 3.5)
            ..close(),
          Paint()..color = line,
        );
      }
    }
  }

  double _labelWidth() => offsetX;

  @override
  bool shouldRepaint(covariant _BodyPainter old) =>
      old.items != items || old.scale != scale || old.width != width;
}
