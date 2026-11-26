// Trend cards for the Woche/Monat pages: one bar per local day, the newest
// (today) highlighted, tap a bar to read its value. Days without a value draw
// a flat empty stub — never an imputed bar.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'opgg_data.dart';
import 'opgg_style.dart';

class TrendSpec {
  final String key; // getChart key
  final String label;
  final String unit;
  final int dec;
  final double Function(double v) map; // e.g. minutes → hours
  final double? min;
  final double? goal;
  final String? goalLabel;
  const TrendSpec(this.key, this.label, this.unit,
      {this.dec = 0, this.map = _id, this.min, this.goal, this.goalLabel});
  static double _id(double v) => v;
}

List<DateTime> lastDays(int n) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return [for (var i = n - 1; i >= 0; i--) today.subtract(Duration(days: i))];
}

List<double?> valuesFor(OpggDay d, TrendSpec s, List<DateTime> days) => [
      for (final day in days)
        if (d.on(s.key, day) case final v?) s.map(v) else null,
    ];

double? avgOf(List<double?> vs) {
  final p = vs.whereType<double>().toList();
  return p.isEmpty ? null : p.reduce((a, b) => a + b) / p.length;
}

class TrendCard extends StatefulWidget {
  final TrendSpec spec;
  final List<DateTime> days;
  final List<double?> values;
  final String? emptyNote; // why there is nothing yet (e.g. baseline learning)
  const TrendCard(
      {super.key,
      required this.spec,
      required this.days,
      required this.values,
      this.emptyNote});
  @override
  State<TrendCard> createState() => _TrendCardState();
}

class _TrendCardState extends State<TrendCard> {
  int? _sel;

  @override
  Widget build(BuildContext context) {
    final s = widget.spec;
    final vals = widget.values;
    final present = vals.whereType<double>().toList();
    final avg = avgOf(vals);
    final hi = present.isEmpty
        ? 1.0
        : math.max(present.reduce(math.max), s.goal ?? 0) * 1.08;
    final lo = s.min ?? 0;
    final n = vals.length;
    final gap = n <= 7 ? 8.0 : 3.0;
    final sel = _sel;
    final headValue = sel != null
        ? (vals[sel] == null ? '—' : de(vals[sel]!, s.dec))
        : (avg == null ? '--' : de(avg, s.dec));
    final headSub = sel != null
        ? wdDm(widget.days[sel])
        : (avg == null ? (widget.emptyNote ?? 'noch keine Daten') : 'Ø pro Tag');

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: tileDeco(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: O.ink)),
              const SizedBox(height: 2),
              Text(headSub, style: O.small),
            ]),
          ),
          Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: headValue,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: O.ink)),
              if (headValue != '--' && headValue != '—')
                TextSpan(text: ' ${s.unit}', style: const TextStyle(fontSize: 13, color: O.ink3)),
            ]),
            style: const TextStyle(fontFeatures: O.tabular),
          ),
        ]),
        const SizedBox(height: 14),
        SizedBox(
          height: 84,
          child: Stack(children: [
            if (s.goal != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 84 * ((s.goal! - lo) / (hi - lo)).clamp(0.0, 1.0),
                child: Row(children: [
                  Expanded(child: Container(height: 1, color: O.ink3.withValues(alpha: .6))),
                  const SizedBox(width: 4),
                  Text(s.goalLabel ?? '', style: const TextStyle(fontSize: 10, color: O.ink3)),
                ]),
              ),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (var i = 0; i < n; i++) ...[
                if (i > 0) SizedBox(width: gap),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _sel = _sel == i ? null : i),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        height: vals[i] == null
                            ? 3
                            : math.max(4, 84 * ((vals[i]! - lo) / (hi - lo)).clamp(0.0, 1.0)),
                        decoration: BoxDecoration(
                          color: vals[i] == null
                              ? O.barEmpty
                              : sel != null
                                  ? (i == sel ? O.ink : O.raised)
                                  : (i == n - 1 ? O.ink : O.bar),
                          borderRadius: BorderRadius.vertical(
                              top: Radius.circular(n <= 7 ? 5 : 2),
                              bottom: const Radius.circular(2)),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ]),
          ]),
        ),
        const SizedBox(height: 8),
        Row(children: [
          for (var i = 0; i < n; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Expanded(
              child: Text(
                n <= 7
                    ? kWd[widget.days[i].weekday - 1]
                    : ((n - 1 - i) % 7 == 0
                        ? '${widget.days[i].day}.${widget.days[i].month}.'
                        : ''),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.visible,
                softWrap: false,
                style: const TextStyle(fontSize: 10, color: O.ink3),
              ),
            ),
          ],
        ]),
      ]),
    );
  }
}

/// Two summary tiles on top of a period page.
class SumTile extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final double? bar; // 0..1, optional progress bar
  final double? height;
  const SumTile(this.label, this.value, this.sub, {super.key, this.bar, this.height});
  @override
  Widget build(BuildContext context) => Container(
        height: height,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: tileDeco(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: O.small),
            Text(value,
                style: const TextStyle(
                    fontSize: 30, fontWeight: FontWeight.w300, color: O.ink, fontFeatures: O.tabular)),
            if (bar != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: bar!.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: O.raised,
                  valueColor: const AlwaysStoppedAnimation(O.ink),
                ),
              ),
            Text(sub, style: O.small),
          ],
        ),
      );
}
