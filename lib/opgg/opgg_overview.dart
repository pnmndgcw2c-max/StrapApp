// Überblick: energy triangle (Schlaf / Recovery / Ruhe), live biomarkers,
// and the Woche/Monat trend pages. Values are OpenStrap's own; a missing input
// shows "—" and the energy score is only formed when all three sides exist.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/metric.dart' show baselineCountsFromNote;
import '../state/app_state.dart';
import 'opgg_charts.dart';
import 'opgg_data.dart';
import 'opgg_style.dart';

/// What the Today bundle says, or — while it still withholds last night
/// (it waits about an hour past wake) — the value the derive already stored
/// for that night. Both are OpenStrap's own numbers.
double? pick(num? today, OpggDay d, String key) =>
    today?.toDouble() ?? d.recent(key)?.v;

/// Recovery (OpenStrap readiness) needs a personal baseline first.
String recoveryWait(OpggDay d) {
  final c = baselineCountsFromNote(d.today.readiness.note);
  if (c != null) return 'lernt noch · ${c.have}/${c.need} Nächte';
  return 'lernt noch · braucht ca. 14 Nächte';
}

/// The three sides of the triangle, each 0–100 or null.
class Energy {
  final double? sleep, recovery, calm;
  final double? sleepMin, needMin; // for the "why" rows
  final bool needIsGoal; // need not learned yet → Jonas' 8 h goal
  const Energy(this.sleep, this.recovery, this.calm,
      {this.sleepMin, this.needMin, this.needIsGoal = false});

  factory Energy.of(OpggDay d) {
    final t = d.today;
    final dur = pick(t.sleepDuration.value, d, 'sleep');
    final learned = t.sleepNeed.value?.toDouble();
    // Until OpenStrap has learned the sleep need, measure against the 8 h
    // goal Jonas set — labelled as the goal wherever it is shown.
    final need = learned ?? 480.0;
    final sleep = dur == null ? null : (dur / need * 100).clamp(0.0, 100.0);
    // 'recovery' and 'readiness' are the same metric in the read seam.
    final rec = pick(t.readiness.value, d, 'recovery')?.clamp(0.0, 100.0);
    final stress = pick(t.stress?.score, d, 'stress');
    final calm = stress == null ? null : (100 - stress).clamp(0.0, 100.0);
    return Energy(sleep, rec, calm,
        sleepMin: dur, needMin: need, needIsGoal: learned == null);
  }

  double? get total => (sleep != null && recovery != null && calm != null)
      ? (sleep! + recovery! + calm!) / 3
      : null;
}

String _pct(double? v) => v == null ? '—' : '${v.round()}';

class OverviewToday extends StatefulWidget {
  final OpggDay day;
  const OverviewToday({super.key, required this.day});
  @override
  State<OverviewToday> createState() => _OverviewTodayState();
}

class _OverviewTodayState extends State<OverviewToday> {
  bool _why = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final d = widget.day;
    final e = Energy.of(d);
    final t = d.today;
    final now = DateTime.now();

