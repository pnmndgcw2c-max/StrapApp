// Schlaf: Nacht / Wecker / Wind-down, plus Woche/Monat trends.
// The alarm goes through AppState.setAlarm (band vibration); its state comes
// from alarmArmOf so this screen and the engine can never disagree.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../ui2/profile/alarm.dart' show AlarmArmState, alarmArmOf;
import 'opgg_charts.dart';
import 'opgg_data.dart';
import 'opgg_style.dart';

class SleepToday extends StatefulWidget {
  final OpggDay day;
  const SleepToday({super.key, required this.day});
  @override
  State<SleepToday> createState() => _SleepTodayState();
}

class _SleepTodayState extends State<SleepToday> {
  int _sub = 0; // 0 Nacht · 1 Wecker · 2 Wind-down

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
      children: [
        Seg(
            labels: const ['Nacht', 'Wecker', 'Wind-down'],
            index: _sub,
            onPick: (i) => setState(() => _sub = i),
            height: 34),
        const SizedBox(height: 16),
        switch (_sub) {
          0 => _Night(day: widget.day),
          1 => const _Alarm(),
          _ => _WindDown(day: widget.day),
        },
      ],
    );
  }
}

// ── Nacht ────────────────────────────────────────────────────────────────────

class _Night extends StatelessWidget {
  final OpggDay day;
  const _Night({required this.day});
  @override
  Widget build(BuildContext context) {
    final t = day.today;
    final last = day.latest('sleep');
    final nightDay = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last.t * 1000);
    double? stage(String k) => nightDay == null ? null : day.on(k, nightDay);
    // The Today bundle waits ~1 h past wake before it shows the night; the
    // derive's stored night is the same measurement, so read that meanwhile.
    final dur = t.sleepDuration.value?.toDouble() ?? stage('sleep');
    final need = t.sleepNeed.value?.toDouble();
    final eff = t.sleepEfficiency.value?.toDouble() ?? stage('efficiency');
    final deep = stage('deep'), light = stage('light'), rem = stage('rem');
    final stagesKnown = deep != null && light != null && rem != null;
    final total = stagesKnown ? deep + light + rem : 0.0;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHead(nightDay == null ? 'Letzte Nacht' : nightLabel(nightDay).replaceFirst('letzte', 'Letzte'),
          hint: nightDay == null ? null : wdDm(nightDay)),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: wellDeco(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(dur == null ? '--' : hMin(dur),
                style: const TextStyle(
                    fontSize: 40, fontWeight: FontWeight.w300, color: O.ink, fontFeatures: O.tabular)),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(need == null ? 'von 8 h Ziel' : 'von ${hMin(need)} Bedarf', style: O.small),
            ),
          ]),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: dur == null ? 0 : (dur / (need ?? 480)).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: O.raised,
              valueColor: const AlwaysStoppedAnimation(O.ink),
            ),
          ),
          const SizedBox(height: 16),
          // Stage bar: only when all three stages exist — never an invisible gap.
          if (stagesKnown && total > 0) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                height: 14,
                child: Row(children: [
                  Expanded(flex: (deep / total * 1000).round(), child: Container(color: O.ink)),
                  const SizedBox(width: 2),
                  Expanded(flex: (rem / total * 1000).round(), child: Container(color: O.bar)),
                  const SizedBox(width: 2),
                  Expanded(flex: (light / total * 1000).round(), child: Container(color: O.raised)),
                ]),
              ),
            ),
            const SizedBox(height: 10),
          ],
          Row(children: [
            _kv('Tief', deep == null ? '—' : hMin(deep), O.ink),
            _kv('REM', rem == null ? '—' : hMin(rem), O.bar),
            _kv('Leicht', light == null ? '—' : hMin(light), O.raised),
            _kv('Effizienz', eff == null ? '—' : '${eff.round()} %', null),
          ]),
        ]),
      ),
      if (dur == null) ...[
        const SizedBox(height: 10),
        const Text('Noch keine Nacht erfasst. Band über Nacht tragen, morgens synchronisiert es von selbst.',
            style: O.small),
      ],
    ]);
  }

  Widget _kv(String k, String v, Color? c) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (c != null) ...[Dot(c, size: 6, blink: false), const SizedBox(width: 5)],
            Text(k, style: const TextStyle(fontSize: 11, color: O.ink3)),
          ]),
          const SizedBox(height: 2),
          Text(v,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: O.ink, fontFeatures: O.tabular)),
        ]),
      );
}

// ── Wecker ───────────────────────────────────────────────────────────────────

DateTime nextAt(int h, int m) {
  final now = DateTime.now();
  var at = DateTime(now.year, now.month, now.day, h, m);
  if (!at.isAfter(now)) at = DateTime(now.year, now.month, now.day + 1, h, m);
  return at;
}

