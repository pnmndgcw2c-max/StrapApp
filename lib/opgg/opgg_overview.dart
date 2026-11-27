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
import 'opgg_sync.dart';
import 'opgg_focus.dart';
import 'opgg_tasks.dart';
import 'opgg_toast.dart';

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

/// Energy of a past day from the stored series (same rule: all three sides).
double? energyOn(OpggDay d, DateTime day) {
  final sl = d.on('sleep', day), rc = d.on('recovery', day), st = d.on('stress', day);
  if (sl == null || rc == null || st == null) return null;
  final need = d.today.sleepNeed.value?.toDouble() ?? 480.0;
  return ((sl / need * 100).clamp(0.0, 100.0) + rc.clamp(0.0, 100.0) + (100 - st).clamp(0.0, 100.0)) /
      3;
}

String energyWord(double? e) => e == null
    ? '—'
    : e >= 70
        ? 'HOCH'
        : e >= 45
            ? 'MITTEL'
            : 'NIEDRIG';

String _pct(double? v) => v == null ? '—' : '${v.round()}';

/// Rough duration of a task by its effort (shown as "~…").
String effortEst(String? effort) => switch (effort) {
      'kurz' => '20 min',
      'lang' => '2 h 30',
      _ => '1 h',
    };

class OverviewToday extends StatefulWidget {
  final OpggDay day;
  final void Function(OTask) onStart;
  final VoidCallback onTasks;
  const OverviewToday({super.key, required this.day, required this.onStart, required this.onTasks});
  @override
  State<OverviewToday> createState() => _OverviewTodayState();
}

class _OverviewTodayState extends State<OverviewToday> {
  bool _why = false;
  int _sel = -1; // selected activity on the pulse curve

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
    final acts = _activities(d, now);
    final wakeMin = acts.where((a) => a.type == 'sleep').firstOrNull?.b ?? 0;
    final dayHr = d.hrAvg(wakeMin + 1, 1440);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(children: [
            const Text('HEUTE', style: O.label),
            const Spacer(),
            Text(wdDm(now), style: const TextStyle(fontSize: 12, color: O.ink2)),
          ]),
        ),
        const SizedBox(height: 10),
        // ── energy: triangle + number + three rows (mockup) ──
        Container(
          height: 160,
          padding: const EdgeInsets.fromLTRB(10, 14, 16, 14),
          decoration: wellDeco(),
          child: Row(children: [
            GestureDetector(
              onTap: () => setState(() => _why = !_why),
              child: SizedBox(
                  width: 150, height: 132, child: CustomPaint(painter: _TrianglePainter(e))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ENERGIE · ${energyWord(e.total)}', style: O.label),
                    const SizedBox(height: 2),
                    Text.rich(TextSpan(children: [
                      TextSpan(
                          text: _pct(e.total),
                          style: const TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w300,
                              height: 1.05,
                              color: O.ink,
                              fontFeatures: O.tabular)),
                      const TextSpan(text: ' /100', style: TextStyle(fontSize: 14, color: O.ink3)),
                    ])),
                    const SizedBox(height: 8),
                    for (final r in [('Schlaf', e.sleep), ('Recovery', e.recovery), ('Ruhe', e.calm)])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(children: [
                          Text(r.$1, style: const TextStyle(fontSize: 12, color: O.ink3)),
                          const Spacer(),
                          Text(_pct(r.$2),
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: O.ink,
                                  fontFeatures: O.tabular)),
                        ]),
                      ),
                  ]),
            ),
          ]),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 220),
          crossFadeState: _why ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: _Reasons(e: e, d: d, rmssd: rmssd, rhr: rhr, stress: stress, dayHr: dayHr),
          ),
        ),
        const SizedBox(height: 18),
        SectionHead('Biomarker',
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
        const SizedBox(height: 18),
        // ── pulse curve, auto-assigned to what you did ──
        const SectionHead('Puls heute', hint: 'automatisch zugeordnet'),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          decoration: tileDeco(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              height: 96,
              child: d.hr.isEmpty
                  ? const Center(child: Text('noch keine Pulsdaten heute', style: O.small))
                  : CustomPaint(painter: _HrPainter(d.hr, acts, _sel)),
            ),
            const SizedBox(height: 6),
            const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('0', style: TextStyle(fontSize: 10, color: O.ink3)),
              Text('6', style: TextStyle(fontSize: 10, color: O.ink3)),
              Text('12', style: TextStyle(fontSize: 10, color: O.ink3)),
              Text('18', style: TextStyle(fontSize: 10, color: O.ink3)),
              Text('24 Uhr', style: TextStyle(fontSize: 10, color: O.ink3)),
            ]),
            const SizedBox(height: 4),
            for (var i = 0; i < acts.length; i++)
              InkWell(
                onTap: () => setState(() => _sel = _sel == i ? -1 : i),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: O.line))),
                  child: Row(children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          color: i == _sel ? const Color(0xFF8FE0A8) : _swatch(acts[i].type),
                          borderRadius: BorderRadius.circular(3)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(acts[i].label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: O.ink)),
                        Text(acts[i].range, style: const TextStyle(fontSize: 11, color: O.ink3)),
                      ]),
                    ),
                    Text(acts[i].avg == null ? '—' : 'Ø ${acts[i].avg!.round()} bpm',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w500, color: O.ink, fontFeatures: O.tabular)),
                  ]),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 18),
        // ── tasks that fit today ──
        ListenableBuilder(
          listenable: NotionStore.instance,
          builder: (context, _) {
            final n = NotionStore.instance;
            final top = suggest(n.tasks, e.total).take(3).toList();
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Text('HEUTE PASST', style: O.label),
                const Spacer(),
                GestureDetector(
                  onTap: widget.onTasks,
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    decoration:
                        BoxDecoration(color: O.pill, borderRadius: BorderRadius.circular(999)),
                    child: const Text('Alle Aufgaben →',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: O.ink2)),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                decoration: tileDeco(),
                child: !n.configured || top.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                            !n.configured
                                ? 'Notion verbinden, dann erscheinen hier passende Aufgaben.'
                                : 'Keine offenen Aufgaben.',
                            style: O.small),
                      )
                    : Column(children: [
                        for (var i = 0; i < top.length; i++)
                          _FitRow(top[i], first: i == 0),
                      ]),
              ),
            ]);
          },
        ),
      ],
    );
  }
}

