// Fokus: learn/work sessions with pause tracking and a pause reminder that
// buzzes the band. The running session is persisted on every change so an
// iOS kill/relaunch resumes it; all times are wall-clock timestamps, never
// tick counts. Finished sessions go to a local log (Notion sync: Etappe 2b).
//
// Average HR of a session is read afterwards from the band's own 1 Hz data
// (LocalDb.hrSamplesInRange) once it has synced — until then "wartet auf Band".

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/db.dart' show LocalDb;
import '../state/app_state.dart';
import '../state/prefs.dart';
import 'opgg_charts.dart';
import 'opgg_style.dart';

// ── model ────────────────────────────────────────────────────────────────────

enum FPhase { idle, running, paused }

class FocusSession {
  final String id;
  final String type; // 'learn' | 'work'
  final String? title;
  final String? taskId;
  final int start, end; // epoch ms
  final int studiedMs, breakMs, breaks;
  final int? progress; // % reported for a linked task
  const FocusSession({
    required this.id,
    required this.type,
    this.title,
    this.taskId,
    required this.start,
    required this.end,
    required this.studiedMs,
    required this.breakMs,
    required this.breaks,
    this.progress,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type,
        'title': title,
        'taskId': taskId,
        'start': start,
        'end': end,
        'studiedMs': studiedMs,
        'breakMs': breakMs,
        'breaks': breaks,
        'progress': progress,
      };

  static FocusSession? fromJson(Object? j) {
    if (j is! Map) return null;
    int i(String k) => (j[k] as num?)?.toInt() ?? 0;
    return FocusSession(
      id: j['id']?.toString() ?? '${i('start')}',
      type: j['type'] == 'work' ? 'work' : 'learn',
      title: j['title'] as String?,
      taskId: j['taskId'] as String?,
      start: i('start'),
      end: i('end'),
      studiedMs: i('studiedMs'),
      breakMs: i('breakMs'),
      breaks: i('breaks'),
      progress: (j['progress'] as num?)?.toInt(),
    );
  }

  String get label => title ?? (type == 'learn' ? 'Lernen' : 'Arbeit');
}

/// Process-wide focus state (one running session at most).
class FocusStore extends ChangeNotifier {
  FocusStore._() {
    _load();
  }
  static final FocusStore instance = FocusStore._();

  static const _kRun = 'opgg_focus_run';
  static const _kLog = 'opgg_focus_log';
  static const _kType = 'opgg_focus_type';
  static const _kRemind = 'opgg_focus_remind'; // -1 auto, 0 off, else minutes

  FPhase phase = FPhase.idle;
  String type = 'learn';
  int startedAt = 0, lastResume = 0, studyMs = 0, breakMs = 0, breaks = 0;
  int? pauseStart;
  String? taskId, taskTitle;
  int remind = -1;
  int _buzzedBlock = 0; // reminder blocks already buzzed since lastResume
  List<FocusSession> log = [];

  /// Set by the shell: buzzes the band (best-effort, never throws).
  Future<void> Function()? buzz;
  Timer? _watch;