class _Alarm extends StatefulWidget {
  const _Alarm();
  @override
  State<_Alarm> createState() => _AlarmState();
}

/// The alarm is the engine's WEEKLY SCHEDULE, not a one-shot SET_ALARM: on
/// every connect/sync the engine re-arms the next scheduled occurrence — and
/// with an empty schedule it DISABLES whatever the band holds. A one-shot set
/// from here was therefore wiped by the first reconnect during the night.
class _AlarmState extends State<_Alarm> {
  int? _h, _m; // picked, not yet saved
  Set<int>? _days; // 0=Mo..6=So, edited, not yet saved
  bool _busy = false;
  String? _err, _info;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final (armedAt, state) = alarmArmOf(app);
    final now = DateTime.now();
    final sched = app.alarmSchedule;
    final on = {for (final e in sched) if (e.enabled) e.weekday};
    final firstOn = sched.where((e) => e.enabled).firstOrNull;
    final live = armedAt != null && armedAt.isAfter(now);

    final h = _h ?? firstOn?.hour ?? (live ? armedAt.hour : 7);
    final m = _m ?? firstOn?.minute ?? (live ? armedAt.minute : 0);
    // Nothing scheduled yet: suggest the day of the next occurrence.
    final days = _days ?? (on.isNotEmpty ? on : {nextAt(h, m).weekday - 1});
    final timeDirty = firstOn == null || firstOn.hour != h || firstOn.minute != m;
    final dirty = (_days != null && !_sameSet(_days!, on)) ||
        (_h != null && timeDirty) ||
        on.isEmpty;

    final (Color dot, String status) = _err != null
        ? (O.red, _err!)
        : on.isEmpty
            ? (O.grey, 'Kein Wecker gestellt')
            : !live
                ? (O.orange, _info ?? 'Gespeichert – geht beim nächsten Verbinden ans Band')
                : switch (state) {
                    AlarmArmState.confirmed => (O.green, 'Band vibriert ${_when(armedAt)}'),
                    AlarmArmState.pending => (O.orange, 'Wird ans Band gesendet …'),
                    _ => (O.orange, 'Gestellt für ${_when(armedAt)}, Band hat nicht bestätigt'),
                  };

