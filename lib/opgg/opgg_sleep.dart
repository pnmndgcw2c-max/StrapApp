// Schlaf: Nacht / Wecker / Wind-down, plus Woche/Monat trends.
// The alarm goes through AppState.setAlarm (band vibration); its state comes
// from alarmArmOf so this screen and the engine can never disagree.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/prefs.dart';
import '../ui2/profile/alarm.dart' show AlarmArmState, alarmArmOf;
import 'opgg_charts.dart';
import 'opgg_data.dart';
import 'opgg_overview.dart' show Energy;
import 'opgg_style.dart';

class SleepToday extends StatelessWidget {
  final OpggDay day;
  final int sub; // 0 Nacht · 1 Wecker · 2 Wind-down
  final ValueChanged<int> onSub;
  const SleepToday({super.key, required this.day, required this.sub, required this.onSub});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
      children: [
        Seg(labels: const ['Nacht', 'Wecker', 'Wind-down'], index: sub, onPick: onSub, height: 34),
        const SizedBox(height: 16),
        switch (sub) {
          0 => _Night(day: day),
          1 => _Alarm(day: day, onWind: () => onSub(2)),
          _ => _WindDown(day: day),
        },
      ],
    );
  }
}

/// Sleep need if OpenStrap has learned it, else Jonas' 8 h goal (minutes).
double needOrGoal(OpggDay d) => d.today.sleepNeed.value?.toDouble() ?? 480;

