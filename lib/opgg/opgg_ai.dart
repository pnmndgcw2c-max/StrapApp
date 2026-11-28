// KI-Berichte (Tag / Woche / Monat) for Überblick and Aufgaben.
//
// One provider client and one key store: OpenStrap's CoachConfig +
// CoachEngine.completeText (BYOK). OPGG only picks the provider preset.
//
// Every provider gets the SAME prompt: the fixed system text [kReportSystem]
// and the fixed template [kReportTemplate], whose {{PLATZHALTER}} are filled
// with a fixed list of labelled values per report kind. A value the store
// does not have is written as "—" and the system text forbids the model to
// mention or infer it (never fabricate, AGENTS.md §3.3). The answer comes back
// as fixed JSON (Rückblick / Ausblick, each text + points).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../coach/coach_config.dart';
import '../coach/coach_engine.dart';
import '../data/day_label.dart';
import '../state/prefs.dart';
import 'opgg_charts.dart' show avgOf;
import 'opgg_data.dart';
import 'opgg_focus.dart';
import 'opgg_overview.dart';
import 'opgg_style.dart';
import 'opgg_sync.dart';
import 'opgg_tasks.dart';
import 'opgg_toast.dart';

// ── providers ────────────────────────────────────────────────────────────────

class AiPreset {
  final String label, base, model;
  const AiPreset(this.label, this.base, this.model);
}

/// Anthropic first: it is the default (decided 28.11.). Model ids are only the
/// starting value of the field; "Modelle laden" lists what the key can use.
const kAiPresets = [
  AiPreset('Anthropic', 'https://api.anthropic.com/v1', 'claude-sonnet-5-5'),
  AiPreset('OpenAI', 'https://api.openai.com/v1', 'gpt-5-mini'),
  AiPreset('OpenRouter', 'https://openrouter.ai/api/v1', ''),
];

/// Index of the preset [cfg] currently points at, or -1 (something else is
/// configured in OpenStrap's own coach settings, e.g. a local model).
int presetOf(CoachConfig cfg) {
  if (cfg.usesApple || cfg.usesChatGpt) return -1;
  final o = coachEndpointOrigin(cfg.baseUrl);
  for (var i = 0; i < kAiPresets.length; i++) {
    if (coachEndpointOrigin(kAiPresets[i].base) == o) return i;
  }
  return -1;
}

// ── the one prompt ───────────────────────────────────────────────────────────

const kReportSystem = '''Du schreibst kurze Berichte für OPGG, Jonas' private App für Energie, Schlaf, Fokus und Aufgaben. Die Werte kommen vom WHOOP-Band (ausgewertet von OpenStrap) und aus Notion.
Regeln:
1. Deutsch, Du-Form, ruhig und sachlich. Keine Emojis, kein Markdown.
2. Nutze nur die gelieferten Werte. „—“ heißt: Wert fehlt. Erwähne fehlende Werte nicht und leite nichts aus ihnen ab.
3. Erfinde keine Zahlen. Vergleiche nur Werte, die beide vorhanden sind. Runde nicht anders als geliefert.
4. Keine Diagnosen und keine medizinischen Ratschläge.
5. Rückblick: was war, mit den wichtigsten Zahlen. Ausblick: was das für den Ausblick-Zeitraum heißt, konkret und machbar.
6. Antworte ausschließlich mit diesem JSON, ohne Text davor oder danach:
{"rueckblick":{"text":"2 bis 3 Sätze","punkte":["ein Satz","ein Satz"]},"ausblick":{"text":"1 bis 2 Sätze","punkte":["ein Satz","ein Satz","ein Satz"]}}
Höchstens 3 Punkte je Abschnitt.''';

const kReportTemplate = '''{{BERICHT}} · erstellt {{JETZT}}

RÜCKBLICK · {{RUECKBLICK_ZEITRAUM}}
{{RUECKBLICK_WERTE}}

AUSBLICK · {{AUSBLICK_ZEITRAUM}}
{{AUSBLICK_WERTE}}

HINWEISE
{{HINWEISE}}''';

String fillTemplate(Map<String, String> v) {
  var s = kReportTemplate;
  v.forEach((k, val) => s = s.replaceAll('{{$k}}', val));
  return s;
}

// ── kinds and periods ────────────────────────────────────────────────────────

enum RKind { day, week, month, tasksWeek, tasksMonth }