    final next = _nextFor(days, h, m);
    final until = next?.difference(now);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHead('Wecker',
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Dot(dot),
            const SizedBox(width: 6),
            Text(on.isEmpty ? 'aus' : 'aktiv', style: O.small),
          ])),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 14),
        decoration: wellDeco(),
        child: Column(children: [
          // The time itself is the picker: arrows step it, dragging the
          // digits up or down scrolls through the values.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _TimeUnit(
                  value: h,
                  max: 24,
                  step: 1,
                  onChanged: (v) => setState(() {
                        _h = v;
                        _m = m;
                        _err = null;
                      })),
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(':',
                    style: TextStyle(fontSize: 56, fontWeight: FontWeight.w200, color: O.ink3)),
              ),
              _TimeUnit(
                  value: m,
                  max: 60,
                  step: 5,
                  onChanged: (v) => setState(() {
                        _h = h;
                        _m = v;
                        _err = null;
                      })),
            ]),
          ),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < 7; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: GestureDetector(
                  onTap: () => setState(() {
                    final n = {...days};
                    n.contains(i) ? n.remove(i) : n.add(i);
                    _days = n;
                    _err = null;
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 38,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: days.contains(i) ? O.ink : O.pill,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(kWd[i],
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: days.contains(i) ? O.bg : O.ink3)),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 10),
          Text(
              next == null || until == null
                  ? 'Kein Tag ausgewählt'
                  : 'nächster: ${_when(next)} · in ${until.inHours} h ${pad2(until.inMinutes % 60)} min',
              style: O.small),
        ]),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Dot(dot),
        const SizedBox(width: 8),
        Expanded(child: Text(status, style: const TextStyle(fontSize: 13, color: O.ink2))),
      ]),
      const SizedBox(height: 14),
      Row(children: [
        if (on.isNotEmpty) ...[
          Expanded(
            child: OButton('Aus', onTap: _busy ? null : () => _clear(app), primary: false, height: 48),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          flex: 2,
          child: OButton(
            _busy ? 'Sende …' : (on.isEmpty ? 'Wecker stellen' : (dirty ? 'Speichern' : 'Gestellt')),
            onTap: (_busy || !dirty || days.isEmpty) ? null : () => _save(app, h, m, days, on),
            height: 48,
          ),
        ),
      ]),
      const SizedBox(height: 10),
      const Text(
          'Wiederholt sich an den markierten Tagen. Das Band vibriert auch ohne Handy in der Nähe.',
          style: O.small),
    ]);
  }

  static bool _sameSet(Set<int> a, Set<int> b) => a.length == b.length && a.containsAll(b);

  DateTime? _nextFor(Set<int> days, int h, int m) {
    if (days.isEmpty) return null;
    final now = DateTime.now();
    for (var k = 0; k <= 7; k++) {
      final t = DateTime(now.year, now.month, now.day + k, h, m);
      if (t.isAfter(now) && days.contains(t.weekday - 1)) return t;
    }
    return null;
  }

  String _when(DateTime t) {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final day = (t.year == now.year && t.month == now.month && t.day == now.day)
        ? 'heute'
        : (t.year == tomorrow.year && t.month == tomorrow.month && t.day == tomorrow.day)
            ? 'morgen'
            : wdDm(t);
    return '$day ${hhmm(t)}';
  }

  Future<void> _save(AppState app, int h, int m, Set<int> days, Set<int> on) async {
    setState(() {
      _busy = true;
      _err = null;
      _info = null;
    });
    try {
      // One time for every weekday (one band write), then flip only the days
      // whose on/off changed. The schedule is saved even when offline.
      var onBand = await app.setWakeTimeAllDays(hour: h, minute: m);
      for (var i = 0; i < 7; i++) {
        final want = days.contains(i);
        if (want != on.contains(i)) {
          onBand = await app.setScheduleDay(weekday: i, enabled: want);
        }
      }
      if (!mounted) return;
      setState(() {
        _h = null;
        _m = null;
        _days = null;
        if (!onBand) {
          _info = app.isConnected
              ? 'Gespeichert – Band hat noch nicht geantwortet'
              : 'Gespeichert – geht ans Band, sobald es verbunden ist';
        }
      });
    } catch (_) {
      if (mounted) setState(() => _err = 'Konnte den Wecker nicht speichern');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear(AppState app) async {
    if (!app.isConnected) {
      setState(() => _err = 'Band nicht verbunden – zum Ausschalten muss es erreichbar sein');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await app.clearAlarm(); // cancel-all: clears the band and the schedule
      if (mounted) setState(() => _days = null);
    } catch (_) {
      if (mounted) setState(() => _err = 'Band nicht erreicht – Wecker ist noch aktiv');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// One time digit pair with up/down arrows (tap = [step], hold = repeat)
/// and vertical drag (1 per notch) — wraps around at [max].
class _TimeUnit extends StatefulWidget {
  final int value, max, step;
  final ValueChanged<int> onChanged;
  const _TimeUnit(
      {required this.value, required this.max, required this.step, required this.onChanged});
  @override
  State<_TimeUnit> createState() => _TimeUnitState();
}

class _TimeUnitState extends State<_TimeUnit> {
  Timer? _rep;
  double _drag = 0;
  late int _v = widget.value;

  @override
  void didUpdateWidget(_TimeUnit old) {
    super.didUpdateWidget(old);
    _v = widget.value;
  }

  @override
  void dispose() {
    _rep?.cancel();
    super.dispose();
  }

  void _by(int d) {
    _v = ((_v + d) % widget.max + widget.max) % widget.max;
    HapticFeedback.selectionClick();
    widget.onChanged(_v);
  }

  /// Arrow step: snaps to the step grid first (07:03 + 5 → 07:05).
  void _arrow(int dir) {
    final s = widget.step;
    final r = _v % s;
    _by(dir > 0 ? s - r : (r == 0 ? -s : -r));
  }

  Widget _btn(IconData icon, int dir) => GestureDetector(
        onTap: () => _arrow(dir),
        onLongPressStart: (_) =>
            _rep = Timer.periodic(const Duration(milliseconds: 110), (_) => _arrow(dir)),
        onLongPressEnd: (_) => _rep?.cancel(),
        child: SizedBox(
            width: 96, height: 34, child: Icon(icon, size: 26, color: O.ink3)),
      );

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        _btn(Icons.keyboard_arrow_up_rounded, 1),
        GestureDetector(
          onVerticalDragUpdate: (d) {
            _drag += d.delta.dy;
            while (_drag <= -14) {
              _drag += 14;
              _by(1);
            }
            while (_drag >= 14) {
              _drag -= 14;
              _by(-1);
            }
          },
          onVerticalDragEnd: (_) => _drag = 0,
          child: SizedBox(
            width: 96,
            child: Text(pad2(_v),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 60,
                    fontWeight: FontWeight.w200,
                    height: 1.1,
                    color: O.ink,
                    fontFeatures: O.tabular)),
          ),
        ),
        _btn(Icons.keyboard_arrow_down_rounded, -1),
      ]);
}

// ── Wind-down ────────────────────────────────────────────────────────────────

class _WindDown extends StatefulWidget {
  final OpggDay day;
  const _WindDown({required this.day});
  @override
  State<_WindDown> createState() => _WindDownState();
}

class _WindDownState extends State<_WindDown> {
  final _done = <int>{};
  static const _steps = [
    'Bildschirme weg',
    'Licht dimmen',
    'Zimmer kühl & dunkel',
    'Morgen kurz notieren',
  ];

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final (armedAt, _) = alarmArmOf(app);
    final now = DateTime.now();
    final wake = (armedAt != null && armedAt.isAfter(now)) ? armedAt : null;
    final learned = widget.day.today.sleepNeed.value;
    final need = learned ?? 480; // 8 h goal until OpenStrap has learned the need

    DateTime? bed, start;
    if (wake != null) {
      // +15 min to fall asleep, wind-down 45 min before bed.
      bed = wake.subtract(Duration(minutes: need.round() + 15));
      start = bed.subtract(const Duration(minutes: 45));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionHead('Wind-down', hint: 'nicht getrackt'),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: wellDeco(),
        child: Row(children: [
          _big('Start', start == null ? '--:--' : hhmm(start)),
          _big('Ins Bett', bed == null ? '--:--' : hhmm(bed)),
          _big('Wecker', wake == null ? '--:--' : hhmm(wake)),
        ]),
      ),
      const SizedBox(height: 8),
      Text(
          wake == null
              ? 'Stell einen Wecker, dann rechnet OPGG die Zeiten aus deinem Schlafbedarf.'
              : 'Aus Weckzeit, ${hMin(need)} ${learned == null ? 'Schlafziel' : 'Schlafbedarf'} und 15 min Einschlafzeit.',
          style: O.small),
      const SizedBox(height: 18),
      for (var i = 0; i < _steps.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _done.contains(i) ? _done.remove(i) : _done.add(i)),
            child: Ink(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: tileDeco(),
              child: Row(children: [
                Icon(_done.contains(i) ? Icons.check_circle : Icons.circle_outlined,
                    size: 20, color: _done.contains(i) ? O.ink : O.ink3),
                const SizedBox(width: 12),
                Text(_steps[i],
                    style: O.body.copyWith(
                        color: _done.contains(i) ? O.ink3 : O.ink,
                        decoration: _done.contains(i) ? TextDecoration.lineThrough : null)),
              ]),
            ),
          ),
        ),
    ]);
  }

  Widget _big(String k, String v) => Expanded(
        child: Column(children: [
          Text(k, style: O.small),
          const SizedBox(height: 4),
          Text(v,
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w400, color: O.ink, fontFeatures: O.tabular)),
        ]),
      );
}

