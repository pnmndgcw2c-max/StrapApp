// OPGG ↔ Notion. Notion is the store: tasks are read from it, finished focus
// sessions and task progress are written to it. Writes go through a small
// persisted queue so nothing is lost offline; a sync runs in the background
// every few minutes, on app resume, right after something is queued, and on
// demand (holding the Sync pill). Every Notion and band sync lands in the
// in-app Protokoll.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../state/prefs.dart';
import 'notion_api.dart';
import 'opgg_focus.dart' show FocusSession;

// ── schema (created by OPGG on the shared "OPGG" page) ─────────────────────

const kTasksTitle = 'Aufgaben';
const kSessionsTitle = 'Sessions';
const kStatusOpen = 'Offen', kStatusDoing = 'In Arbeit', kStatusDone = 'Erledigt';
const kEnergies = ['niedrig', 'mittel', 'hoch'];
const kEfforts = ['kurz', 'mittel', 'lang'];
const kAreas = ['Uni', 'Arbeit', 'Privat'];

Map<String, Object?> _sel(List<(String, String)> opts) => {
      'select': {
        'options': [for (final o in opts) {'name': o.$1, 'color': o.$2}]
      }
    };

Map<String, Object?> tasksSchema() => {
      'Name': {'title': {}},
      'Status': _sel([(kStatusOpen, 'gray'), (kStatusDoing, 'yellow'), (kStatusDone, 'green')]),
      'Energie': _sel([('niedrig', 'blue'), ('mittel', 'yellow'), ('hoch', 'red')]),
      'Aufwand': _sel([('kurz', 'gray'), ('mittel', 'brown'), ('lang', 'purple')]),
      'Fällig': {'date': {}},
      'Bereich': _sel([('Uni', 'blue'), ('Arbeit', 'orange'), ('Privat', 'green')]),
      'Fortschritt': {
        'number': {'format': 'percent'}
      },
      'Fokuszeit (min)': {
        'number': {'format': 'number'}
      },
      'Erledigt am': {'date': {}},
    };

Map<String, Object?> sessionsSchema(String tasksDs) => {
      'Name': {'title': {}},
      'Zeit': {'date': {}},
      'Dauer (min)': {
        'number': {'format': 'number'}
      },
      'Pausen (min)': {
        'number': {'format': 'number'}
      },
      'Aufgabe': {
        'relation': {
          'data_source_id': tasksDs,
          'type': 'single_property',
          'single_property': {},
        }
      },
      'Fortschritt': {
        'number': {'format': 'percent'}
      },
    };

// ── model ────────────────────────────────────────────────────────────────────

class OTask {
  final String id, name, status;
  final String? energy, effort, area, url;
  final DateTime? due;
  final int progress; // 0–100
  final int focusMin;
  final DateTime? doneAt; // for finished tasks (stats)
  const OTask({
    required this.id,
    required this.name,
    required this.status,
    this.energy,
    this.effort,
    this.area,
    this.url,
    this.due,
    this.progress = 0,
    this.focusMin = 0,
    this.doneAt,
  });

  OTask copyWith({String? status, int? progress, int? focusMin, DateTime? doneAt}) => OTask(
        id: id,
        name: name,
        status: status ?? this.status,
        energy: energy,
        effort: effort,
        area: area,
        url: url,
        due: due,
        progress: progress ?? this.progress,
        focusMin: focusMin ?? this.focusMin,
        doneAt: doneAt ?? this.doneAt,
      );

  bool get started => status == kStatusDoing || (progress > 0 && progress < 100);

  static String? _selOf(Map p, String k) {
    final v = p[k];
    return v is Map && v['select'] is Map ? '${v['select']['name']}' : null;
  }

  static num? _numOf(Map p, String k) {
    final v = p[k];
    return v is Map ? v['number'] as num? : null;
  }