// ── activities on the pulse curve ──

class _Act {
  final String type, label, range; // type: sleep | focus | train
  final int a, b; // minutes of today
  final double? avg;
  const _Act(this.type, this.label, this.range, this.a, this.b, this.avg);
}

Color _swatch(String type) => switch (type) {
      'sleep' => const Color(0xFF3A3A3E),
      'train' => const Color(0xFF8A8A90),
      _ => const Color(0xFF5A5A5F),
    };

List<_Act> _activities(OpggDay d, DateTime now) {
  final mid = DateTime(now.year, now.month, now.day);
  final nowMin = now.hour * 60 + now.minute;
  int minOf(int epochSec) {
    final t = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    final m = t.difference(mid).inMinutes;
    return m.clamp(0, nowMin);
  }

  String range(int fromSec, int? toSec) =>
      '${hhmm(DateTime.fromMillisecondsSinceEpoch(fromSec * 1000))} – '
      '${toSec == null ? 'jetzt' : hhmm(DateTime.fromMillisecondsSinceEpoch(toSec * 1000))}';
  final out = <_Act>[];
  final n = d.night;
  if (n != null && n.wake * 1000 > mid.millisecondsSinceEpoch) {
    final a = minOf(n.onset), b = minOf(n.wake);
    out.add(_Act('sleep', 'Schlaf', range(n.onset, n.wake), a, b, d.hrAvg(a, b)));
  }
  final f = FocusStore.instance;
  for (final s in f.onDay(now)) {
    final a = minOf(s.start ~/ 1000), b = minOf(s.end ~/ 1000);
    out.add(_Act('focus', 'Fokus · ${s.label}', range(s.start ~/ 1000, s.end ~/ 1000), a, b,
        d.hrAvg(a, b)));
  }
  if (f.phase != FPhase.idle) {
    final a = minOf(f.startedAt ~/ 1000);
    out.add(_Act('focus', 'Fokus läuft${f.taskTitle == null ? '' : ' · ${f.taskTitle}'}',
        range(f.startedAt ~/ 1000, null), a, nowMin, d.hrAvg(a, nowMin)));
  }
  for (final w in d.workouts) {
    final st = (w['start_ts'] as num?)?.toInt();
    if (st == null) continue;
    final en = (w['end_ts'] as num?)?.toInt();
    final a = minOf(st), b = en == null ? nowMin : minOf(en);
    final name = '${w['title'] ?? w['type'] ?? 'Training'}';
    out.add(_Act('train', 'Training · $name', range(st, en), a, b,
        (w['avg_hr'] as num?)?.toDouble() ?? d.hrAvg(a, b)));
  }
  out.sort((x, y) => x.a.compareTo(y.a));
  return out;
}