// ── Woche / Monat ─────────────────────────────────────────────────────────────

double _h(double m) => m / 60;
const _sleepSpec = TrendSpec('sleep', 'Schlaf', 'h', dec: 1, map: _h, goal: 8, goalLabel: '8 h');
const _deepSpec = TrendSpec('deep', 'Tiefschlaf', 'h', dec: 1, map: _h);
const _remSpec = TrendSpec('rem', 'REM', 'h', dec: 1, map: _h);

class SleepPeriod extends StatelessWidget {
  final OpggDay day;
  final int n;
  const SleepPeriod({super.key, required this.day, required this.n});
  @override
  Widget build(BuildContext context) {
    final days = lastDays(n);
    final sl = valuesFor(day, _sleepSpec, days);
    final avg = avgOf(sl);
    final nights = sl.whereType<double>().length;
    final hit = sl.whereType<double>().where((v) => v >= 8).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
      children: [
        SectionHead(n == 7 ? 'Letzte 7 Nächte' : 'Letzte 30 Nächte',
            hint: '${wdDm(days.first)} – ${wdDm(days.last)}'),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
              child: SumTile('Ø Schlaf', avg == null ? '--' : de(avg, 1), 'h pro Nacht',
                  bar: avg == null ? null : avg / 8, height: 118)),
          const SizedBox(width: 8),
          Expanded(
              child: SumTile('Ziel 8 h', nights == 0 ? '--' : '$hit/$nights', 'Nächte erreicht',
                  bar: nights == 0 ? null : hit / nights, height: 118)),
        ]),
        const SizedBox(height: 12),
        TrendCard(spec: _sleepSpec, days: days, values: sl),
        const SizedBox(height: 12),
        TrendCard(spec: _deepSpec, days: days, values: valuesFor(day, _deepSpec, days)),
        const SizedBox(height: 12),
        TrendCard(spec: _remSpec, days: days, values: valuesFor(day, _remSpec, days)),
      ],
    );
  }
}