extension RKindX on RKind {
  bool get isTasks => this == RKind.tasksWeek || this == RKind.tasksMonth;
  String get reportName => switch (this) {
        RKind.day => 'Tagesbericht',
        RKind.week || RKind.tasksWeek => 'Wochenbericht',
        RKind.month || RKind.tasksMonth => 'Monatsbericht',
      };
  String get area => isTasks ? 'Aufgaben' : 'Überblick';
}

const _kMonths = [
  'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', 'August', //
  'September', 'Oktober', 'November', 'Dezember'
];

DateTime _d(DateTime t) => DateTime(t.year, t.month, t.day);
List<DateTime> _range(DateTime a, DateTime b) => [
      for (var d = _d(a); !d.isAfter(b); d = DateTime(d.year, d.month, d.day + 1)) d,
    ];
String _dm(DateTime d) => '${d.day}.${d.month}.';
String _span(List<DateTime> ds) =>
    ds.length == 1 ? wdDm(ds.first) : '${_dm(ds.first)} – ${_dm(ds.last)}';

/// Rückblick = the last whole day / calendar week / month, Ausblick = the
/// current one so far (as in the mockup). Local days only.
class RPeriod {
  final List<DateTime> back, fwd;
  final int total; // days of the current period
  final String backName, fwdName;
  const RPeriod(this.back, this.fwd, this.total, this.backName, this.fwdName);
  int get left => total - fwd.length;
  String get key => dayLabelOf(fwd.first);

  factory RPeriod.of(RKind k, [DateTime? now]) {
    final t = _d(now ?? DateTime.now());
    switch (k) {
      case RKind.day:
        final y = DateTime(t.year, t.month, t.day - 1);
        return RPeriod([y], [t], 1, 'gestern, ${wdDm(y)}', 'heute, ${wdDm(t)}');
      case RKind.week || RKind.tasksWeek:
        final mo = DateTime(t.year, t.month, t.day - (t.weekday - 1));
        final back = _range(DateTime(mo.year, mo.month, mo.day - 7), DateTime(mo.year, mo.month, mo.day - 1));
        final fwd = _range(mo, t);
        return RPeriod(back, fwd, 7, 'letzte Woche (${_span(back)})',
            'diese Woche (${_span([mo, DateTime(mo.year, mo.month, mo.day + 6)])}), bisher ${fwd.length} von 7 Tagen');
      case RKind.month || RKind.tasksMonth:
        final first = DateTime(t.year, t.month, 1);
        final lastFirst = DateTime(t.year, t.month - 1, 1);
        final back = _range(lastFirst, DateTime(t.year, t.month, 0));
        final total = DateTime(t.year, t.month + 1, 0).day;
        final fwd = _range(first, t);
        return RPeriod(back, fwd, total, '${_kMonths[lastFirst.month - 1]} (${_span(back)})',
            '${_kMonths[first.month - 1]}, bisher ${fwd.length} von $total Tagen');
    }
  }
}

// ── values (fixed list per kind; absent → "—") ──────────────────────────────

const _na = '—';
String _n(double? v, {int dec = 0, String unit = ''}) =>
    v == null ? _na : '${de(v, dec)}${unit.isEmpty ? '' : ' $unit'}';

