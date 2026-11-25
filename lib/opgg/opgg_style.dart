// OPGG design tokens — the dark-grey system from the OPGG mockup.
//
// Kept separate from `ui2/theme.dart` on purpose: OPGG is its own surface and
// should not shift when upstream retunes its palette.

import 'package:flutter/material.dart';

class O {
  O._();
  static const bg = Color(0xFF1D1D20);
  static const well = Color(0xFF17171A);
  static const tile = Color(0xFF27272A);
  static const pill = Color(0xFF2E2E32);
  static const line = Color(0xFF36363A);
  static const raised = Color(0xFF3A3A3E);
  static const raised2 = Color(0xFF303034);
  static const ink = Color(0xFFF4F4F5);
  static const ink2 = Color(0xFFD1D1D6);
  static const ink3 = Color(0xFF9E9EA4);
  static const green = Color(0xFF4CD37E);
  static const orange = Color(0xFFF5A524);
  static const red = Color(0xFFFF5F57);
  static const grey = Color(0xFF5A5A5F);
  static const bar = Color(0xFF6C6C72);
  static const barEmpty = Color(0xFF333337);

  static const label = TextStyle(
      fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: ink3);
  static const small = TextStyle(fontSize: 12, color: ink3);
  static const body = TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: ink);
  static const tabular = [FontFeature.tabularFigures()];
}

/// Inset well (the dark recessed card).
BoxDecoration wellDeco({double r = 22}) => BoxDecoration(
      color: O.well,
      borderRadius: BorderRadius.circular(r),
      boxShadow: const [
        BoxShadow(color: Color(0x6B000000), blurRadius: 8, offset: Offset(0, 2)),
      ],
    );

/// Slightly raised tile.
BoxDecoration tileDeco({double r = 16}) =>
    BoxDecoration(color: O.tile, borderRadius: BorderRadius.circular(r));

/// A small round status dot.
class Dot extends StatelessWidget {
  final Color color;
  final double size;
  const Dot(this.color, {super.key, this.size = 7});
  @override
  Widget build(BuildContext context) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

/// Section header: LABEL left, hint right.
class SectionHead extends StatelessWidget {
  final String label;
  final String? hint;
  final Widget? trailing;
  const SectionHead(this.label, {super.key, this.hint, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(children: [
          Text(label, style: O.label),
          const Spacer(),
          if (hint != null)
            Text(hint!, style: const TextStyle(fontSize: 12, color: O.ink2)),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ]),
      );
}

/// Pill segmented control (white sliding thumb), as in the mockup.
class Seg extends StatelessWidget {
  final List<String> labels;
  final int index;
  final ValueChanged<int> onPick;
  final double height;
  const Seg(
      {super.key,
      required this.labels,
      required this.index,
      required this.onPick,
      this.height = 40});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
          color: O.pill, borderRadius: BorderRadius.circular(14)),
      child: LayoutBuilder(builder: (c, box) {
        final w = (box.maxWidth - 4 * (labels.length - 1)) / labels.length;
        return SizedBox(
          height: height,
          child: Stack(children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOutBack,
              left: index * (w + 4),
              top: 0,
              width: w,
              height: height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [O.ink, Color(0xFFE3E3E6)]),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            Row(children: [
              for (var i = 0; i < labels.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                SizedBox(
                  width: w,
                  height: height,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => onPick(i),
                    child: Center(
                      child: Text(labels[i],
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: i == index ? O.bg : const Color(0xFFA1A1A6))),
                    ),
                  ),
                ),
              ],
            ]),
          ]),
        );
      }),
    );
  }
}

/// White primary / grey secondary button.
class OButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final double height;
  const OButton(this.label,
      {super.key, this.onTap, this.primary = true, this.height = 54});
  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          height: height,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: primary
                  ? const [O.ink, Color(0xFFE2E2E5)]
                  : const [O.raised, O.pill],
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Center(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
                      color: primary ? O.bg : O.ink)),
            ),
          ),
        ),
      ),
    );
  }
}

String de(num v, int d) => v.toStringAsFixed(d).replaceAll('.', ',');
String pad2(int n) => n.toString().padLeft(2, '0');
String hhmm(DateTime t) => '${pad2(t.hour)}:${pad2(t.minute)}';
const kWd = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
String wdDm(DateTime d) => '${kWd[d.weekday - 1]} ${d.day}.${d.month}.';
String hMin(num minutes) {
  final m = minutes.round();
  return m >= 60 ? '${m ~/ 60} h ${pad2(m % 60)}' : '$m min';
}
