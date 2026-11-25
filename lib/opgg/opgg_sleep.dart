// Schlaf: Nacht / Wecker / Wind-down, plus Woche/Monat trends.
// The alarm goes through AppState.setAlarm (band vibration); its state comes
// from alarmArmOf so this screen and the engine can never disagree.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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
    final dur = t.sleepDuration.value;
    final need = t.sleepNeed.value;
    final eff = t.sleepEfficiency.value;
    final last = day.latest('sleep');
    final nightDay = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last.t * 1000);
    double? stage(String k) => nightDay == null ? null : day.on(k, nightDay);
    final deep = stage('deep'), light = stage('light'), rem = stage('rem');
    final stagesKnown = deep != null && light != null && rem != null;
    final total = stagesKnown ? deep + light + rem : 0.0;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHead('Letzte Nacht', hint: nightDay == null ? null : wdDm(nightDay)),
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
              child: Text(need == null ? 'Bedarf —' : 'von ${hMin(need)} Bedarf', style: O.small),
            ),
          ]),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: (dur != null && need != null && need > 0) ? (dur / need).clamp(0.0, 1.0) : 0,
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
            if (c != null) ...[Dot(c, size: 6), const SizedBox(width: 5)],
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

class _AlarmState extends State<_Alarm> {
  int? _h, _m; // picked, not yet sent
  bool _busy = false;
  String? _err;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final (armedAt, state) = alarmArmOf(app);
    final now = DateTime.now();
    final live = armedAt != null && armedAt.isAfter(now);
    final h = _h ?? (live ? armedAt.hour : 7);
    final m = _m ?? (live ? armedAt.minute : 0);
    final dirty = _h != null && (!live || armedAt.hour != _h || armedAt.minute != _m);

    final (Color dot, String status) = _err != null
        ? (O.red, _err!)
        : !live
            ? (O.grey, armedAt != null ? 'Wecker ist gelaufen' : 'Kein Wecker gestellt')
            : switch (state) {
                AlarmArmState.confirmed => (O.green, 'Band vibriert ${_when(armedAt)}'),
                AlarmArmState.pending => (O.orange, 'Wird ans Band gesendet …'),
                _ => (O.orange, 'Gestellt, Band hat nicht bestätigt'),
              };

    final wake = nextAt(h, m);
    final until = wake.difference(now);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHead('Wecker',
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Dot(dot),
            const SizedBox(width: 6),
            Text(live ? 'aktiv' : 'aus', style: O.small),
          ])),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 14),
        decoration: wellDeco(),
        child: Column(children: [
          // The time itself is the picker.
          SizedBox(
            height: 150,
            child: CupertinoTheme(
              data: const CupertinoThemeData(
                brightness: Brightness.dark,
                textTheme: CupertinoTextThemeData(
                  dateTimePickerTextStyle: TextStyle(
                      fontSize: 34, fontWeight: FontWeight.w300, color: O.ink),
                ),
              ),
              child: CupertinoDatePicker(
                key: ValueKey(_h == null ? 'armed-$h:$m' : 'edit'),
                mode: CupertinoDatePickerMode.time,
                use24hFormat: true,
                itemExtent: 44,
                initialDateTime: DateTime(2000, 1, 1, h, m),
                onDateTimeChanged: (d) => setState(() {
                  _h = d.hour;
                  _m = d.minute;
                  _err = null;
                }),
              ),
            ),
          ),
          Text('in ${until.inHours} h ${pad2(until.inMinutes % 60)} min · ${_when(wake)}',
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
        if (live) ...[
          Expanded(
            child: OButton('Aus', onTap: _busy ? null : () => _clear(app), primary: false, height: 48),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          flex: 2,
          child: OButton(
            _busy ? 'Sende …' : (live && !dirty ? 'Gestellt' : 'Wecker stellen'),
            onTap: (_busy || (live && !dirty)) ? null : () => _set(app, h, m),
            height: 48,
          ),
        ),
      ]),
      const SizedBox(height: 10),
      const Text('Das Band vibriert zur Weckzeit – auch ohne Handy in der Nähe.', style: O.small),
    ]);
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

  Future<void> _set(AppState app, int h, int m) async {
    if (!app.isConnected) {
      setState(() => _err = 'Band nicht verbunden – Band antippen, dann nochmal');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await app.setAlarm(nextAt(h, m));
      if (!mounted) return;
      setState(() {
        _h = null;
        _m = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _err = 'Band hat den Wecker nicht angenommen');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear(AppState app) async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await app.clearAlarm();
    } catch (_) {
      if (mounted) setState(() => _err = 'Konnte Wecker nicht löschen');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
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
    final need = widget.day.today.sleepNeed.value;

    DateTime? bed, start;
    if (wake != null && need != null) {
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
              : need == null
                  ? 'Schlafbedarf ist noch unbekannt – nach ein paar Nächten erscheinen die Zeiten.'
                  : 'Aus Weckzeit, ${hMin(need)} Schlafbedarf und 15 min Einschlafzeit.',
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
