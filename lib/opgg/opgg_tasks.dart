// Aufgaben: open tasks from Notion with energy and effort, started ones marked
// orange. Tap a task to start it in Fokus, finish it, or open it in Notion.
// New tasks are written straight to Notion (the store).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'opgg_charts.dart';
import 'opgg_focus.dart' show FocusStore;
import 'opgg_style.dart';
import 'opgg_sync.dart';

/// Energy level wanted for today's energy score (0–100), or null.
String? wantedLevel(double? energy) => energy == null
    ? null
    : energy >= 70
        ? 'hoch'
        : energy >= 45
            ? 'mittel'
            : 'niedrig';

/// Open tasks ordered for today: overdue/due first, then closest to today's
/// energy, short tasks first when energy is low.
List<OTask> suggest(List<OTask> all, double? energy) {
  final want = wantedLevel(energy);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  int lvl(String? e) => e == null ? 1 : kEnergies.indexOf(e).clamp(0, 2);
  int eff(String? e) => e == null ? 1 : kEfforts.indexOf(e).clamp(0, 2);
  double score(OTask t) {
    var s = 0.0;
    if (t.due != null) {
      final d = DateTime(t.due!.year, t.due!.month, t.due!.day).difference(today).inDays;
      if (d <= 0) {
        s -= 10; // overdue or today
      } else if (d <= 2) {
        s -= 4;
      }
    }
    if (want != null) s += (lvl(t.energy) - kEnergies.indexOf(want)).abs() * 3;
    if (want == 'niedrig') s += eff(t.effort);
    if (t.started) s -= 1; // finish what was started
    return s;
  }

  final list = [...all]..sort((a, b) => score(a).compareTo(score(b)));
  return list;
}

String dueLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
  if (diff < 0) return 'überfällig';
  if (diff == 0) return 'heute';
  if (diff == 1) return 'morgen';
  return wdDm(d);
}

class TasksPage extends StatelessWidget {
  final double? energy;
  final void Function(OTask) onStart;
  final VoidCallback onSettings;
  const TasksPage({super.key, this.energy, required this.onStart, required this.onSettings});

  @override
  Widget build(BuildContext context) {
    final n = NotionStore.instance;
    return ListenableBuilder(
      listenable: n,
      builder: (context, _) {
        if (!n.configured) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.check_box_outlined, size: 40, color: O.ink3),
                const SizedBox(height: 14),
                const Text('Notion verbinden',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: O.ink)),
                const SizedBox(height: 6),
                const Text('Deine Aufgaben kommen aus Notion. Einmal verbinden, '
                    'dann legt OPGG die Tabellen selbst an.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: O.ink3)),
                const SizedBox(height: 18),
                SizedBox(width: 240, child: OButton('Einrichten', onTap: onSettings, height: 46)),
              ]),
            ),
          );
        }
        final list = suggest(n.tasks, energy);
        final want = wantedLevel(energy);
        return ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
            children: [
              SectionHead('Offen',
                  hint: want == null
                      ? '${list.length} Aufgaben'
                      : 'passend zu Energie: $want zuerst'),
              const SizedBox(height: 10),
              if (list.isEmpty)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: tileDeco(),
                  child: const Text('Keine offenen Aufgaben. Mit + neue anlegen.', style: O.small),
                )
              else
                Container(
                  decoration: tileDeco(),
                  child: Column(children: [
                    for (var i = 0; i < list.length; i++) ...[
                      if (i > 0) const Divider(height: 1, thickness: 1, color: O.line, indent: 14),
                      TaskRow(list[i], onTap: () => _actions(context, list[i])),
                    ],
                  ]),
                ),
              const SizedBox(height: 16),
              OButton('+ Neue Aufgabe', primary: false, height: 48, onTap: () => _add(context)),
            ],
        );
      },
    );
  }

  Future<void> _actions(BuildContext context, OTask t) async {
    HapticFeedback.selectionClick();
    final r = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: O.tile,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.name, style: O.body, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(
                [
                  if (t.energy != null) 'Energie ${t.energy}',
                  if (t.effort != null) t.effort!,
                  if (t.progress > 0) '${t.progress} %',
                  if (t.focusMin > 0) '${hMin(t.focusMin)} fokussiert',
                ].join(' · '),
                textAlign: TextAlign.center,
                style: O.small),
            const SizedBox(height: 16),
            OButton('In Fokus starten', height: 48, onTap: () => Navigator.of(c).pop('start')),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: OButton('Erledigt',
                      primary: false, height: 46, onTap: () => Navigator.of(c).pop('done'))),
              const SizedBox(width: 8),
              Expanded(
                  child: OButton('In Notion',
                      primary: false, height: 46, onTap: () => Navigator.of(c).pop('open'))),
            ]),
          ]),
        ),
      ),
    );
    switch (r) {
      case 'start':
        onStart(t);
      case 'done':
        NotionStore.instance.completeTask(t);
      case 'open':
        if (t.url != null) {
          await launchUrl(Uri.parse(t.url!), mode: LaunchMode.externalApplication);
        }
    }
  }

  Future<void> _add(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: O.tile,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (c) => const _AddTask(),
    );
  }
}