  void _load() {
    type = Prefs.getString(_kType, 'learn') == 'work' ? 'work' : 'learn';
    remind = Prefs.getInt(_kRemind, -1);
    try {
      final raw = jsonDecode(Prefs.getString(_kLog, '[]'));
      log = [
        if (raw is List)
          for (final e in raw)
            if (FocusSession.fromJson(e) case final s?) s,
      ];
    } catch (_) {
      log = [];
    }
    try {
      final r = Prefs.getString(_kRun, '');
      if (r.isNotEmpty) {
        final j = jsonDecode(r) as Map;
        phase = j['phase'] == 'paused' ? FPhase.paused : FPhase.running;
        type = j['type'] == 'work' ? 'work' : 'learn';
        startedAt = (j['startedAt'] as num).toInt();
        lastResume = (j['lastResume'] as num).toInt();
        studyMs = (j['studyMs'] as num).toInt();
        breakMs = (j['breakMs'] as num).toInt();
        breaks = (j['breaks'] as num).toInt();
        pauseStart = (j['pauseStart'] as num?)?.toInt();
        taskId = j['taskId'] as String?;
        taskTitle = j['taskTitle'] as String?;
        _buzzedBlock = (j['buzzed'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {
      phase = FPhase.idle;
    }
    _arm();
  }

  void _saveRun() {
    Prefs.setString(
        _kRun,
        phase == FPhase.idle
            ? ''
            : jsonEncode({
                'phase': phase.name,
                'type': type,
                'startedAt': startedAt,
                'lastResume': lastResume,
                'studyMs': studyMs,
                'breakMs': breakMs,
                'breaks': breaks,
                'pauseStart': pauseStart,
                'taskId': taskId,
                'taskTitle': taskTitle,
                'buzzed': _buzzedBlock,
              }));
  }

  void _saveLog() {
    // Keep ~100 days locally; Notion is the long-term store.
    final cut = DateTime.now().subtract(const Duration(days: 100)).millisecondsSinceEpoch;
    log = [for (final s in log) if (s.end >= cut) s];
    Prefs.setString(_kLog, jsonEncode([for (final s in log) s.toJson()]));
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;
  int get studied => studyMs + (phase == FPhase.running ? _now - lastResume : 0);
  int get curBreak => phase == FPhase.paused && pauseStart != null ? _now - pauseStart! : 0;
  int get sinceResume => phase == FPhase.running ? _now - lastResume : 0;

  void setType(String t) {
    if (phase != FPhase.idle) return; // a running session keeps its type
    type = t;
    Prefs.setString(_kType, t);
    notifyListeners();
  }

  void setRemind(int v) {
    remind = v;
    Prefs.setInt(_kRemind, v);
    // Blocks already past under the new interval count as handled — changing
    // the setting must not fire a burst of buzzes.
    final m = remindMin(energy);
    _buzzedBlock = m <= 0 ? 0 : sinceResume ~/ (m * 60000);
    _saveRun();
    notifyListeners();
  }

  /// Reminder interval in minutes (0 = off). Auto follows today's energy;
  /// without an energy value it uses the classic 50 min.
  int remindMin(double? energy) {
    if (remind >= 0) return remind;
    return autoBlock(energy);
  }

  static int autoBlock(double? energy) => energy == null
      ? 50
      : energy >= 70
          ? 50
          : energy >= 45
              ? 40
              : 25;

  double? energy; // set by the screen from today's triangle

  void primary() {
    final t = _now;
    switch (phase) {
      case FPhase.idle:
        phase = FPhase.running;
        startedAt = t;
        lastResume = t;
        studyMs = 0;
        breakMs = 0;
        breaks = 0;
        pauseStart = null;
        _buzzedBlock = 0;
      case FPhase.running:
        phase = FPhase.paused;
        studyMs += t - lastResume;
        pauseStart = t;
        breaks++;
      case FPhase.paused:
        phase = FPhase.running;
        breakMs += t - (pauseStart ?? t);
        pauseStart = null;
        lastResume = t;
        _buzzedBlock = 0;
    }
    _saveRun();
    _arm();
    notifyListeners();
  }

  /// Ends the session and logs it. Returns the logged session.
  FocusSession? finish({int? progress}) {
    if (phase == FPhase.idle) return null;
    final t = _now;
    final s = FocusSession(
      id: '$startedAt',
      type: type,
      title: taskTitle,
      taskId: taskId,
      start: startedAt,
      end: t,
      studiedMs: studied,
      breakMs: breakMs + curBreak,
      breaks: breaks,
      progress: progress,
    );
    // Under a minute is a mis-tap, not a session.
    if (s.studiedMs >= 60000) {
      log = [...log, s];
      _saveLog();
    }
    phase = FPhase.idle;
    taskId = null;
    taskTitle = null;
    pauseStart = null;
    _saveRun();
    _arm();
    notifyListeners();
    return s;
  }

  // ── pause reminder ──
  // A light watchdog while running: buzz the band once per reminder block.
  // It runs as long as iOS keeps the app alive (the band link usually does);
  // when the app was suspended the buzz comes on the next wake-up.
  void _arm() {
    _watch?.cancel();
    _watch = null;
    if (phase != FPhase.running) return;
    _watch = Timer.periodic(const Duration(seconds: 15), (_) => check());
    check();
  }

  /// Block number now due (0 = none yet).
  int get dueBlock {
    final m = remindMin(energy);
    if (m <= 0 || phase != FPhase.running) return 0;
    return sinceResume ~/ (m * 60000);
  }

  bool get reminderDue => dueBlock > 0 && !_dismissed.contains('$lastResume:$dueBlock');
  final _dismissed = <String>{};

  void dismissReminder() {
    _dismissed.add('$lastResume:$dueBlock');
    notifyListeners();
  }

  void check() {
    final b = dueBlock;
    if (b > _buzzedBlock) {
      _buzzedBlock = b;
      _saveRun();
      unawaited(buzz?.call());
      HapticFeedback.heavyImpact();
      notifyListeners();
    }
  }

  // ── stats ──
  List<FocusSession> onDay(DateTime day) => [
        for (final s in log)
          if (_sameDay(DateTime.fromMillisecondsSinceEpoch(s.start), day)) s,
      ];

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

String _clock(int ms) {
  final s = ms ~/ 1000;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  return h > 0 ? '$h:${pad2(m)}:${pad2(sec)}' : '${pad2(m)}:${pad2(sec)}';
}

String _dur(int ms) => hMin(ms / 60000);

// ── Heute ────────────────────────────────────────────────────────────────────

class FocusToday extends StatefulWidget {
  final double? energy;
  const FocusToday({super.key, this.energy});
  @override
  State<FocusToday> createState() => _FocusTodayState();
}

class _FocusTodayState extends State<FocusToday> {
  final f = FocusStore.instance;
  Timer? _tick;
  AppState? _app;
  bool _menu = false;
  String? _note;
  Timer? _noteT;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _app!.retainLiveHrView();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && f.phase != FPhase.idle) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _noteT?.cancel();
    _app?.releaseLiveHrView();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ListenableBuilder(
      listenable: f,
      builder: (context, _) {
        f.energy = widget.energy;
        final rm = f.remindMin(widget.energy);
        final since = f.sinceResume;
        final left = rm > 0 ? rm * 60000 - since : null;
        final rState = rm == 0 || f.phase != FPhase.running
            ? 'idle'
            : left! <= 0
                ? 'due'
                : left <= 5 * 60000
                    ? 'soon'
                    : 'ok';
        final rColor = switch (rState) {
          'ok' => O.green,
          'soon' => O.orange,
          'due' => O.red,
          _ => O.grey,
        };
        final rLabel = rm == 0
            ? 'Erinnerung aus'
            : rState == 'due'
                ? 'Pause fällig'
                : rState == 'idle'
                    ? 'Pause nach $rm min'
                    : 'Pause in ${(left! / 60000).ceil()} min';
        final sub = switch (f.phase) {
          FPhase.running => rm == 0
              ? 'Ohne Pausen-Erinnerung'
              : left! <= 0
                  ? 'Zeit für eine Pause · ${_dur(since)} am Stück'
                  : 'Pause in ${_dur(left)}',
          FPhase.paused => 'Pause seit ${_dur(f.curBreak)}',
          FPhase.idle => widget.energy == null
              ? 'Pausen-Erinnerung nach ${FocusStore.autoBlock(null)} min'
              : 'Empfohlen heute: ${FocusStore.autoBlock(widget.energy)}-min-Blöcke '
                  '(Energie ${widget.energy!.round()})',
        };
        final hr = f.phase != FPhase.idle && app.isConnected ? app.liveHr : null;
        final today = f.onDay(DateTime.now()).reversed.toList();
        final todayMs =
            today.fold<int>(0, (a, s) => a + s.studiedMs) + (f.phase == FPhase.idle ? 0 : f.studied);

        return Stack(children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
            children: [
              Seg(
                labels: const ['Lernen', 'Arbeit'],
                index: f.type == 'learn' ? 0 : 1,
                onPick: f.phase == FPhase.idle ? (i) => f.setType(i == 0 ? 'learn' : 'work') : (_) {},
                height: 34,
              ),
              const SizedBox(height: 14),
              if (f.reminderDue) ...[
                _Nudge(
                  text: '${_dur(since)} am Stück${f.taskTitle == null ? '' : ' · ${f.taskTitle}'}',
                  onPause: () {
                    f.dismissReminder();
                    f.primary();
                  },
                  onDismiss: f.dismissReminder,
                ),
                const SizedBox(height: 10),
              ],
              Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                decoration: wellDeco(),
                child: Column(children: [
                  Row(children: [
                    Dot(switch (f.phase) {
                      FPhase.running => O.green,
                      FPhase.paused => O.orange,
                      FPhase.idle => O.grey,
                    }),
                    const SizedBox(width: 7),
                    Text(
                        switch (f.phase) {
                          FPhase.running => f.type == 'learn' ? 'Lernen' : 'Arbeiten',
                          FPhase.paused => 'Pause',
                          FPhase.idle => 'Bereit',
                        },
                        style: O.body),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => setState(() => _menu = !_menu),
                      child: Container(
                        height: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                            color: O.pill, borderRadius: BorderRadius.circular(999)),
                        child: Row(children: [
                          Dot(rColor, size: 6),
                          const SizedBox(width: 6),
                          Text(rLabel,
                              style: const TextStyle(
                                  fontSize: 12, color: O.ink2, fontFeatures: O.tabular)),
                          const SizedBox(width: 4),
                          Icon(_menu ? Icons.expand_less : Icons.expand_more,
                              size: 14, color: O.ink3),
                        ]),
                      ),
                    ),
                  ]),
                  if (f.taskTitle != null) ...[
                    const SizedBox(height: 10),
                    Text(f.taskTitle!, style: O.body.copyWith(color: O.ink2)),
                  ],
                  const SizedBox(height: 18),
                  Text(_clock(f.studied),
                      style: TextStyle(
                          fontSize: 64,
                          fontWeight: FontWeight.w200,
                          height: 1,
                          fontFeatures: O.tabular,
                          color: switch (f.phase) {
                            FPhase.running => O.ink,
                            FPhase.paused => const Color(0xFF6E6E73),
                            FPhase.idle => const Color(0xFF46464B),
                          })),
                  const SizedBox(height: 8),
                  Text(sub, style: O.small, textAlign: TextAlign.center),
                ]),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: _Mini('Pausen',
                        '${f.breaks} · ${_clock(f.breakMs + f.curBreak)}')),
                const SizedBox(width: 8),
                Expanded(
                    child: _Mini('Puls jetzt', hr == null ? '–' : '$hr bpm',
                        dot: hr == null ? O.grey : O.green)),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  flex: 3,
                  child: OButton(
                    switch (f.phase) {
                      FPhase.idle => 'Start',
                      FPhase.running => 'Pause',
                      FPhase.paused => 'Weiter',
                    },
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      f.primary();
                    },
                    height: 54,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: OButton('Beenden',
                      primary: false,
                      height: 54,
                      onTap: f.phase == FPhase.idle ? null : () => _finish(context)),
                ),
              ]),
              if (_note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_note!, textAlign: TextAlign.center, style: O.small),
                ),
              const SizedBox(height: 24),
              SectionHead('Heute', hint: '${_dur(todayMs)} fokussiert'),
              const SizedBox(height: 10),
              if (today.isEmpty)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: tileDeco(),
                  child: const Text('Noch keine Session heute.', style: O.small),
                )
              else
                Container(
                  decoration: tileDeco(),
                  child: Column(children: [
                    for (var i = 0; i < today.length; i++) ...[
                      if (i > 0) const Divider(height: 1, thickness: 1, color: O.line, indent: 14),
                      _SessionRow(today[i]),
                    ],
                  ]),
                ),
            ],
          ),
          if (_menu) ...[
            Positioned.fill(
                child: GestureDetector(
                    onTap: () => setState(() => _menu = false),
                    child: Container(color: Colors.transparent))),
            Positioned(
              top: 108 + (f.reminderDue ? 74 : 0),
              right: 28,
              width: 230,
              child: Material(
                color: O.pill,
                elevation: 12,
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(10, 6, 10, 4),
                          child: Text('PAUSE ERINNERN NACH', style: O.label),
                        ),
                        for (final o in [
                          (-1, 'Automatisch',
                              '${FocusStore.autoBlock(widget.energy)} min · ${widget.energy == null ? 'Standard' : 'nach Energie'}'),
                          (25, '25 min', 'kurze Blöcke'),
                          (50, '50 min', 'klassisch'),
                          (90, '90 min', 'Deep Work'),
                          (0, 'Aus', 'keine Erinnerung'),
                        ])
                          InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () {
                              f.setRemind(o.$1);
                              setState(() => _menu = false);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              child: Row(children: [
                                Expanded(
                                  child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(o.$2, style: O.body),
                                        Text(o.$3, style: O.small),
                                      ]),
                                ),
                                if (f.remind == o.$1)
                                  const Icon(Icons.check, size: 16, color: O.ink),
                              ]),
                            ),
                          ),
                      ]),
                ),
              ),
            ),
          ],
        ]);
      },
    );
  }

  Future<void> _finish(BuildContext context) async {
    HapticFeedback.mediumImpact();
    // A linked task asks for its progress first (tasks arrive with Notion).
    int? progress;
    if (f.taskId != null) {
      progress = await showProgressSheet(context, f.taskTitle ?? 'Aufgabe');
      if (progress == null) return; // sheet dismissed: keep running
    }
    final s = f.finish(progress: progress);
    if (s != null && s.studiedMs < 60000 && mounted) {
      setState(() => _note = 'Unter 1 Minute – nicht gespeichert');
      _noteT?.cancel();
      _noteT = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _note = null);
      });
    }
  }
}