  factory OTask.fromNotion(Map page) {
    final p = (page['properties'] as Map?) ?? const {};
    final d = p['Fällig'];
    DateTime? due;
    if (d is Map && d['date'] is Map) due = DateTime.tryParse('${d['date']['start']}');
    final e = p['Erledigt am'];
    DateTime? doneAt;
    if (e is Map && e['date'] is Map) doneAt = DateTime.tryParse('${e['date']['start']}')?.toLocal();
    doneAt ??= DateTime.tryParse('${page['last_edited_time']}')?.toLocal();
    return OTask(
      id: '${page['id']}',
      name: NotionApi.pageTitle(page).trim().isEmpty ? 'Ohne Titel' : NotionApi.pageTitle(page),
      status: _selOf(p, 'Status') ?? kStatusOpen,
      energy: _selOf(p, 'Energie'),
      effort: _selOf(p, 'Aufwand'),
      area: _selOf(p, 'Bereich'),
      url: page['url'] as String?,
      due: due,
      progress: (((_numOf(p, 'Fortschritt') ?? 0) * 100).round()).clamp(0, 100),
      focusMin: (_numOf(p, 'Fokuszeit (min)') ?? 0).round(),
      doneAt: doneAt,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'status': status,
        'energy': energy,
        'effort': effort,
        'area': area,
        'url': url,
        'due': due?.toIso8601String(),
        'progress': progress,
        'focusMin': focusMin,
        'doneAt': doneAt?.toIso8601String(),
      };

  static OTask? fromJson(Object? j) {
    if (j is! Map) return null;
    return OTask(
      id: '${j['id']}',
      name: '${j['name']}',
      status: '${j['status'] ?? kStatusOpen}',
      energy: j['energy'] as String?,
      effort: j['effort'] as String?,
      area: j['area'] as String?,
      url: j['url'] as String?,
      due: j['due'] == null ? null : DateTime.tryParse('${j['due']}'),
      progress: (j['progress'] as num?)?.toInt() ?? 0,
      focusMin: (j['focusMin'] as num?)?.toInt() ?? 0,
      doneAt: j['doneAt'] == null ? null : DateTime.tryParse('${j['doneAt']}'),
    );
  }
}

class SyncLogEntry {
  final int t; // epoch ms
  final String src; // 'Notion' | 'Band'
  final bool ok;
  final String msg;
  const SyncLogEntry(this.t, this.src, this.ok, this.msg);
  Map<String, Object?> toJson() => {'t': t, 'src': src, 'ok': ok, 'msg': msg};
  static SyncLogEntry? fromJson(Object? j) => j is Map
      ? SyncLogEntry((j['t'] as num?)?.toInt() ?? 0, '${j['src']}', j['ok'] == true, '${j['msg']}')
      : null;
}

enum SyncState { off, syncing, ok, idle, error }

// ── store ────────────────────────────────────────────────────────────────────

class NotionStore extends ChangeNotifier {
  NotionStore._() {
    _load();
  }
  static final NotionStore instance = NotionStore._();

  static const _secure = FlutterSecureStorage();
  static const _kToken = 'opgg_notion_token';
  static const _kPage = 'opgg_notion_page', _kPageTitle = 'opgg_notion_page_title';
  static const _kTasksDs = 'opgg_notion_tasks_ds', _kSessDs = 'opgg_notion_sessions_ds';
  static const _kTasks = 'opgg_tasks_cache', _kQueue = 'opgg_sync_queue';
  static const _kLog = 'opgg_sync_log', _kLastOk = 'opgg_sync_last_ok';
  static const _kDone = 'opgg_tasks_done', _kDoneCol = 'opgg_notion_donecol';
  static const _kSessPages = 'opgg_session_pages';
  Map<String, String> _sessionPages = {};

  /// Notion link of a logged session, once it has been uploaded.
  String? sessionUrl(String sessionId) {
    final id = _sessionPages[sessionId];
    return id == null ? null : 'https://www.notion.so/${id.replaceAll('-', '')}';
  }

  /// True while the session still waits in the queue.
  bool sessionPending(String sessionId) => queue.any(
      (o) => o['op'] == 'session' && o['s'] is Map && '${(o['s'] as Map)['id']}' == sessionId);