class _HrPainter extends CustomPainter {
  final List<(int, double)> hr;
  final List<_Act> acts;
  final int sel;
  _HrPainter(this.hr, this.acts, this.sel);

  @override
  void paint(Canvas canvas, Size size) {
    double x(num m) => m / 1440 * size.width;
    double y(double v) => size.height - ((v - 40) / 130).clamp(0.0, 1.0) * size.height;
    for (var i = 0; i < acts.length; i++) {
      final a = acts[i];
      final c = i == sel
          ? const Color(0x408FE0A8)
          : switch (a.type) {
              'sleep' => const Color(0x0DFFFFFF),
              'train' => const Color(0x26FFFFFF),
              _ => const Color(0x17FFFFFF),
            };
      final w = math.max(2.0, x(a.b) - x(a.a));
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x(a.a), 0, w, size.height), const Radius.circular(4)),
          Paint()..color = c);
    }
    final path = Path();
    (int, double)? prev;
    for (final p in hr) {
      // A gap of more than 20 min (band off) breaks the line.
      if (prev == null || p.$1 - prev.$1 > 20) {
        path.moveTo(x(p.$1), y(p.$2));
      } else {
        path.lineTo(x(p.$1), y(p.$2));
      }
      prev = p;
    }
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = O.ink);
  }

  @override
  bool shouldRepaint(_HrPainter old) => old.hr != hr || old.sel != sel || old.acts.length != acts.length;
}

// ── why the energy is what it is ──

class _Reasons extends StatelessWidget {
  final Energy e;
  final OpggDay d;
  final double? rmssd, rhr, stress, dayHr;
  const _Reasons(
      {required this.e, required this.d, this.rmssd, this.rhr, this.stress, this.dayHr});

  @override
  Widget build(BuildContext context) {
    final t = d.today;
    final last = d.latest('sleep');
    final nd = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last.t * 1000);
    final eff = t.sleepEfficiency.value?.toDouble() ?? (nd == null ? null : d.on('efficiency', nd));
    final deep = nd == null ? null : d.on('deep', nd);
    String sleepWhy() {
      final dur = e.sleepMin;
      if (dur == null) return 'Keine Nacht erfasst.';
      final gap = dur - (e.needMin ?? 480);
      final target = e.needIsGoal ? 'deinem Ziel' : 'deinem Bedarf';
      return '${hMin(dur)}'
          '${eff == null ? '' : ' bei ${eff.round()} % Effizienz'}'
          '${deep == null ? '' : ' und ${hMin(deep)} Tiefschlaf'}'
          ' – ${gap >= 0 ? 'Ziel erreicht' : '${hMin(-gap)} unter $target'}.';
    }

    String recWhy() {
      final rc = e.recovery;
      if (rc == null) return 'Recovery ${recoveryWait(d)}.';
      final base = [
        if (rmssd != null) 'HRV ${rmssd!.round()} ms',
        if (rhr != null) 'Ruhepuls ${rhr!.round()}',
      ].join(', ');
      final verdict = rc >= 67
          ? 'gut erholt'
          : rc >= 34
              ? 'normal erholt'
              : 'wenig erholt';
      return '${base.isEmpty ? '' : '$base – '}$verdict.';
    }