/// "Wie weit bist du?" — 25/50/75/fertig. Null when dismissed.
Future<int?> showProgressSheet(BuildContext context, String title) =>
    showModalBottomSheet<int>(
      context: context,
      backgroundColor: O.tile,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: O.body),
            const SizedBox(height: 4),
            const Text('Wie weit bist du?', style: O.small),
            const SizedBox(height: 16),
            Row(children: [
              for (final p in const [25, 50, 75]) ...[
                Expanded(
                    child: OButton('$p %',
                        primary: false, height: 48, onTap: () => Navigator.of(c).pop(p))),
                const SizedBox(width: 8),
              ],
              Expanded(
                  child: OButton('Fertig', height: 48, onTap: () => Navigator.of(c).pop(100))),
            ]),
          ]),
        ),
      ),
    );

class _Nudge extends StatelessWidget {
  final String text;
  final VoidCallback onPause, onDismiss;
  const _Nudge({required this.text, required this.onPause, required this.onDismiss});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        decoration: BoxDecoration(color: O.ink, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Zeit für eine Pause',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: O.bg)),
              Text('$text · das Band hat vibriert',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF48484C))),
            ]),
          ),
          TextButton(
            onPressed: onPause,
            style: TextButton.styleFrom(
                backgroundColor: O.bg,
                foregroundColor: O.ink,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Pause'),
          ),
          IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 16, color: Color(0xFF48484C))),
        ]),
      );
}

