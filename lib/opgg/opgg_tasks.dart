// Aufgaben: open tasks from Notion with energy and effort, started ones marked
// orange. Tap a task to start it in Fokus, finish it, or open it in Notion.
// New tasks are written straight to Notion (the store).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'opgg_ai.dart' show RKind, ReportPanel, ReportPen;
import 'opgg_charts.dart';
import 'opgg_focus.dart' show FPhase, FocusStore, finishFocus;
import 'opgg_style.dart';
import 'opgg_sync.dart';
import 'opgg_toast.dart';

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

/// Effort points and rough minutes (shared with the stats below).
int effortPoints(String? e) => switch (e) { 'kurz' => 1, 'lang' => 3, _ => 2 };
int effortMinutes(String? e) => switch (e) { 'kurz' => 20, 'lang' => 150, _ => 60 };

/// Highest task energy that fits today's energy (null = unknown → all fit).
int? energyCap(double? energy) => energy == null ? null : kEnergies.indexOf(wantedLevel(energy)!);

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

class TasksPage extends StatefulWidget {
  final double? energy;
  final void Function(OTask) onStart;
  final VoidCallback onSettings, onFocus;
  const TasksPage(
      {super.key,
      this.energy,
      required this.onStart,
      required this.onSettings,
      required this.onFocus});
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  bool _fit = true; // "Passt jetzt" vs "Alle"
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && FocusStore.instance.phase != FPhase.idle) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = NotionStore.instance;
    final f = FocusStore.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([n, f]),
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
                SizedBox(width: 240, child: OButton('Einrichten', onTap: widget.onSettings, height: 46)),
              ]),
            ),
          );
        }
        final now = DateTime.now();
        final cap = energyCap(widget.energy);
        final open = suggest(n.tasks, widget.energy);
        final doneToday = [for (final t in n.done) if (t.doneAt != null && _sameDay(t.doneAt!, now)) t];
        bool fits(OTask t) => cap == null || (t.energy == null ? 1 : kEnergies.indexOf(t.energy!)) <= cap;
        final shown = [
          for (final t in open) if (!_fit || fits(t)) t,
          ...doneToday,
        ];
        final openMin = open.fold<int>(0, (a, t) => a + effortMinutes(t.effort));
        final points = doneToday.fold<int>(0, (a, t) => a + effortPoints(t.effort));
        final running = f.phase != FPhase.idle && f.taskId != null
            ? (open.where((t) => t.id == f.taskId).firstOrNull)
            : null;

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
          children: [
            Seg(
                labels: const ['Passt jetzt', 'Alle'],
                index: _fit ? 0 : 1,
                onPick: (i) => setState(() => _fit = i == 0),
                height: 40),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: _Tile('Offen', '${open.length}', '~${hMin(openMin)} Aufwand')),
              const SizedBox(width: 12),
              Expanded(child: _Tile('Heute erledigt', '${doneToday.length}', '$points Aufwandspunkte')),
            ]),
            if (running != null) ...[
              const SizedBox(height: 16),
              _RunCard(task: running, onFocus: widget.onFocus),
            ],
            const SizedBox(height: 16),
            Row(children: [
              Text(
                  _fit
                      ? (widget.energy == null
                          ? 'PASST JETZT · ENERGIE NOCH UNBEKANNT'
                          : 'PASST ZU ENERGIE ${widget.energy!.round()}')
                      : 'ALLE AUFGABEN',
                  style: O.label),
              const Spacer(),
              const Text('aus Notion', style: O.small),
            ]),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              decoration: tileDeco(),
              child: shown.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Text('Keine passenden Aufgaben. Mit + neue anlegen.', style: O.small),
                    )
                  : Column(children: [
                      for (var i = 0; i < shown.length; i++)
                        TaskRow(
                          shown[i],
                          first: i == 0,
                          done: doneToday.contains(shown[i]),
                          dim: !fits(shown[i]),
                          running: running?.id == shown[i].id,
                          onToggle: () => _toggle(shown[i], doneToday.contains(shown[i])),
                          onTap: () => _actions(context, shown[i]),
                        ),
                    ]),
            ),
            const SizedBox(height: 16),
            OButton('+ Neue Aufgabe', primary: false, height: 48, onTap: () => _add(context)),
          ],
        );
      },
    );
  }

  void _toggle(OTask t, bool isDone) {
    HapticFeedback.selectionClick();
    final n = NotionStore.instance;
    if (isDone) {
      n.reopenTask(t);
      return;
    }
    final lists = n.snapshot();
    final uid = n.completeTask(t);
    OToast.instance.show('In Notion abgehakt', undo: () => n.undo(uid, lists));
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
        widget.onStart(t);
      case 'done':
        final n = NotionStore.instance;
        final lists = n.snapshot();
        final uid = n.completeTask(t);
        OToast.instance.show('In Notion abgehakt', undo: () => n.undo(uid, lists));
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

/// Task row (mockup): checkbox, title, meta, effort dots + level + tracked
/// time, progress bar. Tapping the row opens the actions.
class TaskRow extends StatelessWidget {
  final OTask t;
  final bool first, done, dim, running;
  final VoidCallback onToggle, onTap;
  const TaskRow(this.t,
      {super.key,
      required this.first,
      required this.done,
      required this.dim,
      required this.running,
      required this.onToggle,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pts = effortPoints(t.effort);
    final prog = done ? 100 : t.progress;
    final overdue = !done && t.due != null && dueLabel(t.due!) == 'überfällig';
    final meta = [
      t.area ?? 'Aufgabe',
      if (t.due != null) 'fällig ${dueLabel(t.due!)}',
      '~${hMin(effortMinutes(t.effort))}',
    ].join(' · ');
    final tracked = [
      if (prog > 0 && !done) '$prog %',
      if (t.focusMin > 0) '${hMin(t.focusMin)} getrackt',
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: first ? null : const BoxDecoration(border: Border(top: BorderSide(color: O.line))),
        child: Row(children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggle,
            child: SizedBox(
              width: 32,
              height: 44,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: done ? O.ink : null,
                    border: done ? null : Border.all(color: O.ink3, width: 1.5),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: done ? const Icon(Icons.check, size: 14, color: O.bg) : null,
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(t.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: done ? const Color(0xFF6E6E73) : (dim ? const Color(0xFFA1A1A6) : O.ink),
                          decoration: done ? TextDecoration.lineThrough : null)),
                ),
                if (running) ...[const SizedBox(width: 8), const Dot(O.green)],
                if (!running && t.started && !done) ...[const SizedBox(width: 8), const Dot(O.orange)],
              ]),
              const SizedBox(height: 4),
              Text(meta, style: TextStyle(fontSize: 12, color: overdue ? O.red : O.ink3)),
              const SizedBox(height: 4),
              Row(children: [
                for (var k = 1; k <= 3; k++)
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 3),
                    decoration: BoxDecoration(
                        color: k <= pts ? O.ink : const Color(0xFF46464B), shape: BoxShape.circle),
                  ),
                const SizedBox(width: 5),
                if (t.energy != null)
                  Text(t.energy!.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .5, color: O.ink2)),
                if (tracked.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(tracked,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: O.ink3, fontFeatures: O.tabular)),
                  ),
                ],
              ]),
              if (prog > 0 && !done) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: prog / 100,
                    minHeight: 4,
                    backgroundColor: O.raised,
                    valueColor: const AlwaysStoppedAnimation(O.ink),
                  ),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final String label, value, sub;
  const _Tile(this.label, this.value, this.sub);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: tileDeco(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: O.small),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w500, color: O.ink, fontFeatures: O.tabular)),
          const SizedBox(height: 4),
          Text(sub, style: O.small),
        ]),
      );
}