    String calmWhy() {
      if (stress == null) return 'Noch kein Stresswert – kommt mit der nächsten gewerteten Nacht.';
      final s = stress!.round();
      final tag = dayHr == null ? '' : ', Puls tagsüber Ø ${dayHr!.round()}';
      return 'Stress $s von 100 in der Nacht$tag'
          '${s >= 60 ? ' – kurze Pausen helfen.' : '.'}';
    }

    final rows = [
      ('Schlaf', e.sleep, sleepWhy()),
      ('Recovery', e.recovery, recWhy()),
      ('Ruhe', e.calm, calmWhy()),
    ];
    final vals = [for (final r in rows) if (r.$2 != null) r.$2!];
    final weakest = vals.isEmpty ? null : vals.reduce(math.min);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: tileDeco(),
      child: Column(children: [
        for (var i = 0; i < rows.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: i == 0
                ? null
                : const BoxDecoration(border: Border(top: BorderSide(color: O.line))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 34,
                child: Text(_pct(rows[i].$2),
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w500, color: O.ink, fontFeatures: O.tabular)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(rows[i].$1,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: O.ink)),
                    if (rows[i].$2 != null && rows[i].$2 == weakest && weakest! < 70) ...[
                      const SizedBox(width: 7),
                      const Dot(O.orange, size: 6),
                      const SizedBox(width: 5),
                      const Text('bremst heute',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: O.orange)),
                    ],
                  ]),
                  const SizedBox(height: 3),
                  Text(rows[i].$3, style: const TextStyle(fontSize: 12, height: 1.45, color: O.ink2)),
                ]),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// "Heute passt" row: tap ticks the task off (with undo), as in the mockup.
class _FitRow extends StatelessWidget {
  final OTask t;
  final bool first;
  const _FitRow(this.t, {required this.first});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () {
          final n = NotionStore.instance;
          final lists = n.snapshot();
          final uid = n.completeTask(t);
          OToast.instance.show('In Notion abgehakt', undo: () => n.undo(uid, lists));
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration:
              first ? null : const BoxDecoration(border: Border(top: BorderSide(color: O.line))),
          child: Row(children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                  border: Border.all(color: O.ink3, width: 1.5),
                  borderRadius: BorderRadius.circular(6)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: O.ink)),
                const SizedBox(height: 2),
                Text('${t.area ?? 'Aufgabe'} · ~${effortEst(t.effort)}', style: O.small),
              ]),
            ),
            if (t.energy != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: O.pill, borderRadius: BorderRadius.circular(999)),
                child: Text(t.energy!.toUpperCase(),
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .5, color: O.ink2)),
              ),
          ]),
        ),
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
                    fontSize: 22, fontWeight: FontWeight.w500, color: O.ink, fontFeatures: O.tabular)),
            Text(unit, style: const TextStyle(fontSize: 11, color: O.ink3)),
          ],
        ),
      );
}

/// Mockup triangle: rings at 1/3, 2/3, 1; filled value polygon.
/// Corners: Schlaf top, Recovery bottom-left, Ruhe bottom-right.
class _TrianglePainter extends CustomPainter {
  final Energy e;
  _TrianglePainter(this.e);