class _Mini extends StatelessWidget {
  final String label, value;
  final Color? dot;
  const _Mini(this.label, this.value, {this.dot});
  @override
  Widget build(BuildContext context) => Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: tileDeco(r: 14),
        child: Row(children: [
          if (dot != null) ...[Dot(dot!, size: 6), const SizedBox(width: 6)],
          Text(label, style: O.small),
          const Spacer(),
          Text(value,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: O.ink, fontFeatures: O.tabular)),
        ]),
      );
}

/// One logged session; its average HR comes from the band's synced 1 Hz data.
class _SessionRow extends StatelessWidget {
  final FocusSession s;
  const _SessionRow(this.s);

  static final _hrCache = <String, int?>{};

  Future<int?> _avgHr() async {
    if (_hrCache[s.id] != null) return _hrCache[s.id];
    try {
      final rows = await LocalDb.hrSamplesInRange(s.start ~/ 1000, s.end ~/ 1000);
      if (rows.length < 60) return null; // under a minute of band data: not yet
      final sum = rows.fold<num>(0, (a, r) => a + ((r['hr'] as num?) ?? 0));
      final v = (sum / rows.length).round();
      _hrCache[s.id] = v;
      return v;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = DateTime.fromMillisecondsSinceEpoch(s.start);
    final b = DateTime.fromMillisecondsSinceEpoch(s.end);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.label, style: O.body),
            const SizedBox(height: 2),
            Text(
                '${s.type == 'learn' ? 'Lernen' : 'Arbeit'} · ${hhmm(a)} – ${hhmm(b)}'
                '${s.progress == null ? '' : ' · ${s.progress} %'}',
                style: O.small),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_dur(s.studiedMs),
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: O.ink, fontFeatures: O.tabular)),
          const SizedBox(height: 2),
          FutureBuilder<int?>(
            future: _avgHr(),
            builder: (c, snap) => Text(
                snap.data == null ? 'Puls: wartet auf Band' : 'Ø ${snap.data} bpm',
                style: O.small),
          ),
        ]),
      ]),
    );
  }
}