  String? _token;
  String? pageId, pageTitle, tasksDs, sessionsDs;
  List<OTask> tasks = [];
  List<OTask> done = []; // finished in the last ~31 days (Woche/Monat)
  List<Map<String, dynamic>> queue = [];
  List<SyncLogEntry> log = [];
  int lastOk = 0; // epoch ms of the last successful Notion sync
  bool syncing = false;
  String? lastError;
  Timer? _timer;
  AppLifecycleListener? _life;
  Timer? _soon;

  bool get configured => _token != null && tasksDs != null && sessionsDs != null;
  bool get hasToken => _token != null;

  SyncState get state {
    if (!configured) return SyncState.off;
    if (syncing) return SyncState.syncing;
    final age = DateTime.now().millisecondsSinceEpoch - lastOk;
    if (lastError != null || age > const Duration(hours: 2).inMilliseconds) {
      return SyncState.error;
    }
    if (queue.isEmpty && age < const Duration(minutes: 5).inMilliseconds) return SyncState.ok;
    return SyncState.idle;
  }

  /// Started-but-unfinished tasks (drives the orange dot on Aufgaben).
  List<OTask> get started => [for (final t in tasks) if (t.started) t];

  void _load() {
    pageId = _nz(Prefs.getString(_kPage, ''));
    pageTitle = _nz(Prefs.getString(_kPageTitle, ''));
    tasksDs = _nz(Prefs.getString(_kTasksDs, ''));
    sessionsDs = _nz(Prefs.getString(_kSessDs, ''));
    lastOk = Prefs.getInt(_kLastOk, 0);
    tasks = _list(_kTasks, OTask.fromJson);
    done = _list(_kDone, OTask.fromJson);
    try {
      final m = jsonDecode(Prefs.getString(_kSessPages, '{}'));
      if (m is Map) _sessionPages = {for (final e in m.entries) '${e.key}': '${e.value}'};
    } catch (_) {}
    log = _list(_kLog, SyncLogEntry.fromJson);
    try {
      final q = jsonDecode(Prefs.getString(_kQueue, '[]'));
      queue = [
        if (q is List)
          for (final e in q)
            if (e is Map) e.cast<String, dynamic>()
      ];
    } catch (_) {
      queue = [];
    }
    unawaited(_secure.read(key: _kToken).then((v) {
      _token = (v == null || v.isEmpty) ? null : v;
      notifyListeners();
      _start();
    }, onError: (_) {}));
  }

  static String? _nz(String s) => s.isEmpty ? null : s;

  static List<T> _list<T>(String key, T? Function(Object?) f) {
    try {
      final raw = jsonDecode(Prefs.getString(key, '[]'));
      return [
        if (raw is List)
          for (final e in raw)
            if (f(e) case final v?) v
      ];
    } catch (_) {
      return [];
    }
  }

  void _start() {
    _timer?.cancel();
    _life ??= AppLifecycleListener(onResume: () => syncSoon());
    if (!configured) return;
    _timer = Timer.periodic(const Duration(minutes: 15), (_) => sync());
    syncSoon();
  }

  void syncSoon() {
    _soon?.cancel();
    final wait = _heldUntil - DateTime.now().millisecondsSinceEpoch;
    _soon = Timer(Duration(milliseconds: wait > 0 ? wait + 300 : 2000), () => sync());
  }

  void _persistQueue() => Prefs.setString(_kQueue, jsonEncode(queue));

  void addLog(String src, bool ok, String msg) {
    log = [SyncLogEntry(DateTime.now().millisecondsSinceEpoch, src, ok, msg), ...log];
    if (log.length > 80) log = log.sublist(0, 80);
    Prefs.setString(_kLog, jsonEncode([for (final e in log) e.toJson()]));
    notifyListeners();
  }

  // ── setup ──