/// Next armed alarm in the future, or null.
DateTime? nextAlarm(AppState app) {
  final (at, _) = alarmArmOf(app);
  return at != null && at.isAfter(DateTime.now()) ? at : null;
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

    final st = t.status;
    final now = DateTime.now();
    final shownToday = nightDay != null &&
        nightDay.year == now.year &&
        nightDay.month == now.month &&
        nightDay.day == now.day;
    // OpenStrap still holds tonight's night back (about an hour past wake).
    final evaluating = !shownToday &&
        st != null &&
        (st.overnightBuilding || st.overnightState == 'provisional');
    final n = day.night;
    final range = n == null
        ? null
        : '${hhmm(DateTime.fromMillisecondsSinceEpoch(n.onset * 1000))} – '
            '${hhmm(DateTime.fromMillisecondsSinceEpoch(n.wake * 1000))}';
    final goal = need ?? 480;
    final gap = dur == null ? null : dur - goal;
    double? nightVal(String k, num? today) => today?.toDouble() ?? (nightDay == null ? null : day.on(k, nightDay));
    final nHrv = nightVal('hrv', t.hrv?.rmssd), nRhr = nightVal('resting_hr', t.restingHr.value);
    final nResp = nightVal('resp_rate', t.resp?.value);

    if (evaluating && dur == null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: wellDeco(),
        child: const Row(children: [
          Dot(O.orange),
          SizedBox(width: 10),
          Expanded(
            child: Text('Nacht wird noch ausgewertet – sie erscheint etwa eine Stunde nach dem Aufwachen.',
                style: TextStyle(fontSize: 13, color: O.ink2)),
          ),
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHead(nightDay == null ? 'Letzte Nacht' : nightLabel(nightDay).replaceFirst('letzte', 'Letzte'),
          hint: range ?? (nightDay == null ? null : wdDm(nightDay))),
      if (evaluating) ...[
        const SizedBox(height: 6),
        const Row(children: [
          Dot(O.orange, size: 6),
          SizedBox(width: 6),
          Text('Heutige Nacht wird noch ausgewertet', style: O.small),
        ]),
      ],
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
            const Spacer(),
            if (gap != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(gap >= 0 ? 'Ziel erreicht' : '−${hMin(-gap)} zum Ziel',
                    style: TextStyle(fontSize: 13, color: gap >= 0 ? O.green : O.ink2)),
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
      const SizedBox(height: 10),
      Row(children: [
        for (final v in [
          ('HRV nachts', nHrv?.round().toString(), 'ms'),
          ('Ruhepuls', nRhr?.round().toString(), 'bpm'),
          ('Atmung', nResp == null ? null : de(nResp, 1), '/min'),
        ]) ...[
          if (v.$1 != 'HRV nachts') const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: tileDeco(),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(v.$1, style: O.small),
                const SizedBox(height: 3),
                Text(v.$2 ?? '—',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w500, color: O.ink, fontFeatures: O.tabular)),
                Text(v.$3, style: const TextStyle(fontSize: 11, color: O.ink3)),
              ]),
            ),
          ),
        ],
      ]),
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
  final OpggDay day;
  final VoidCallback onWind;
  const _Alarm({required this.day, required this.onWind});
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
  int? _win; // 0 = fest, else smart window in minutes (edited, not yet saved)
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
    final savedWin = firstOn?.smartWindowMinutes ?? 0;
    final win = _win ?? savedWin;
    final dirty = (_days != null && !_sameSet(_days!, on)) ||
        (_h != null && timeDirty) ||
        (_win != null && _win != savedWin) ||
        on.isEmpty;

    final (Color dot, String status) = _err != null
        ? (O.red, _err!)
        : on.isEmpty
            ? (O.grey, 'Kein Wecker gestellt')
            : !live
                ? (O.orange, _info ?? 'Gespeichert – geht beim nächsten Verbinden ans Band')
                : switch (state) {
                    AlarmArmState.confirmed => (
                        O.green,
                        savedWin > 0
                            ? 'Weckt in leichtem Schlaf ab '
                                '${hhmm(armedAt.subtract(Duration(minutes: savedWin)))} · spätestens ${_when(armedAt)}'
                            : 'Band vibriert ${_when(armedAt)}'
                      ),
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
      Seg(
          labels: const ['Fest', 'Smart'],
          index: win > 0 ? 1 : 0,
          onPick: (i) => setState(() => _win = i == 0 ? 0 : (savedWin > 0 ? savedWin : 30)),
          height: 34),
      if (win > 0) ...[
        const SizedBox(height: 12),
        const Text('IN LEICHTEM SCHLAF, BIS ZU … FRÜHER', style: O.label),
        const SizedBox(height: 8),
        Row(children: [
          for (final w in const [15, 30, 45]) ...[
            if (w != 15) const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _win = w),
                child: Container(
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: win == w ? O.ink : O.pill, borderRadius: BorderRadius.circular(10)),
                  child: Text('$w min',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: win == w ? O.bg : O.ink2)),
                ),
              ),
            ),
          ],
        ]),
      ],
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
            onTap: (_busy || !dirty || days.isEmpty) ? null : () => _save(app, h, m, days, on, win),
            height: 48,
          ),
        ),
      ]),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        decoration: tileDeco(),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Für ${hMin(needOrGoal(widget.day))} Schlaf ins Bett um', style: O.small),
              Text(
                  next == null
                      ? '--:--'
                      : hhmm(next.subtract(Duration(minutes: needOrGoal(widget.day).round()))),
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w500, color: O.ink, fontFeatures: O.tabular)),
            ]),
          ),
          SizedBox(
              width: 120,
              child: OButton('Wind-down', primary: false, height: 44, onTap: widget.onWind)),
        ]),
      ),
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

  Future<void> _save(AppState app, int h, int m, Set<int> days, Set<int> on, int win) async {
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
        final cur = app.alarmSchedule.where((e) => e.weekday == i).firstOrNull;
        if (want != on.contains(i) || (want && (cur?.smartWindowMinutes ?? 0) != win)) {
          onBand = await app.setScheduleDay(
              weekday: i, enabled: want, smartWindowMinutes: want ? win : null);
        }
      }
      if (!mounted) return;
      setState(() {
        _h = null;
        _m = null;
        _days = null;
        _win = null;
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

/// Wind-down (mockup): phase with countdown to wind-down start / bedtime,
/// a four-step routine (ticked per evening, not tracked), and a 4-minute
/// breathing exercise with the band's live pulse.
class _WindDownState extends State<_WindDown> {
  Timer? _tick;
  int? _breath; // epoch ms the breathing started
  AppState? _app;

  static String _dayKey() {
    // An evening's routine belongs to the night: before 6 am still counts as yesterday.
    final n = DateTime.now().subtract(const Duration(hours: 6));
    return 'opgg_wd_${n.year}${pad2(n.month)}${pad2(n.day)}';
  }

  Set<String> get _done => Prefs.getString(_dayKey(), '').split(',').where((e) => e.isNotEmpty).toSet();

  void _toggle(String id) {
    final d = _done;
    d.contains(id) ? d.remove(id) : d.add(id);
    Prefs.setString(_dayKey(), d.join(','));
    HapticFeedback.selectionClick();
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    if (_breath != null) _app?.releaseLiveHrView();
    super.dispose();
  }

  String _clock(Duration d) {
    final s = d.inSeconds.clamp(0, 359999);
    return '${pad2(s ~/ 3600)}:${pad2(s % 3600 ~/ 60)}:${pad2(s % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final now = DateTime.now();
    final wake = nextAlarm(app);
    final need = needOrGoal(widget.day);
    final bed = wake?.subtract(Duration(minutes: need.round()));
    final start = bed?.subtract(const Duration(minutes: 45));

    final String phase, clock, sub;
    final Color dot;
    if (bed == null || start == null) {
      phase = 'Kein Wecker';
      clock = '--:--:--';
      sub = 'Stell einen Wecker, dann rechnet OPGG Wind-down und Bettzeit aus.';
      dot = O.grey;
    } else if (now.isBefore(start)) {
      phase = 'Bereit';
      clock = _clock(start.difference(now));
      sub = 'Wind-down ab ${hhmm(start)} · Bett um ${hhmm(bed)}';
      dot = O.grey;
    } else if (now.isBefore(bed)) {
      phase = 'Läuft';
      clock = _clock(bed.difference(now));
      sub = 'Noch bis zum Bett um ${hhmm(bed)}';
      dot = O.green;
    } else {
      phase = 'Schlafenszeit';
      clock = '00:00:00';
      sub = 'Ab ins Bett – der Wecker steht';
      dot = O.orange;
    }

    final calm = Energy.of(widget.day).calm;
    final bEl = _breath == null ? 0 : now.millisecondsSinceEpoch - _breath!;
    final bDone = bEl >= 240000;
    final inhale = (bEl ~/ 4000) % 2 == 0;
    final hr = app.isConnected ? app.liveHr : null;
    final done = _done;
    final routine = [
      ('lap', 'Laptop runterfahren',
          'Shutdown Timer${bed == null ? '' : ' · ${hhmm(bed.subtract(const Duration(minutes: 30)))}'}'),
      ('plan', 'Morgen planen', 'Aufgaben in Notion nach Energie sortieren'),
      ('phone', 'Handy weglegen', bed == null ? 'vor dem Schlafen' : 'ab ${hhmm(bed.subtract(const Duration(minutes: 15)))}'),
      ('br', 'Atmen', '4 min · Puls vom Band'),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        decoration: wellDeco(),
        child: Column(children: [
          Row(children: [
            Dot(dot),
            const SizedBox(width: 7),
            Text(phase, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: O.ink2)),
            const Spacer(),
            Text('Ruhe ${calm == null ? '—' : calm.round()}', style: O.small),
          ]),
          const SizedBox(height: 14),
          if (_breath == null) ...[
            Text(clock,
                style: TextStyle(
                    fontSize: 54,
                    fontWeight: FontWeight.w200,
                    height: 1,
                    fontFeatures: O.tabular,
                    color: phase == 'Schlafenszeit' ? const Color(0xFF46464B) : O.ink)),
            const SizedBox(height: 8),
            Text(sub, style: O.small, textAlign: TextAlign.center),
          ] else ...[
            SizedBox(
              height: 130,
              child: Center(
                child: AnimatedScale(
                  scale: bDone ? .55 : (inhale ? 1 : .55),
                  duration: const Duration(milliseconds: 3800),
                  curve: Curves.easeInOut,
                  child: Container(
                    width: 104,
                    height: 104,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                          center: Alignment(0, -.3), colors: [O.ink, Color(0xFFC7C7CC)]),
                      boxShadow: [BoxShadow(color: Color(0x2EFFFFFF), blurRadius: 40)],
                    ),
                  ),
                ),
              ),
            ),
            Text(
                '${bDone ? 'Fertig' : inhale ? 'Einatmen' : 'Ausatmen'} · noch '
                '${(240 - bEl ~/ 1000).clamp(0, 240) ~/ 60}:${pad2((240 - bEl ~/ 1000).clamp(0, 240) % 60)}'
                '${hr == null ? '' : ' · Puls $hr'}',
                style: const TextStyle(fontSize: 13, color: O.ink2)),
          ],
        ]),
      ),
      const SizedBox(height: 10),
      OButton(
        _breath == null ? 'Atemübung starten' : (bDone ? 'Fertig – abhaken' : 'Atmen beenden'),
        height: 58,
        primary: _breath == null || bDone,
        onTap: () {
          setState(() {
            if (_breath == null) {
              _breath = now.millisecondsSinceEpoch;
              _app?.retainLiveHrView();
            } else {
              if (bDone && !_done.contains('br')) _toggle('br');
              _breath = null;
              _app?.releaseLiveHrView();
            }
          });
        },
      ),
      const SizedBox(height: 18),
      SectionHead('Routine', hint: '${done.length.clamp(0, 4)}/4'),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        decoration: tileDeco(),
        child: Column(children: [
          for (var i = 0; i < routine.length; i++)
            InkWell(
              onTap: () => _toggle(routine[i].$1),
              child: Container(
                constraints: const BoxConstraints(minHeight: 52),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration:
                    i == 0 ? null : const BoxDecoration(border: Border(top: BorderSide(color: O.line))),
                child: Row(children: [
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: done.contains(routine[i].$1) ? O.ink : null,
                      border: done.contains(routine[i].$1) ? null : Border.all(color: O.ink3, width: 1.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: done.contains(routine[i].$1)
                        ? const Icon(Icons.check, size: 14, color: O.bg)
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(routine[i].$2,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: done.contains(routine[i].$1) ? const Color(0xFF6E6E73) : O.ink,
                              decoration: done.contains(routine[i].$1) ? TextDecoration.lineThrough : null)),
                      const SizedBox(height: 2),
                      Text(routine[i].$3, style: O.small),
                    ]),
                  ),
                ]),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 10),
      const Text('Wird nicht getrackt – nur für dich, jeden Abend neu.', style: O.small),
    ]);
  }
}