// ── Woche / Monat ─────────────────────────────────────────────────────────────

class FocusPeriod extends StatelessWidget {
  final int n;
  const FocusPeriod({super.key, required this.n});
  @override
  Widget build(BuildContext context) {
    final f = FocusStore.instance;
    return ListenableBuilder(
      listenable: f,
      builder: (context, _) {
        final days = lastDays(n);
        List<double?> hours(String? type) => [
              for (final d in days)
                () {
                  final ms = f
                      .onDay(d)
                      .where((s) => type == null || s.type == type)
                      .fold<int>(0, (a, s) => a + s.studiedMs);
                  return ms == 0 ? null : ms / 3600000;
                }(),
            ];
        final all = hours(null);
        final total = all.whereType<double>().fold<double>(0, (a, b) => a + b);
        final learn = hours('learn').whereType<double>().fold<double>(0, (a, b) => a + b);
        final sessions = [for (final d in days) ...f.onDay(d)];
        final avgLen = sessions.isEmpty
            ? null
            : sessions.fold<int>(0, (a, s) => a + s.studiedMs) / sessions.length / 60000;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
          children: [
            SectionHead(n == 7 ? 'Letzte 7 Tage' : 'Letzte 30 Tage',
                hint: '${wdDm(days.first)} – ${wdDm(days.last)}'),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: SumTile('Fokuszeit', sessions.isEmpty ? '--' : de(total, 1),
                      sessions.isEmpty ? 'h' : 'h · davon ${de(learn, 1)} h Lernen',
                      bar: sessions.isEmpty || total == 0 ? null : learn / total,
                      height: 118)),
              const SizedBox(width: 8),
              Expanded(
                  child: SumTile('Sessions', sessions.isEmpty ? '--' : '${sessions.length}',
                      avgLen == null ? 'noch keine' : 'Ø ${hMin(avgLen)} lang',
                      height: 118)),
            ]),
            const SizedBox(height: 12),
            TrendCard(
                spec: const TrendSpec('focus', 'Fokus', 'h', dec: 1),
                days: days,
                values: all,
                emptyNote: 'noch keine Sessions'),
            const SizedBox(height: 12),
            TrendCard(
                spec: const TrendSpec('learn', 'Lernen', 'h', dec: 1),
                days: days,
                values: hours('learn'),
                emptyNote: 'noch keine Lern-Sessions'),
          ],
        );
      },
    );
  }
}