/// The task currently in focus (mockup): state, total tracked time,
/// "Zum Fokus" and "Beenden" (asks for the progress).
class _RunCard extends StatelessWidget {
  final OTask task;
  final VoidCallback onFocus;
  const _RunCard({required this.task, required this.onFocus});
  @override
  Widget build(BuildContext context) {
    final f = FocusStore.instance;
    final paused = f.phase == FPhase.paused;
    final totalS = task.focusMin * 60 + f.studied ~/ 1000;
    final clock = '${pad2(totalS ~/ 3600)}:${pad2(totalS % 3600 ~/ 60)}:${pad2(totalS % 60)}';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      decoration: wellDeco(),
      child: Column(children: [
        Row(children: [
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(color: O.pill, borderRadius: BorderRadius.circular(999)),
            child: Row(children: [
              Dot(paused ? O.orange : O.green),
              const SizedBox(width: 7),
              Text(paused ? 'Pause' : 'Im Fokus',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: O.ink2)),
            ]),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(task.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: O.ink2)),
          ),
        ]),
        const SizedBox(height: 8),
        Text(clock,
            style: const TextStyle(
                fontSize: 44, fontWeight: FontWeight.w300, height: 1, color: O.ink, fontFeatures: O.tabular)),
        const SizedBox(height: 8),
        Text(
            '${paused ? 'Pause' : 'Im Fokus'} · '
            '${task.progress > 0 ? '${task.progress} % · ' : ''}geschätzt ~${hMin(effortMinutes(task.effort))}',
            style: O.small),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: OButton('Zum Fokus', primary: false, height: 48, onTap: onFocus)),
          const SizedBox(width: 10),
          Expanded(child: OButton('Beenden', height: 48, onTap: () => finishFocus(context))),
        ]),
      ]),
    );
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
    final r = await NotionStore.instance.createTask(
      name: name,
      energy: kEnergies[_energy],
      effort: kEfforts[_effort],
      area: _area < 0 ? null : kAreas[_area],
      due: due,
    );
    if (!mounted) return;
    final id = r.id;
    if (id != null) {
      Navigator.of(context).pop();
      OToast.instance.show('Aufgabe angelegt · in Notion',
          undo: () => NotionStore.instance.trashTask(id));
    } else {
      setState(() {
        _busy = false;
        _err = r.err;
      });
    }
  }
}

// ── Woche / Monat ─────────────────────────────────────────────────────────────


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
        final points = perDay((l) => l.fold<double>(0, (a, t) => a + effortPoints(t.effort)));
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
        final est = rated.fold<int>(0, (a, t) => a + effortMinutes(t.effort));
        final real = rated.fold<int>(0, (a, t) => a + t.focusMin);
        final dev = est == 0 ? null : ((real - est) / est * 100).round();

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
          children: [
            SectionHead(n == 7 ? 'Letzte 7 Tage' : 'Letzte 30 Tage',
                hint: '${wdDm(days.first)} – ${wdDm(days.last)}',
                trailing: ReportPen(n == 7 ? RKind.tasksWeek : RKind.tasksMonth)),
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
            ReportPanel(n == 7 ? RKind.tasksWeek : RKind.tasksMonth),
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