bool _same(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

String _lines(List<(String, String)> rows) => [for (final r in rows) '- ${r.$1}: ${r.$2}'].join('\n');

/// Health + focus + tasks over [days] (Überblick).
List<(String, String)> _overviewBlock(OpggDay d, List<DateTime> days) {
  final one = days.length == 1;
  final p = one ? '' : 'Ø ';
  List<double?> s(String key) => [for (final x in days) d.on(key, x)];
  final energy = [for (final x in days) energyOn(d, x)];
  int? best;
  for (var i = 0; i < energy.length; i++) {
    if (energy[i] != null && (best == null || energy[i]! > energy[best]!)) best = i;
  }
  final sleep = s('sleep');
  final need = d.today.sleepNeed.value?.toDouble() ?? 480.0;
  final hi = <double>[], lo = <double>[];
  for (var i = 0; i < days.length; i++) {
    if (energy[i] == null || sleep[i] == null) continue;
    (sleep[i]! >= need ? hi : lo).add(energy[i]!);
  }
  final f = FocusStore.instance;
  final sessions = [for (final x in days) ...f.onDay(x)];
  final focusMs = sessions.fold<int>(0, (a, x) => a + x.studiedMs);
  final done = [
    for (final t in NotionStore.instance.done)
      if (t.doneAt != null && days.any((x) => _same(x, t.doneAt!))) t
  ];
  final sl = avgOf(sleep);
  return [
    ('${p}Energie (0–100)', _n(avgOf(energy))),
    if (!one) ('Bester Energie-Tag', best == null ? _na : '${wdDm(days[best])} mit ${energy[best]!.round()}'),
    ('${p}Schlaf', sl == null ? _na : hMin(sl)),
    ('${p}Tiefschlaf', avgOf(s('deep')) == null ? _na : hMin(avgOf(s('deep'))!)),
    ('${p}Recovery (0–100)', _n(avgOf(s('recovery')))),
    ('${p}HRV', _n(avgOf(s('hrv')), unit: 'ms')),
    ('${p}Ruhepuls', _n(avgOf(s('resting_hr')), unit: 'bpm')),
    ('${p}Stress nachts (0–100)', _n(avgOf(s('stress')))),
    if (!one) ('Nächte mit Daten', '${sleep.whereType<double>().length} von ${days.length}'),
    if (!one)
      ('Ø Energie an Tagen mit Schlaf ≥ Ziel / darunter',
          hi.isEmpty || lo.isEmpty ? _na : '${avgOf(hi)!.round()} / ${avgOf(lo)!.round()}'),
    ('Fokuszeit', sessions.isEmpty ? _na : '${hMin(focusMs / 60000)} in ${sessions.length} Sessions'),
    ('Erledigte Aufgaben',
        !NotionStore.instance.configured
            ? _na
            : done.isEmpty
                ? '0'
                : '${done.length} (${done.fold<int>(0, (a, t) => a + effortPoints(t.effort))} Aufwandspunkte)'),
  ];
}

/// Tasks over [days] (Aufgaben).
List<(String, String)> _tasksBlock(List<DateTime> days) {
  final n = NotionStore.instance;
  if (!n.configured) return const [('Aufgaben', _na)];
  final done = [
    for (final t in n.done)
      if (t.doneAt != null && days.any((x) => _same(x, t.doneAt!))) t
  ];
  final f = FocusStore.instance;
  final sessions = [for (final x in days) ...f.onDay(x)];
  final taskMs = sessions.where((s) => s.taskId != null).fold<int>(0, (a, s) => a + s.studiedMs);
  final allMs = sessions.fold<int>(0, (a, s) => a + s.studiedMs);
  final rated = [for (final t in done) if (t.effort != null && t.focusMin > 0) t];
  final est = rated.fold<int>(0, (a, t) => a + effortMinutes(t.effort));
  final real = rated.fold<int>(0, (a, t) => a + t.focusMin);
  final areas = <String, int>{};
  for (final t in done) {
    areas[t.area ?? 'ohne Bereich'] = (areas[t.area ?? 'ohne Bereich'] ?? 0) + 1;
  }
  return [
    ('Erledigte Aufgaben', '${done.length}'),
    ('Aufwandspunkte', '${done.fold<int>(0, (a, t) => a + effortPoints(t.effort))}'),
    ('Nach Bereich', areas.isEmpty ? _na : [for (final e in areas.entries) '${e.key} ${e.value}'].join(', ')),
    ('Zeit an Aufgaben (Fokus)', taskMs == 0 ? _na : hMin(taskMs / 60000)),
    ('Fokuszeit gesamt', allMs == 0 ? _na : hMin(allMs / 60000)),
    ('Schätzung vs. echte Fokuszeit',
        est == 0 ? _na : '${hMin(est)} geschätzt, ${hMin(real)} gebraucht (${rated.length} Aufgaben)'),
    ('Erledigt', done.isEmpty ? _na : [for (final t in done.take(6)) t.name].join('; ')),
  ];
}

/// Open work as of now (Ausblick of the task reports and the day report).
List<(String, String)> _openBlock(DateTime until, double? energy) {
  final n = NotionStore.instance;
  if (!n.configured) return const [('Offene Aufgaben', _na)];
  final today = _d(DateTime.now());
  final open = n.tasks;
  final overdue = [for (final t in open) if (t.due != null && _d(t.due!).isBefore(today)) t];
  final dueSoon = [
    for (final t in open)
      if (t.due != null && !_d(t.due!).isBefore(today) && !_d(t.due!).isAfter(until)) t
  ];
  final fit = suggest(open, energy).take(3);
  return [
    ('Offene Aufgaben', '${open.length} (~${hMin(open.fold<int>(0, (a, t) => a + effortMinutes(t.effort)))} Aufwand)'),
    ('Überfällig', overdue.isEmpty ? '0' : [for (final t in overdue.take(5)) t.name].join('; ')),
    ('Fällig bis ${wdDm(until)}', dueSoon.isEmpty ? '0' : [for (final t in dueSoon.take(5)) t.name].join('; ')),
    ('Angefangen', n.started.isEmpty ? '0' : [for (final t in n.started.take(3)) '${t.name} (${t.progress} %)'].join('; ')),
    ('Passt jetzt am besten',
        fit.isEmpty ? _na : [for (final t in fit) '${t.name} (${t.effort ?? 'Aufwand offen'}, Energie ${t.energy ?? 'offen'})'].join('; ')),
  ];
}

List<(String, String)> _todayBlock(OpggDay d) {
  final e = Energy.of(d);
  final t = d.today;
  final f = FocusStore.instance;
  final ms = f.onDay(DateTime.now()).fold<int>(0, (a, s) => a + s.studiedMs);
  return [
    ('Energie heute (0–100)', e.total == null ? _na : '${e.total!.round()} (${energyWord(e.total).toLowerCase()})'),
    ('Schlaf-Seite / Recovery / Ruhe',
        '${_n(e.sleep)} / ${_n(e.recovery)} / ${_n(e.calm)}'),
    ('Letzte Nacht', e.sleepMin == null ? _na : hMin(e.sleepMin!)),
    (e.needIsGoal ? 'Schlafziel' : 'Gelernter Schlafbedarf', hMin(e.needMin ?? 480)),
    ('HRV', _n(pick(t.hrv?.rmssd, d, 'hrv'), unit: 'ms')),
    ('Ruhepuls', _n(pick(t.restingHr.value, d, 'resting_hr'), unit: 'bpm')),
    ('Stress nachts (0–100)', _n(pick(t.stress?.score, d, 'stress'))),
    ('Fokus heute bisher', ms == 0 ? '0 min' : hMin(ms / 60000)),
    ('Uhrzeit', hhmm(DateTime.now())),
  ];
}

List<String> _notes(OpggDay? d, RKind k) => [
      if (!k.isTasks)
        'Energie ist der Mittelwert aus Schlaf (Dauer zu Ziel), Recovery und Ruhe (100 minus Stress), 0–100. Sie gibt es nur, wenn alle drei Werte da sind.',
      if (!k.isTasks && d != null && d.today.readiness.value == null)
        'Recovery: ${recoveryWait(d)}.',
      if (!k.isTasks && d != null && d.today.sleepNeed.value == null)
        'Der Schlafbedarf ist noch nicht gelernt, daher gilt Jonas\' Ziel von 8 h.',
      'Aufwand in Notion: kurz ~20 min (1 Punkt), mittel ~1 h (2 Punkte), lang ~2 h 30 (3 Punkte).',
      'Training wird in OPGG noch nicht erfasst.',
    ];

/// The filled prompt for [k], built from what the screens already have.
({String title, String prompt, RPeriod p}) buildReport(RKind k, OpggDay? d) {
  final p = RPeriod.of(k);
  final title = '${k.reportName} ${k.area} · ${_span(k == RKind.day ? p.fwd : [p.fwd.first, DateTime(p.fwd.first.year, p.fwd.first.month, p.fwd.first.day + p.total - 1)])}';
  final until = DateTime(p.fwd.first.year, p.fwd.first.month, p.fwd.first.day + p.total - 1);
  final energy = d == null ? null : Energy.of(d).total;
  final List<(String, String)> back, fwd;
  if (k.isTasks) {
    back = _tasksBlock(p.back);
    fwd = [..._tasksBlock(p.fwd), ('Tage übrig', '${p.left}'), ..._openBlock(until, energy)];
  } else if (k == RKind.day) {
    back = _overviewBlock(d!, p.back);
    fwd = [..._todayBlock(d), ..._openBlock(p.fwd.first, energy)];
  } else {
    back = _overviewBlock(d!, p.back);
    fwd = [..._overviewBlock(d, p.fwd), ('Tage übrig', '${p.left}'), ..._openBlock(until, energy)];
  }
  final prompt = fillTemplate({
    'BERICHT': '${k.reportName} ${k.area}',
    'JETZT': '${wdDm(DateTime.now())} ${hhmm(DateTime.now())}',
    'RUECKBLICK_ZEITRAUM': p.backName,
    'RUECKBLICK_WERTE': _lines(back),
    'AUSBLICK_ZEITRAUM': p.fwdName,
    'AUSBLICK_WERTE': _lines(fwd),
    'HINWEISE': [for (final s in _notes(d, k)) '- $s'].join('\n'),
  });
  return (title: title, prompt: prompt, p: p);
}

// ── report model + parsing ───────────────────────────────────────────────────

class RSection {
  final String head, text;
  final List<String> points;
  const RSection(this.head, this.text, this.points);
  Map<String, Object?> toJson() => {'h': head, 't': text, 'p': points};
  static RSection fromJson(Map j) =>
      RSection('${j['h'] ?? ''}', '${j['t'] ?? ''}', [for (final x in (j['p'] as List? ?? const [])) '$x']);
}

class Report {
  final RKind kind;
  final String key, title, model, prompt;
  final int at;
  final List<RSection> sections;
  final DateTime from, to; // whole Ausblick period (Notion "Zeitraum")
  final int savedAt; // 0 = not in Notion yet
  const Report(this.kind, this.key, this.title, this.model, this.prompt, this.at, this.sections,
      this.from, this.to, {this.savedAt = 0});

  Report saved(int t) => Report(kind, key, title, model, prompt, at, sections, from, to, savedAt: t);

  Map<String, Object?> toJson() => {
        'k': kind.name, 'key': key, 'title': title, 'model': model, 'prompt': prompt, 'at': at,
        's': [for (final s in sections) s.toJson()],
        'from': from.millisecondsSinceEpoch, 'to': to.millisecondsSinceEpoch, 'saved': savedAt,
      };
  static Report? fromJson(Object? j) {
    if (j is! Map) return null;
    final k = RKind.values.where((x) => x.name == j['k']).firstOrNull;
    if (k == null) return null;
    return Report(
      k, '${j['key']}', '${j['title']}', '${j['model']}', '${j['prompt']}', (j['at'] as num?)?.toInt() ?? 0,
      [for (final s in (j['s'] as List? ?? const [])) if (s is Map) RSection.fromJson(s)],
      DateTime.fromMillisecondsSinceEpoch((j['from'] as num?)?.toInt() ?? 0),
      DateTime.fromMillisecondsSinceEpoch((j['to'] as num?)?.toInt() ?? 0),
      savedAt: (j['saved'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Reads the fixed JSON answer. Anything else becomes one plain section, so a
/// stray answer is still shown as written rather than dropped.
List<RSection> parseAnswer(String raw, RPeriod p) {
  final a = raw.indexOf('{'), b = raw.lastIndexOf('}');
  if (a >= 0 && b > a) {
    try {
      final j = jsonDecode(raw.substring(a, b + 1));
      if (j is Map) {
        RSection? sec(String key, String head) {
          final m = j[key];
          if (m is! Map) return null;
          return RSection(head, '${m['text'] ?? ''}'.trim(),
              [for (final x in (m['punkte'] as List? ?? const [])) '$x'.trim()].where((x) => x.isNotEmpty).toList());
        }

        final out = [
          ?sec('rueckblick', 'RÜCKBLICK · ${p.backName.toUpperCase()}'),
          ?sec('ausblick', 'AUSBLICK · ${p.fwdName.toUpperCase()}'),
        ];
        if (out.isNotEmpty) return out;
      }
    } catch (_) {}
  }
  return [RSection('BERICHT', raw.trim(), const [])];
}

// ── store ────────────────────────────────────────────────────────────────────

class ReportStore extends ChangeNotifier {
  ReportStore._() {
    for (final k in RKind.values) {
      try {
        final r = Report.fromJson(jsonDecode(Prefs.getString(_pref(k), '')));
        if (r != null) _last[k] = r;
      } catch (_) {}
    }
  }
  static final ReportStore instance = ReportStore._();
  static String _pref(RKind k) => 'opgg_report_${k.name}';

  final Map<RKind, Report> _last = {};
  final Set<RKind> _open = {}, _busy = {};
  final Map<RKind, String> _err = {};
  final Set<RKind> _saving = {};

  bool isOpen(RKind k) => _open.contains(k);
  bool isBusy(RKind k) => _busy.contains(k);
  bool isSaving(RKind k) => _saving.contains(k);
  String? error(RKind k) => _err[k];
  Report? shown(RKind k) => _open.contains(k) ? _last[k] : null;

  void close(RKind k) {
    _open.remove(k);
    _err.remove(k);
    notifyListeners();
  }

  /// Pen: opens the saved report of the current period, else writes one;
  /// pressed while a report is open, it writes a new one.
  Future<void> pen(RKind k, CoachConfig cfg, OpggDay? day) async {
    if (_busy.contains(k)) return;
    final cached = _last[k];
    if (!_open.contains(k) && cached != null && cached.key == RPeriod.of(k).key) {
      _open.add(k);
      _err.remove(k);
      notifyListeners();
      return;
    }
    await write(k, cfg, day);
  }

  Future<void> write(RKind k, CoachConfig cfg, OpggDay? day) async {
    _open.add(k);
    _err.remove(k);
    if (!cfg.configured) {
      _err[k] = 'Kein KI-Schlüssel. Trag ihn in den Einstellungen unter „KI-Berichte“ ein.';
      notifyListeners();
      return;
    }
    if (!k.isTasks && day == null) {
      _err[k] = 'Die Daten laden noch. Gleich nochmal versuchen.';
      notifyListeners();
      return;
    }
    _busy.add(k);
    notifyListeners();
    try {
      final b = buildReport(k, day);
      final raw = await CoachEngine.completeText(
          config: cfg, system: kReportSystem, user: b.prompt, temperature: 0.2);
      final first = b.p.fwd.first;
      final r = Report(k, b.p.key, b.title, cfg.model, b.prompt, DateTime.now().millisecondsSinceEpoch,
          parseAnswer(raw, b.p), first, DateTime(first.year, first.month, first.day + b.p.total - 1));
      _last[k] = r;
      Prefs.setString(_pref(k), jsonEncode(r.toJson()));
      NotionStore.instance.addLog('KI', true, '${k.reportName} ${k.area} geschrieben');
    } on CoachException catch (e) {
      _err[k] = 'Bericht fehlgeschlagen: ${e.message}';
      NotionStore.instance.addLog('KI', false, '${k.reportName}: ${e.message}');
    } on TimeoutException {
      _err[k] = 'Keine Antwort vom Anbieter (Zeitüberschreitung).';
      NotionStore.instance.addLog('KI', false, '${k.reportName}: Zeitüberschreitung');
    } catch (e) {
      _err[k] = 'Bericht fehlgeschlagen. Ist das Handy online?';
      NotionStore.instance.addLog('KI', false, '${k.reportName}: $e');
    } finally {
      _busy.remove(k);
      notifyListeners();
    }
  }

  Future<void> saveToNotion(RKind k) async {
    final r = _last[k];
    if (r == null || _saving.contains(k)) return;
    _saving.add(k);
    notifyListeners();
    final err = await NotionStore.instance.saveReport(r);
    _saving.remove(k);
    if (err == null) {
      final s = r.saved(DateTime.now().millisecondsSinceEpoch);
      _last[k] = s;
      Prefs.setString(_pref(k), jsonEncode(s.toJson()));
      OToast.instance.show('Bericht in Notion gespeichert');
    } else {
      OToast.instance.show(err);
    }
    notifyListeners();
  }
}

// ── UI: pen + panel (mockup) ─────────────────────────────────────────────────

class ReportPen extends StatelessWidget {
  final RKind kind;
  final OpggDay? day;
  const ReportPen(this.kind, {super.key, this.day});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ReportStore.instance,
        builder: (context, _) {
          final s = ReportStore.instance;
          final on = s.isOpen(kind) || s.isBusy(kind);
          return Semantics(
            button: true,
            label: s.shown(kind) != null ? '${kind.reportName} neu schreiben' : '${kind.reportName} schreiben',
            child: GestureDetector(
              onTap: () => s.pen(kind, context.read<CoachConfig>(), day),
              child: Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: on ? const [O.ink, Color(0xFFE2E2E5)] : const [O.raised, O.raised2]),
                ),
                child: CustomPaint(size: const Size(14, 14), painter: _PenPainter(on ? O.bg : O.ink2)),
              ),
            ),
          );
        },
      );
}

class _PenPainter extends CustomPainter {
  final Color c;
  _PenPainter(this.c);
  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    final p = Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // Mockup icon: M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16v4z  +  M13.5 6.5l4 4
    final body = Path()
      ..moveTo(4 * k, 20 * k)
      ..lineTo(8 * k, 20 * k)
      ..lineTo(19 * k, 9 * k)
      ..arcToPoint(Offset(15 * k, 5 * k), radius: Radius.circular(2.8 * k), clockwise: false)
      ..lineTo(4 * k, 16 * k)
      ..close();
    canvas.drawPath(body, p);
    canvas.drawLine(Offset(13.5 * k, 6.5 * k), Offset(17.5 * k, 10.5 * k), p);
  }

  @override
  bool shouldRepaint(_PenPainter o) => o.c != c;
}

class ReportPanel extends StatefulWidget {
  final RKind kind;
  const ReportPanel(this.kind, {super.key});
  @override
  State<ReportPanel> createState() => _ReportPanelState();
}

class _ReportPanelState extends State<ReportPanel> {
  bool _inputs = false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ReportStore.instance,
        builder: (context, _) {
          final s = ReportStore.instance;
          final k = widget.kind;
          final r = s.shown(k);
          final busy = s.isBusy(k), err = s.error(k);
          Widget child;
          if (!s.isOpen(k)) {
            child = const SizedBox(width: double.infinity);
          } else if (busy) {
            child = _box(Row(children: [
              const Dot(O.ink, size: 7),
              const SizedBox(width: 8),
              Text('${k.reportName} wird geschrieben …', style: const TextStyle(fontSize: 13, color: O.ink2)),
            ]));
          } else if (err != null) {
            child = _box(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(err, style: const TextStyle(fontSize: 13, height: 1.4, color: O.ink2))),
              _x(() => s.close(k)),
            ]));
          } else if (r != null) {
            child = _box(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: Text(r.title,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: O.ink))),
                _x(() => s.close(k)),
              ]),
              for (final sec in r.sections) ...[
                const SizedBox(height: 12),
                Text(sec.head, style: O.label),
                if (sec.text.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(sec.text, style: const TextStyle(fontSize: 13, height: 1.5, color: O.ink2)),
                ],
                for (final pt in sec.points)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                          margin: const EdgeInsets.only(top: 7, right: 9),
                          width: 5,
                          height: 5,
                          decoration: const BoxDecoration(color: O.ink3, shape: BoxShape.circle)),
                      Expanded(
                          child: Text(pt, style: const TextStyle(fontSize: 13, height: 1.45, color: O.ink))),
                    ]),
                  ),
              ],
              const SizedBox(height: 12),
              const Divider(height: 1, color: O.line),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _inputs = !_inputs),
                    child: Text(
                        'Erstellt um ${hhmm(DateTime.fromMillisecondsSinceEpoch(r.at))} · ${r.model}\n'
                        '${_inputs ? 'Werte ausblenden' : 'Werte anzeigen'}',
                        style: const TextStyle(fontSize: 11, height: 1.4, color: O.ink3)),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 150,
                  child: OButton(
                      s.isSaving(k)
                          ? 'Speichert …'
                          : r.savedAt > 0
                              ? 'In Notion gespeichert'
                              : 'In Notion speichern',
                      primary: false,
                      height: 36,
                      onTap: r.savedAt > 0 || s.isSaving(k) || !NotionStore.instance.configured
                          ? null
                          : () => s.saveToNotion(k)),
                ),
              ]),
              if (_inputs) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: O.well, borderRadius: BorderRadius.circular(10)),
                  child: SelectableText(r.prompt,
                      style: const TextStyle(fontSize: 11, height: 1.4, color: O.ink3)),
                ),
              ],
            ]));
          } else {
            child = const SizedBox(width: double.infinity);
          }
          return AnimatedSize(
              duration: const Duration(milliseconds: 220), curve: Curves.easeOut, child: child);
        },
      );

  Widget _box(Widget c) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: tileDeco(),
            child: c),
      );

  Widget _x(VoidCallback onTap) => Semantics(
        button: true,
        label: 'Bericht schließen',
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: const SizedBox(
              width: 32, height: 28, child: Icon(Icons.close_rounded, size: 16, color: O.ink3)),
        ),
      );
}