class TaskRow extends StatelessWidget {
  final OTask t;
  final VoidCallback? onTap;
  const TaskRow(this.t, {super.key, this.onTap});
  @override
  Widget build(BuildContext context) {
    final overdue = t.due != null && dueLabel(t.due!) == 'überfällig';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        child: Row(children: [
          _EnergyBars(t.energy),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.name, style: O.body, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(
                  [
                    if (t.effort != null) t.effort!,
                    if (t.area != null) t.area!,
                    if (t.progress > 0) '${t.progress} %',
                  ].join(' · '),
                  style: O.small),
            ]),
          ),
          if (t.due != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(dueLabel(t.due!),
                  style: TextStyle(fontSize: 12, color: overdue ? O.red : O.ink3)),
            ),
          if (t.started) ...[const SizedBox(width: 8), const Dot(O.orange)],
        ]),
      ),
    );
  }
}

/// Three small bars: how much energy the task needs.
class _EnergyBars extends StatelessWidget {
  final String? energy;
  const _EnergyBars(this.energy);
  @override
  Widget build(BuildContext context) {
    final n = energy == null ? 0 : kEnergies.indexOf(energy!) + 1;
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      for (var i = 0; i < 3; i++)
        Container(
          width: 4,
          height: 7.0 + i * 4,
          margin: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
              color: i < n ? O.ink : O.raised, borderRadius: BorderRadius.circular(2)),
        ),
    ]);
  }
}

class _AddTask extends StatefulWidget {
  const _AddTask();
  @override
  State<_AddTask> createState() => _AddTaskState();
}

class _AddTaskState extends State<_AddTask> {
  final _name = TextEditingController();
  int _energy = 1, _effort = 0, _area = -1, _due = 0; // due: 0 none, 1 today, 2 tomorrow, 3 picked
  DateTime? _picked;
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Widget _row(String label, Widget child) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: O.label),
          const SizedBox(height: 6),
          child,
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 18, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Neue Aufgabe', style: O.body, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            autofocus: true,
            style: const TextStyle(color: O.ink, fontSize: 16),
            cursorColor: O.ink,
            decoration: InputDecoration(
              hintText: 'Was ist zu tun?',
              hintStyle: const TextStyle(color: O.ink3),
              filled: true,
              fillColor: O.well,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
            ),
          ),
          _row('ENERGIE',
              Seg(labels: kEnergies, index: _energy, onPick: (i) => setState(() => _energy = i), height: 34)),
          _row('AUFWAND',
              Seg(labels: kEfforts, index: _effort, onPick: (i) => setState(() => _effort = i), height: 34)),
          _row(
              'BEREICH',
              Seg(
                  labels: const ['–', ...kAreas],
                  index: _area + 1,
                  onPick: (i) => setState(() => _area = i - 1),
                  height: 34)),
          _row(
              'FÄLLIG',
              Seg(
                  labels: ['–', 'heute', 'morgen', _picked == null ? 'Datum' : wdDm(_picked!)],
                  index: _due,
                  onPick: (i) async {
                    if (i == 3) {
                      final d = await showDatePicker(
                        context: context,
                        firstDate: now,
                        lastDate: now.add(const Duration(days: 365)),
                        initialDate: _picked ?? now.add(const Duration(days: 2)),
                      );
                      if (d == null) return;
                      _picked = d;
                    }
                    setState(() => _due = i);
                  },
                  height: 34)),
          if (_err != null) ...[
            const SizedBox(height: 12),
            Text(_err!, style: const TextStyle(fontSize: 12, color: O.red), textAlign: TextAlign.center),
          ],
          const SizedBox(height: 16),
          OButton(_busy ? 'Speichere …' : 'Anlegen', height: 50, onTap: _busy ? null : _save),
        ]),
      ),
    );
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _err = 'Bitte einen Namen eingeben');
      return;
    }
    final now = DateTime.now();
    final due = switch (_due) {
      1 => now,
      2 => now.add(const Duration(days: 1)),
      3 => _picked,
      _ => null,
    };
    setState(() {
      _busy = true;
      _err = null;
    });
    final err = await NotionStore.instance.createTask(
      name: name,
      energy: kEnergies[_energy],
      effort: kEfforts[_effort],
      area: _area < 0 ? null : kAreas[_area],
      due: due,
    );
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _err = err;
      });
    }
  }
}