  /// Saves the key, finds the "OPGG" page and creates (or re-finds) the two
  /// databases on it. Returns null on success, else a German error.
  Future<String?> connect(String token) async {
    final api = NotionApi(token.trim());
    try {
      await api.me();
    } on NotionError catch (e) {
      return e.human;
    }
    await _secure.write(key: _kToken, value: token.trim());
    _token = token.trim();
    try {
      final pages = await api.searchPages('OPGG');
      if (pages.isEmpty) {
        return 'Keine Seite gefunden. Lege in Notion eine Seite „OPGG“ an und '
            'verbinde sie über „…“ → Verbindungen mit deiner Integration.';
      }
      final page = pages.firstWhere((p) => p.title.trim().toUpperCase() == 'OPGG',
          orElse: () => pages.first);
      String norm(String s) => s.replaceAll('-', '');
      // Re-use databases OPGG already made on this page.
      Future<String?> existing(String title) async {
        final ds = await api.searchDataSources(title);
        for (final d in ds) {
          if (d.title.trim() == title &&
              (d.parentPage == null || norm(d.parentPage!) == norm(page.id))) {
            return d.id;
          }
        }
        return null;
      }

      var t = await existing(kTasksTitle);
      t ??= await api.createDatabase(page.id, kTasksTitle, '✅', tasksSchema());
      Prefs.setBool(_kDoneCol, false); // re-check the column on next sync
      var s = await existing(kSessionsTitle);
      s ??= await api.createDatabase(page.id, kSessionsTitle, '⏱', sessionsSchema(t));
      pageId = page.id;
      pageTitle = page.title;
      tasksDs = t;
      sessionsDs = s;
      Prefs.setString(_kPage, page.id);
      Prefs.setString(_kPageTitle, page.title);
      Prefs.setString(_kTasksDs, t);
      Prefs.setString(_kSessDs, s);
      addLog('Notion', true, 'Verbunden mit „${page.title}“');
      _start();
      return null;
    } on NotionError catch (e) {
      addLog('Notion', false, 'Einrichten: ${e.human}');
      return e.human;
    }
  }

  Future<void> disconnect() async {
    await _secure.delete(key: _kToken);
    _token = null;
    for (final k in [_kPage, _kPageTitle, _kTasksDs, _kSessDs, _kTasks, _kDone]) {
      Prefs.setString(k, '');
    }
    Prefs.setBool(_kDoneCol, false);
    done = [];
    pageId = pageTitle = tasksDs = sessionsDs = null;
    tasks = [];
    _timer?.cancel();
    addLog('Notion', true, 'Getrennt');
  }

  // ── writes (queued) ──

  /// How long a fresh write waits before it goes to Notion, so the
  /// "Rückgängig" in the toast can still take it back.
  static const kUndoWindow = Duration(seconds: 10);

  /// Queues [op] (held for the undo window) and returns its id.
  String _enqueue(Map<String, dynamic> op) {
    final uid = '${DateTime.now().microsecondsSinceEpoch}';
    final nb = DateTime.now().add(kUndoWindow).millisecondsSinceEpoch;
    queue = [...queue, {...op, 'uid': uid, 'nb': nb}];
    _persistQueue();
    return uid;
  }

  /// Local task lists before a change — what an undo restores.
  ({List<OTask> tasks, List<OTask> done}) snapshot() => (tasks: [...tasks], done: [...done]);

  /// Takes back a still-held write and restores the task lists.
  void undo(String uid, ({List<OTask> tasks, List<OTask> done}) snap) {
    queue = [for (final o in queue) if (o['uid'] != uid) o];
    _persistQueue();
    tasks = snap.tasks;
    done = snap.done;
    _saveTasks();
    notifyListeners();
  }

  int get _heldUntil => queue.fold<int>(
      0, (a, o) => ((o['nb'] as num?)?.toInt() ?? 0) > a ? (o['nb'] as num).toInt() : a);

  String enqueueSession(FocusSession s) {
    final uid = _enqueue({'op': 'session', 's': s.toJson()});
    // Reflect progress locally right away; Notion follows on the next sync.
    final t = s.taskId == null ? null : tasks.where((x) => x.id == s.taskId).firstOrNull;
    if (t != null) {
      final addMin = (s.studiedMs / 60000).round();
      if ((s.progress ?? 0) >= 100) {
        _markDoneLocal(t, addMin: addMin);
      } else {
        tasks = [
          for (final x in tasks)
            if (x.id == t.id)
              x.copyWith(
                  status: kStatusDoing,
                  progress: s.progress ?? x.progress,
                  focusMin: x.focusMin + addMin)
            else
              x
        ];
      }
      _saveTasks();
    }
    notifyListeners();
    syncSoon();
    return uid;
  }