  @override
  void paint(Canvas canvas, Size size) {
    const cx = 75.0, cy = 76.0, r = 56.0;
    const angles = [-90.0, 150.0, 30.0]; // Schlaf, Recovery, Ruhe
    Offset pt(int i, double k) {
      final a = angles[i] * math.pi / 180;
      return Offset(cx + r * k * math.cos(a), cy + r * k * math.sin(a));
    }

    Path tri(List<double> k) => Path()
      ..moveTo(pt(0, k[0]).dx, pt(0, k[0]).dy)
      ..lineTo(pt(1, k[1]).dx, pt(1, k[1]).dy)
      ..lineTo(pt(2, k[2]).dx, pt(2, k[2]).dy)
      ..close();
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(tri(const [1, 1, 1]), ring..color = O.ink.withValues(alpha: .35)..strokeWidth = 1.2);
    for (final k in const [2 / 3, 1 / 3]) {
      canvas.drawPath(tri([k, k, k]), ring..color = O.ink.withValues(alpha: .12)..strokeWidth = 1);
    }
    final vals = [e.sleep, e.recovery, e.calm];
    if (vals.any((v) => v != null)) {
      final p = tri([for (final v in vals) ((v ?? 0) / 100).clamp(0.04, 1.0)]);
      canvas.drawPath(p, Paint()..color = O.ink.withValues(alpha: .9));
      canvas.drawPath(
          p,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..strokeJoin = StrokeJoin.round
            ..color = O.ink);
    }
    void label(String t, double x, double y) {
      final tp = TextPainter(
        text: TextSpan(
            text: t,
            style: const TextStyle(
                fontSize: 9, fontWeight: FontWeight.w600, letterSpacing: .8, color: O.ink2)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, y - tp.height + 2));
    }

    label('SCHLAF', 75, 11);
    label('RECOVERY', 22, 124);
    label('RUHE', 128, 124);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) =>
      old.e.sleep != e.sleep || old.e.recovery != e.recovery || old.e.calm != e.calm;
}

// ── Woche / Monat ─────────────────────────────────────────────────────────────

const _recSpec = TrendSpec('recovery', 'Recovery', '%');
const _hrvSpec = TrendSpec('hrv', 'HRV', 'ms');
const _rhrSpec = TrendSpec('resting_hr', 'Ruhepuls', 'bpm');
const _stressSpec = TrendSpec('stress', 'Stress', '/100');

class OverviewPeriod extends StatelessWidget {
  final OpggDay day;
  final int n;
  const OverviewPeriod({super.key, required this.day, required this.n});
  @override
  Widget build(BuildContext context) {
    final days = lastDays(n);
    final energy = [for (final d in days) energyOn(day, d)];
    final avg = avgOf(energy);
    int? best;
    for (var i = 0; i < energy.length; i++) {
      if (energy[i] != null && (best == null || energy[i]! > energy[best]!)) best = i;
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
      children: [
        SectionHead(n == 7 ? 'Letzte 7 Tage' : 'Letzte 30 Tage',
            hint: '${wdDm(days.first)} – ${wdDm(days.last)}'),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
              child: SumTile('Ø Energie', avg == null ? '--' : '${avg.round()}',
                  avg == null ? recoveryWait(day).replaceFirst('lernt noch · ', 'Recovery lernt: ') : energyWord(avg).toLowerCase(),
                  bar: avg == null ? null : avg / 100, height: 118)),
          const SizedBox(width: 8),
          Expanded(
              child: SumTile(
                  'Bester Tag',
                  best == null
                      ? '--'
                      : n == 7
                          ? kWd[days[best].weekday - 1]
                          : '${days[best].day}.${days[best].month}.',
                  best == null ? 'noch keine Energie-Tage' : 'Energie ${energy[best]!.round()}',
                  height: 118)),
        ]),
        const SizedBox(height: 12),
        TrendCard(
            spec: const TrendSpec('energy', 'Energie', '/100'),
            days: days,
            values: energy,
            emptyNote: 'braucht Schlaf, Recovery und Ruhe'),
        const SizedBox(height: 12),
        TrendCard(
            spec: _recSpec,
            days: days,
            values: valuesFor(day, _recSpec, days),
            emptyNote: recoveryWait(day)),
        const SizedBox(height: 12),
        TrendCard(spec: _hrvSpec, days: days, values: valuesFor(day, _hrvSpec, days)),
        const SizedBox(height: 12),
        TrendCard(spec: _rhrSpec, days: days, values: valuesFor(day, _rhrSpec, days)),
        const SizedBox(height: 12),
        TrendCard(spec: _stressSpec, days: days, values: valuesFor(day, _stressSpec, days)),
      ],
    );
  }
}