// ── Woche / Monat ─────────────────────────────────────────────────────────────

/// Effort points per task, and the minutes each effort roughly means.
const _points = {'kurz': 1, 'mittel': 2, 'lang': 3};
const _estMin = {'kurz': 20, 'mittel': 60, 'lang': 150};

class TasksPeriod extends StatelessWidget {
  final int n;
  const TasksPeriod({super.key, required this.n});

  static bool _same(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final store = NotionStore.instance;
    final focus = FocusStore.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([store, focus]),
      builder: (context, _) {
        final days = lastDays(n);
        final first = days.first;
        final done = [
          for (final t in store.done)
            if (t.doneAt != null && !t.doneAt!.isBefore(first)) t
        ];
        List<double?> perDay(double Function(List<OTask>) f) => [
              for (final d in days)
                () {
                  final v = f([for (final t in done) if (_same(t.doneAt!, d)) t]);
                  return v == 0 ? null : v;
                }(),
            ];
        final count = perDay((l) => l.length.toDouble());
        final points = perDay((l) => l.fold<double>(0, (a, t) => a + (_points[t.effort] ?? 0)));
        final hours = [
          for (final d in days)
            () {
              final ms = focus
                  .onDay(d)
                  .where((s) => s.taskId != null)
                  .fold<int>(0, (a, s) => a + s.studiedMs);
              return ms == 0 ? null : ms / 3600000;
            }(),
        ];
        final total = done.length;
        final pts = points.whereType<double>().fold<double>(0, (a, b) => a + b);
        // Estimate vs real: only finished tasks with an effort and tracked time.
        final rated = [for (final t in done) if (t.effort != null && t.focusMin > 0) t];
        final est = rated.fold<int>(0, (a, t) => a + (_estMin[t.effort] ?? 0));
        final real = rated.fold<int>(0, (a, t) => a + t.focusMin);
        final dev = est == 0 ? null : ((real - est) / est * 100).round();

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
          children: [
            SectionHead(n == 7 ? 'Letzte 7 Tage' : 'Letzte 30 Tage',
                hint: '${wdDm(days.first)} – ${wdDm(days.last)}'),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: SumTile('Erledigt', total == 0 ? '--' : '$total',
                      total == 0 ? 'noch keine' : '${pts.round()} Aufwandspunkte',
                      height: 118)),
              const SizedBox(width: 8),
              Expanded(
                  child: SumTile(
                      'Schätzung vs. echt',
                      dev == null ? '--' : '${dev >= 0 ? '+' : '−'}${dev.abs()} %',
                      dev == null
                          ? 'braucht erledigte Aufgaben mit Fokuszeit'
                          : dev >= 0
                              ? 'länger als geschätzt'
                              : 'schneller als geschätzt',
                      height: 118)),
            ]),
            const SizedBox(height: 12),
            TrendCard(
                spec: const TrendSpec('done', 'Erledigte Aufgaben', ''),
                days: days,
                values: count,
                emptyNote: 'noch nichts erledigt'),
            const SizedBox(height: 12),
            TrendCard(
                spec: const TrendSpec('points', 'Aufwandspunkte', 'P'),
                days: days,
                values: points,
                emptyNote: 'kurz 1 · mittel 2 · lang 3'),
            const SizedBox(height: 12),
            TrendCard(
                spec: const TrendSpec('taskh', 'Zeit an Aufgaben', 'h', dec: 1),
                days: days,
                values: hours,
                emptyNote: 'noch keine Fokuszeit an Aufgaben'),
          ],
        );
      },
    );
  }
}