    final hr = app.isConnected ? app.liveHr : null;
    final rmssd = pick(t.hrv?.rmssd, d, 'hrv');
    final rhr = pick(t.restingHr.value, d, 'resting_hr');
    final resp = pick(t.resp?.value, d, 'resp_rate');
    final stress = pick(t.stress?.score, d, 'stress');
    final skin = pick(t.skinTempIdx, d, 'skin_temp_z');
    final night = d.recent('sleep')?.day ?? d.recent('hrv')?.day;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
      children: [
        SectionHead(wdDm(now), hint: 'Heute'),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () => setState(() => _why = !_why),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            decoration: wellDeco(),
            child: Column(children: [
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Energie', style: O.small),
                  Text(_pct(e.total),
                      style: const TextStyle(
                          fontSize: 44,
                          fontWeight: FontWeight.w300,
                          color: O.ink,
                          height: 1.05,
                          fontFeatures: O.tabular)),
                ]),
                const Spacer(),
                Icon(_why ? Icons.expand_less : Icons.expand_more, color: O.ink3, size: 20),
              ]),
              const SizedBox(height: 6),
              SizedBox(
                height: 170,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _TrianglePainter(e),
                ),
              ),
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 220),
                crossFadeState: _why ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                firstChild: const SizedBox(width: double.infinity),
                secondChild: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(children: [
                    _why3(
                        'Schlaf',
                        e.sleep,
                        e.sleepMin == null
                            ? 'keine Nacht erfasst'
                            : '${hMin(e.sleepMin!)} von ${hMin(e.needMin!)}'
                                '${e.needIsGoal ? ' Ziel' : ' Bedarf'}'),
                    _why3('Recovery', e.recovery,
                        e.recovery == null ? recoveryWait(d) : 'HRV, Ruhepuls, Schlaf'),
                    _why3('Ruhe', e.calm,
                        stress == null ? 'noch kein Stresswert' : 'Stress ${stress.round()} von 100'),
                    if (e.total == null)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                            'Die Energie-Zahl erscheint, sobald alle drei Seiten Werte haben.',
                            style: O.small),
                      ),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 22),
        SectionHead('Biomarker',
            hint: night == null ? null : nightLabel(night),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Dot(hr != null ? O.green : (app.isPaired ? O.orange : O.red)),
              const SizedBox(width: 6),
              Text(hr != null ? 'live' : 'zuletzt', style: O.small),
            ])),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 1.15,
          children: [
            _Bio('Puls', hr?.toString(), 'bpm', live: hr != null),
            _Bio('Ruhepuls', rhr?.round().toString(), 'bpm'),
            _Bio('HRV', rmssd?.round().toString(), 'ms'),
            _Bio('Atmung', resp == null ? null : de(resp, 1), '/min'),
            _Bio('Stress', stress?.round().toString(), '/100'),
            _Bio('Haut', skin == null ? null : '${skin >= 0 ? '+' : '−'}${de(skin.abs(), 1)}',
                'vs. normal'),
          ],
        ),
        const SizedBox(height: 22),
        const SectionHead('Aufgaben', hint: 'ab Etappe 2'),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: tileDeco(),
          child: const Text(
              'Hier erscheinen die Notion-Aufgaben, die zu deiner Energie heute passen.',
              style: O.small),
        ),
      ],
    );
  }

  Widget _why3(String label, double? v, String note) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          SizedBox(width: 74, child: Text(label, style: O.body)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: (v ?? 0) / 100,
                minHeight: 5,
                backgroundColor: O.raised,
                valueColor: const AlwaysStoppedAnimation(O.ink),
              ),
            ),
          ),
          SizedBox(
            width: 34,
            child: Text(_pct(v),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13, color: O.ink, fontFeatures: O.tabular)),
          ),
          const SizedBox(width: 10),
          SizedBox(width: 130, child: Text(note, style: O.small, maxLines: 2)),
        ]),
      );
}

class _Bio extends StatelessWidget {
  final String label;
  final String? value;
  final String unit;
  final bool live;
  const _Bio(this.label, this.value, this.unit, {this.live = false});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: tileDeco(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(children: [
              Expanded(child: Text(label, style: O.small)),
              if (live) const Dot(O.green, size: 6),
            ]),
            Text(value ?? '—',
                style: const TextStyle(
                    fontSize: 24, fontWeight: FontWeight.w400, color: O.ink, fontFeatures: O.tabular)),
            Text(unit, style: const TextStyle(fontSize: 11, color: O.ink3)),
          ],
        ),
      );
}

/// Rounded outer triangle (100 %), inner value triangle, labels at corners.
/// Top = Recovery, bottom-left = Schlaf, bottom-right = Ruhe.
class _TrianglePainter extends CustomPainter {
  final Energy e;
  _TrianglePainter(this.e);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final r = math.min(size.height * 0.58, size.width * 0.36);
    final cy = size.height * 0.56;
    Offset corner(int i, double k) {
      final a = -math.pi / 2 + i * 2 * math.pi / 3;
      return Offset(cx + r * k * math.cos(a), cy + r * k * math.sin(a));
    }