// ── Woche / Monat ─────────────────────────────────────────────────────────────

double _h(double m) => m / 60;
const _sleepSpec = TrendSpec('sleep', 'Schlafdauer', 'h', dec: 1, map: _h, goal: 8, goalLabel: '8 h');
const _deepSpec = TrendSpec('deep', 'Tiefschlaf', 'h', dec: 1, map: _h);
const _hrvSpec = TrendSpec('hrv', 'HRV nachts', 'ms');
const _rhrSpec = TrendSpec('resting_hr', 'Ruhepuls nachts', 'bpm');

class SleepPeriod extends StatelessWidget {
  final OpggDay day;
  final int n;
  const SleepPeriod({super.key, required this.day, required this.n});
  @override
  Widget build(BuildContext context) {
    final days = lastDays(n);
    final sl = valuesFor(day, _sleepSpec, days); // hours
    final avg = avgOf(sl);
    final goalH = needOrGoal(day) / 60;
    // Schlafschuld: what the recorded nights fell short of the goal, summed.
    final nights = sl.whereType<double>().toList();
    final debt = nights.fold<double>(0, (a, v) => a + (v < goalH ? goalH - v : 0));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
      children: [
        SectionHead(n == 7 ? 'Letzte 7 Nächte' : 'Letzte 30 Nächte',
            hint: '${wdDm(days.first)} – ${wdDm(days.last)}'),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
              child: SumTile('Ø Schlaf', avg == null ? '--' : de(avg, 1), 'h pro Nacht',
                  bar: avg == null ? null : avg / goalH, height: 118)),
          const SizedBox(width: 8),
          Expanded(
              child: SumTile('Schlafschuld', nights.isEmpty ? '--' : hMin(debt * 60),
                  nights.isEmpty ? 'noch keine Nächte' : 'unter Ziel · ${nights.length} Nächte',
                  height: 118)),
        ]),
        const SizedBox(height: 12),
        TrendCard(spec: _sleepSpec, days: days, values: sl),
        const SizedBox(height: 12),
        TrendCard(spec: _deepSpec, days: days, values: valuesFor(day, _deepSpec, days)),
        const SizedBox(height: 12),
        TrendCard(spec: _hrvSpec, days: days, values: valuesFor(day, _hrvSpec, days)),
        const SizedBox(height: 12),
        TrendCard(spec: _rhrSpec, days: days, values: valuesFor(day, _rhrSpec, days)),
      ],
    );
  }
}