  void _saveTasks() {
    Prefs.setString(_kTasks, jsonEncode([for (final t in tasks) t.toJson()]));
    Prefs.setString(_kDone, jsonEncode([for (final t in done) t.toJson()]));
  }

  /// Moves a task to [done] locally (Notion follows via the queue).
  void _markDoneLocal(OTask t, {int addMin = 0}) {
    tasks = [for (final x in tasks) if (x.id != t.id) x];
    done = [
      t.copyWith(
          status: kStatusDone, progress: 100, focusMin: t.focusMin + addMin, doneAt: DateTime.now()),
      for (final x in done) if (x.id != t.id) x,
    ];
  }

  /// Progress change without a logged session (e.g. under a minute).
  String? setProgress(String taskId, int progress) {
    final t = tasks.where((x) => x.id == taskId).firstOrNull;
    if (t == null || t.progress == progress) return null;
    final uid = _enqueue({'op': 'progress', 'id': taskId, 'p': progress});
    if (progress >= 100) {
      _markDoneLocal(t);
    } else {
      tasks = [
        for (final x in tasks)
          if (x.id == taskId) x.copyWith(status: kStatusDoing, progress: progress) else x
      ];
    }
    _saveTasks();
    notifyListeners();
    syncSoon();
    return uid;
  }

  /// Creates a task directly (needs a connection).
  Future<({String? id, String? err})> createTask(
      {required String name, String? energy, String? effort, String? area, DateTime? due}) async {
    if (!configured) return (id: null, err: 'Notion ist nicht verbunden');
    try {
      final id = await NotionApi(_token!).createPage(tasksDs!, {
        'Name': NotionApi.title(name),
        'Status': NotionApi.select(kStatusOpen),
        'Energie': NotionApi.select(energy),
        'Aufwand': NotionApi.select(effort),
        'Bereich': NotionApi.select(area),
        if (due != null) 'Fällig': NotionApi.dateOnly(due),
      });
      tasks = [
        ...tasks,
        OTask(
            id: id,
            name: name,
            status: kStatusOpen,
            energy: energy,
            effort: effort,
            area: area,
            due: due),
      ];
      _saveTasks();
      addLog('Notion', true, 'Aufgabe angelegt: $name');
      notifyListeners();
      return (id: id, err: null);
    } on NotionError catch (e) {
      addLog('Notion', false, 'Aufgabe anlegen: ${e.human}');
      return (id: null, err: e.human);
    }
  }

  /// Undo of [createTask]: moves the page to Notion's trash.
  Future<void> trashTask(String id) async {
    tasks = [for (final t in tasks) if (t.id != id) t];
    _saveTasks();
    notifyListeners();
    try {
      await NotionApi(_token!).trashPage(id);
      addLog('Notion', true, 'Aufgabe zurückgenommen');
    } on NotionError catch (e) {
      addLog('Notion', false, 'Zurücknehmen: ${e.human}');
    }
  }

  /// Marks a task done right away (queued if offline).
  String completeTask(OTask t) {
    final uid = _enqueue({'op': 'done', 'id': t.id});
    _markDoneLocal(t);
    _saveTasks();
    notifyListeners();
    syncSoon();
    return uid;
  }

  // ── sync ──