    Path tri(double k0, double k1, double k2) => Path()
      ..moveTo(corner(0, k0).dx, corner(0, k0).dy)
      ..lineTo(corner(1, k1).dx, corner(1, k1).dy)
      ..lineTo(corner(2, k2).dx, corner(2, k2).dy)
      ..close();

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeJoin = StrokeJoin.round
      ..color = O.line;
    for (final k in const [0.33, 0.66]) {
      canvas.drawPath(tri(k, k, k), grid);
    }
    canvas.drawPath(
        tri(1, 1, 1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round
          ..color = O.raised);

    // value order matches corners: 0 = Recovery (top), 1 = Ruhe (bottom right),
    // 2 = Schlaf (bottom left).
    final vals = [e.recovery, e.calm, e.sleep];
    if (vals.any((v) => v != null)) {
      final ks = [for (final v in vals) ((v ?? 0) / 100).clamp(0.04, 1.0)];
      final p = tri(ks[0], ks[1], ks[2]);
      canvas.drawPath(p, Paint()..color = O.ink.withValues(alpha: .14));
      canvas.drawPath(
          p,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeJoin = StrokeJoin.round
            ..color = O.ink);
    }

    void label(String text, String v, Offset at, TextAlign align) {
      final tp = TextPainter(
        text: TextSpan(children: [
          TextSpan(text: '$text  ', style: const TextStyle(fontSize: 11, color: O.ink3)),
          TextSpan(
              text: v,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: O.ink, fontFeatures: O.tabular)),
        ]),
        textDirection: TextDirection.ltr,
        textAlign: align,
      )..layout();
      final dx = switch (align) {
        TextAlign.left => at.dx,
        TextAlign.right => at.dx - tp.width,
        _ => at.dx - tp.width / 2,
      };
      tp.paint(canvas, Offset(dx, at.dy));
    }

    final top = corner(0, 1), br = corner(1, 1), bl = corner(2, 1);
    label('Recovery', _pct(e.recovery), Offset(top.dx, top.dy - 18), TextAlign.center);
    label('Ruhe', _pct(e.calm), Offset(br.dx + 6, br.dy + 4), TextAlign.right);
    label('Schlaf', _pct(e.sleep), Offset(bl.dx - 6, bl.dy + 4), TextAlign.left);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) =>
      old.e.sleep != e.sleep || old.e.recovery != e.recovery || old.e.calm != e.calm;
}

// ── Woche / Monat ─────────────────────────────────────────────────────────────

const _recSpec = TrendSpec('recovery', 'Recovery', '%');
const _hrvSpec = TrendSpec('hrv', 'HRV', 'ms');
const _rhrSpec = TrendSpec('resting_hr', 'Ruhepuls', 'bpm');
double _h(double m) => m / 60;
const _sleepSpec = TrendSpec('sleep', 'Schlaf', 'h', dec: 1, map: _h, goal: 8, goalLabel: '8 h');

class OverviewPeriod extends StatelessWidget {
  final OpggDay day;
  final int n;
  const OverviewPeriod({super.key, required this.day, required this.n});
  @override
  Widget build(BuildContext context) {
    final days = lastDays(n);
    final rec = valuesFor(day, _recSpec, days);
    final sl = valuesFor(day, _sleepSpec, days);
    final ar = avgOf(rec), asl = avgOf(sl);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
      children: [
        SectionHead(n == 7 ? 'Letzte 7 Tage' : 'Letzte 30 Tage',
            hint: '${wdDm(days.first)} – ${wdDm(days.last)}'),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
              child: SumTile('Ø Recovery', ar == null ? '--' : '${ar.round()}',
                  ar == null ? recoveryWait(day).replaceFirst('lernt noch · ', 'lernt: ') : '%',
                  bar: ar == null ? null : ar / 100, height: 118)),
          const SizedBox(width: 8),
          Expanded(
              child: SumTile('Ø Schlaf', asl == null ? '--' : de(asl, 1), 'h pro Nacht',
                  bar: asl == null ? null : asl / 8, height: 118)),
        ]),
        const SizedBox(height: 12),
        TrendCard(spec: _recSpec, days: days, values: rec, emptyNote: recoveryWait(day)),
        const SizedBox(height: 12),
        TrendCard(spec: _hrvSpec, days: days, values: valuesFor(day, _hrvSpec, days)),
        const SizedBox(height: 12),
        TrendCard(spec: _rhrSpec, days: days, values: valuesFor(day, _rhrSpec, days)),
      ],
    );
  }
}