  Future<void> sync({bool manual = false}) async {
    if (!configured || syncing) return;
    // A write still in its undo window: wait for it rather than pulling a
    // task list that would undo the local change.
    if (_heldUntil > DateTime.now().millisecondsSinceEpoch) {
      syncSoon();
      return;
    }
    syncing = true;
    notifyListeners();
    final api = NotionApi(_token!);
    var sent = 0;
    try {
      // 0. databases made before 'Erledigt am' existed get the column once.
      if (!Prefs.getBool(_kDoneCol, false)) {
        await api.updateDataSource(tasksDs!, {'Erledigt am': {'date': {}}});
        Prefs.setBool(_kDoneCol, true);
      }
      // 1. push queued writes in order; a transient failure stops the run.
      while (queue.isNotEmpty) {
        final op = queue.first;
        try {
          await _push(api, op);
          sent++;
        } on NotionError catch (e) {
          final transient = e.status == 0 || e.status == 409 || e.status == 429 || e.status >= 500;
          if (transient) rethrow;
          addLog('Notion', false, 'Verworfen (${e.human})');
        }
        queue = queue.sublist(1);
        _persistQueue();
      }
      // 2. pull open tasks.
      final rows = await api.query(tasksDs!,
          filter: {
            'property': 'Status',
            'select': {'does_not_equal': kStatusDone},
          },
          sorts: [
            {'property': 'Fällig', 'direction': 'ascending'},
          ]);
      tasks = [for (final r in rows) OTask.fromNotion(r)];
      // 3. tasks finished in the last month (for Woche/Monat).
      final since = DateTime.now().subtract(const Duration(days: 31));
      final doneRows = await api.query(tasksDs!, filter: {
        'and': [
          {
            'property': 'Status',
            'select': {'equals': kStatusDone},
          },
          {
            'timestamp': 'last_edited_time',
            'last_edited_time': {'on_or_after': since.toUtc().toIso8601String()},
          },
        ]
      });
      done = [for (final r in doneRows) OTask.fromNotion(r)];
      _saveTasks();
      lastOk = DateTime.now().millisecondsSinceEpoch;
      Prefs.setInt(_kLastOk, lastOk);
      lastError = null;
      if (manual || sent > 0) {
        addLog('Notion', true,
            '${sent > 0 ? '$sent hochgeladen · ' : ''}${tasks.length} offene Aufgaben');
      }
    } on NotionError catch (e) {
      lastError = e.human;
      addLog('Notion', false, e.human);
    } catch (e) {
      lastError = 'Sync fehlgeschlagen';
      addLog('Notion', false, 'Sync fehlgeschlagen');
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> _push(NotionApi api, Map<String, dynamic> op) async {
    switch (op['op']) {
      case 'session':
        final s = FocusSession.fromJson(op['s']);
        if (s == null) return;
        final start = DateTime.fromMillisecondsSinceEpoch(s.start);
        final end = DateTime.fromMillisecondsSinceEpoch(s.end);
        final taskId = s.taskId;
        // Notion only knows real task ids (UUIDs).
        final linked = taskId != null && !taskId.startsWith('local');
        final pid = await api.createPage(sessionsDs!, {
          'Name': NotionApi.title(s.label),
          'Zeit': NotionApi.date(start, end),
          'Dauer (min)': NotionApi.number((s.studiedMs / 60000).round()),
          'Pausen (min)': NotionApi.number((s.breakMs / 60000).round()),
          if (linked) 'Aufgabe': NotionApi.relation([taskId]),
          if (s.progress != null) 'Fortschritt': NotionApi.number(s.progress! / 100),
        });
        _sessionPages[s.id] = pid;
        Prefs.setString(_kSessPages, jsonEncode(_sessionPages));
        if (linked) {
          // Add the minutes onto what Notion has now (not our cached copy).
          final page = await api.getPage(taskId);
          final cur = OTask.fromNotion(page);
          final p = s.progress ?? cur.progress;
          await api.updatePage(taskId, {
            'Fokuszeit (min)': NotionApi.number(cur.focusMin + (s.studiedMs / 60000).round()),
            if (s.progress != null) 'Fortschritt': NotionApi.number(p / 100),
            'Status': NotionApi.select(p >= 100 ? kStatusDone : kStatusDoing),
            if (p >= 100) 'Erledigt am': NotionApi.dateOnly(DateTime.now()),
          });
        }
      case 'done':
        await api.updatePage('${op['id']}', {
          'Status': NotionApi.select(kStatusDone),
          'Fortschritt': NotionApi.number(1),
          'Erledigt am': NotionApi.dateOnly(DateTime.now()),
        });
      case 'progress':
        final p = (op['p'] as num).toInt();
        await api.updatePage('${op['id']}', {
          'Fortschritt': NotionApi.number(p / 100),
          'Status': NotionApi.select(p >= 100 ? kStatusDone : kStatusDoing),
          if (p >= 100) 'Erledigt am': NotionApi.dateOnly(DateTime.now()),
        });
    }
  }
}
