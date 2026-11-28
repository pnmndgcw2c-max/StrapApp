// OPGG settings, laid out like the mockup: Band, Notion, KI-Berichte, Daten,
// Update, Protokoll, Debug, footer. Keys (Notion, KI) are typed here and go
// straight to the keychain — the KI key through OpenStrap's CoachConfig, the
// one key store for every LLM call in the app.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../coach/coach_config.dart';
import '../coach/coach_engine.dart';
import '../data/csv_export.dart';
import '../state/app_state.dart';
import '../sync/file_log.dart';
import '../ui2/activity/share.dart' show shareOrigin;
import '../ui2/profile/devices.dart' show RePair;
import '../ui2/profile/settings.dart' show MoreSettings;
import 'opgg_ai.dart';
import 'opgg_style.dart';
import 'opgg_sync.dart';
import 'opgg_toast.dart';

/// Build number and commit, passed in by the iOS workflow (--dart-define).
const kOpggBuild = String.fromEnvironment('OPGG_BUILD');
const kOpggSha = String.fromEnvironment('OPGG_SHA');
const _kRepo = 'pnmndgcw2c-max/StrapApp';

Color syncColor(SyncState s) => switch (s) {
      SyncState.off => O.grey,
      SyncState.syncing => O.orange,
      SyncState.ok => O.green,
      SyncState.idle => O.orange,
      SyncState.error => O.red,
    };

String syncLabel(SyncState s, NotionStore n) => switch (s) {
      SyncState.off => 'nicht verbunden',
      SyncState.syncing => 'synchronisiert …',
      SyncState.ok => 'aktuell',
      SyncState.idle => n.queue.isEmpty ? 'wartet auf nächsten Sync' : '${n.queue.length} ausstehend',
      SyncState.error => n.lastError ?? 'lange nicht synchronisiert',
    };

String agoLabel(int ms) {
  if (ms == 0) return 'nie';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return 'gerade eben';
  if (d.inMinutes < 60) return 'vor ${d.inMinutes} min';
  if (d.inHours < 24) return 'vor ${d.inHours} h';
  return wdDm(DateTime.fromMillisecondsSinceEpoch(ms));
}

class OpggSettings extends StatefulWidget {
  final ({Color color, String label}) Function(AppState) bandState;
  const OpggSettings({super.key, required this.bandState});
  @override
  State<OpggSettings> createState() => _OpggSettingsState();
}

class _OpggSettingsState extends State<OpggSettings> {
  final _key = TextEditingController();
  bool _busy = false;
  String? _err;

  // KI
  final _aiKey = TextEditingController();
  final _aiModel = TextEditingController();
  int _aiPreset = 0;
  bool _aiBusy = false;
  String? _aiMsg;
  bool _aiOk = false;

  // Daten / Update / Debug
  bool _exporting = false;
  String? _exported;
  String? _version;
  String? _appCheck, _osCheck;
  bool _checking = false;
  List<String>? _logLines;

  @override
  void initState() {
    super.initState();
    final cfg = context.read<CoachConfig>();
    final p = presetOf(cfg);
    _aiPreset = p < 0 ? 0 : p;
    _aiModel.text = p < 0 || cfg.savedModel.isEmpty ? kAiPresets[_aiPreset].model : cfg.savedModel;
    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _version = i.version);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _key.dispose();
    _aiKey.dispose();
    _aiModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final cfg = context.watch<CoachConfig>();
    final band = widget.bandState(app);
    // Shown in place of the tab content (mockup), not as its own page.
    return ListenableBuilder(
      listenable: NotionStore.instance,
      builder: (context, _) {
        final n = NotionStore.instance;
        final s = n.state;
        final synced = app.lastSynced?.tsEpoch;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
          children: [
            // ── Band ──
            const SectionHead('Band'),
            const SizedBox(height: 10),
            _card([
              _line(Dot(band.color), 'WHOOP 4.0 · ${band.label}',
                  app.device.batteryPct == null ? null : 'Akku ${app.device.batteryPct!.round()} %'),
              _row('Synchronisiert',
                  sub: synced == null || synced <= 0
                      ? 'noch keine Daten'
                      : 'Daten bis ${hhmm(DateTime.fromMillisecondsSinceEpoch(synced * 1000))}',
                  act: (app.syncingNow ? 'Läuft …' : 'Jetzt', app.syncingNow || !app.isPaired ? null : () => app.syncNow())),
              _row('Band neu koppeln', act: ('Koppeln', () => _push(const RePair()))),
            ]),
            const SizedBox(height: 22),
            // ── Notion ──
            const SectionHead('Notion'),
            const SizedBox(height: 10),
            if (!n.configured) _setup(n) else _connected(n, s),
            const SizedBox(height: 22),
            // ── KI ──
            SectionHead('KI-Berichte', hint: cfg.configured && presetOf(cfg) >= 0 ? kAiPresets[presetOf(cfg)].label : null),
            const SizedBox(height: 10),
            _ai(cfg),
            const SizedBox(height: 22),
            // ── Daten ──
            const SectionHead('Daten'),
            const SizedBox(height: 10),
            _card([
              _row('In Apple Health schreiben',
                  sub: app.healthSyncEnabled ? 'Schlaf, Puls, Workouts' : 'aus',
                  toggle: (app.healthSyncEnabled, (v) => app.setHealthSync(v))),
              _row('Export',
                  sub: _exported ?? 'Alle Werte als CSV',
                  act: (_exporting ? 'Exportiert …' : 'Exportieren', _exporting ? null : _exportCsv)),
            ]),
            const SizedBox(height: 22),
            // ── Update ──
            const SectionHead('Update'),
            const SizedBox(height: 10),
            _card([
              _row('App-Version',
                  sub: 'eigener Build, nicht veröffentlicht',
                  value: [
                    if (kOpggBuild.isNotEmpty) 'b$kOpggBuild',
                    if (kOpggSha.isNotEmpty) kOpggSha,
                    if (kOpggBuild.isEmpty && _version != null) _version!,
                  ].join(' · ')),
              _row('App-Updates',
                  sub: _appCheck ?? 'prüft dein GitHub-Repo (Branch opgg/build)',
                  act: ('Prüfen', _checking ? null : _checkUpdates)),
              _row('OpenStrap',
                  sub: _osCheck ?? 'edge auf GitHub · Version ${_version ?? '—'}',
                  act: ('Prüfen', _checking ? null : _checkUpdates)),
            ]),
            const SizedBox(height: 22),
            // ── Protokoll ──
            SectionHead('Protokoll', hint: n.log.isEmpty ? null : '${n.log.length} Einträge'),
            const SizedBox(height: 10),
            _card([
              _row('Sync-Protokoll in Notion',
                  sub: !n.configured
                      ? 'braucht eine Notion-Verbindung'
                      : n.logDs == null
                          ? 'legt die Tabelle „$kLogTitle“ an'
                          : 'jeder Eintrag landet in „$kLogTitle“',
                  toggle: (n.logToNotion, n.configured ? (v) => n.logToNotion = v : null)),
              if (n.log.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text('Noch keine Syncs.', style: O.small),
                )
              else
                for (final e in n.log.take(30))
                  _line(Dot(e.ok ? O.green : O.red, size: 6, blink: false), '${e.src} · ${e.msg}',
                      _stamp(e.t)),
            ]),
            const SizedBox(height: 22),
            // ── Debug ──
            const SectionHead('Debug'),
            const SizedBox(height: 10),
            _card([
              _row('Log', sub: 'Verlauf von Band und Sync (OpenStrap)', act: (_logLines == null ? 'Anzeigen' : 'Ausblenden', _toggleLog)),
              if (_logLines != null)
                Container(
                  margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  padding: const EdgeInsets.all(10),
                  constraints: const BoxConstraints(maxHeight: 280),
                  decoration: BoxDecoration(color: O.well, borderRadius: BorderRadius.circular(10)),
                  child: _logLines!.isEmpty
                      ? const Text('Noch keine Einträge.', style: O.small)
                      : ListView(
                          reverse: true,
                          shrinkWrap: true,
                          children: [
                            for (final l in _logLines!.reversed)
                              Text(l,
                                  style: const TextStyle(
                                      fontSize: 10, height: 1.35, color: O.ink3, fontFamily: 'Menlo')),
                          ],
                        ),
                ),
              _row('Log teilen', sub: 'als Datei, z. B. für die Fehlersuche', act: ('Teilen', _shareLog)),
              _row('OpenStrap-Einstellungen',
                  sub: 'alles Weitere, auch lokale Daten löschen', act: ('Öffnen', () => _push(const MoreSettings()))),
            ]),
            const SizedBox(height: 26),
            const Center(
              child: Text('OPGG · nicht mit WHOOP verbunden oder verwandt',
                  style: TextStyle(fontSize: 11, color: O.ink3)),
            ),
          ],
        );
      },
    );
  }

  // ── Notion ──

  String _stamp(int t) {
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    final now = DateTime.now();
    final same = d.year == now.year && d.month == now.month && d.day == now.day;
    return same ? hhmm(d) : '${wdDm(d)} ${hhmm(d)}';
  }

  Widget _setup(NotionStore n) => Container(
        padding: const EdgeInsets.all(14),
        decoration: tileDeco(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text(
              '1. Auf notion.so/profile/integrations eine interne Integration „OPGG“ anlegen.\n'
              '2. In Notion eine leere Seite „OPGG“ anlegen und über „…“ → Verbindungen '
              'mit der Integration verbinden.\n'
              '3. Den „Secret“-Schlüssel hier einfügen.',
              style: TextStyle(fontSize: 13, color: O.ink2, height: 1.45)),
          const SizedBox(height: 14),
          _field(_key, 'ntn_… oder secret_…', obscure: true),
          if (_err != null) ...[
            const SizedBox(height: 10),
            Text(_err!, style: const TextStyle(fontSize: 12, color: O.red)),
          ],
          const SizedBox(height: 12),
          OButton(_busy ? 'Verbinde …' : 'Verbinden & Tabellen anlegen',
              height: 48,
              onTap: _busy
                  ? null
                  : () async {
                      if (_key.text.trim().isEmpty) return;
                      setState(() {
                        _busy = true;
                        _err = null;
                      });
                      final e = await n.connect(_key.text);
                      if (!mounted) return;
                      setState(() {
                        _busy = false;
                        _err = e;
                        if (e == null) _key.clear();
                      });
                    }),
        ]),
      );

  Widget _connected(NotionStore n, SyncState s) => _card([
        _line(Dot(syncColor(s)), 'Verbunden mit „${n.pageTitle ?? 'OPGG'}“', syncLabel(s, n)),
        _row('Aufgaben', sub: 'Felder: Energie, Aufwand, Fällig', value: '${n.tasks.length} offen'),
        _row('Berichte', sub: n.reportsDs == null ? 'Tabelle entsteht beim ersten Speichern' : 'Tabelle „$kReportsTitle“'),
        _row('Automatisch synchronisieren', sub: 'solange die App offen ist und beim Öffnen', value: 'alle 15 min'),
        _row('Warteschlange', sub: 'Einträge, die noch nicht in Notion sind', value: '${n.queue.length} Einträge'),
        _row('Letzter Sync', value: agoLabel(n.lastOk)),
        _btn('Jetzt synchronisieren', () => n.sync(manual: true), second: ('Trennen', () async {
          final ok = await _confirm('Notion trennen?',
              'Die Tabellen in Notion bleiben erhalten. Du kannst dich jederzeit neu verbinden.', 'Trennen');
          if (ok) await n.disconnect();
        })),
      ]);

  // ── KI ──

  Widget _ai(CoachConfig cfg) {
    final cur = presetOf(cfg);
    final p = kAiPresets[_aiPreset];
    final sameProvider = cur == _aiPreset;
    final hasKey = sameProvider && cfg.hasKey;
    final other = cur < 0 && cfg.configured;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: tileDeco(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Dot(cfg.configured && cur >= 0 ? O.green : (other ? O.orange : O.grey)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                cfg.configured && cur >= 0
                    ? '${kAiPresets[cur].label} · ${cfg.savedModel}'
                    : other
                        ? 'In OpenStrap ist ein anderer Anbieter eingestellt'
                        : 'Noch kein Schlüssel',
                style: const TextStyle(fontSize: 13, color: O.ink)),
          ),
        ]),
        const SizedBox(height: 12),
        Seg(
            labels: [for (final x in kAiPresets) x.label],
            index: _aiPreset,
            height: 36,
            onPick: (i) => setState(() {
                  _aiPreset = i;
                  _aiMsg = null;
                  _aiModel.text = presetOf(cfg) == i && cfg.savedModel.isNotEmpty
                      ? cfg.savedModel
                      : kAiPresets[i].model;
                })),
        const SizedBox(height: 10),
        _field(_aiKey, hasKey ? 'Schlüssel gespeichert – leer lassen zum Behalten' : 'API-Schlüssel für ${p.label}',
            obscure: true),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _field(_aiModel, 'Modell, z. B. ${p.model.isEmpty ? 'aus der Liste' : p.model}')),
          const SizedBox(width: 8),
          SizedBox(
              width: 110,
              child: OButton('Modelle', primary: false, height: 48, onTap: _aiBusy ? null : () => _pickModel(cfg))),
        ]),
        const SizedBox(height: 6),
        const Text(
            'Alle Anbieter bekommen dieselbe Vorlage mit deinen Werten. Der Schlüssel bleibt im '
            'Schlüsselbund dieses iPhones. Ein Bericht wird nur geschrieben, wenn du auf den Stift tippst.',
            style: TextStyle(fontSize: 11, height: 1.4, color: O.ink3)),
        if (_aiMsg != null) ...[
          const SizedBox(height: 8),
          Text(_aiMsg!, style: TextStyle(fontSize: 12, color: _aiOk ? O.green : O.red)),
        ],
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
              child: OButton(_aiBusy ? 'Prüft …' : 'Speichern & testen',
                  primary: false, height: 44, onTap: _aiBusy ? null : () => _saveAi(cfg))),
          if (hasKey) ...[
            const SizedBox(width: 8),
            Expanded(
                child: OButton('Schlüssel löschen',
                    primary: false,
                    height: 44,
                    onTap: _aiBusy
                        ? null
                        : () async {
                            if (!await _confirm('Schlüssel löschen?',
                                'Danach schreibt OPGG keine Berichte mehr, bis du einen neuen einträgst.', 'Löschen')) {
                              return;
                            }
                            try {
                              await cfg.save(apiKey: '');
                              if (mounted) setState(() => (_aiMsg, _aiOk) = ('Schlüssel gelöscht.', true));
                            } catch (_) {
                              if (mounted) setState(() => (_aiMsg, _aiOk) = ('Löschen fehlgeschlagen.', false));
                            }
                          })),
          ],
        ]),
      ]),
    );
  }

  /// The key to send for [preset]: the typed one, else the stored one — but
  /// only if it belongs to the same provider (never carry a key elsewhere).
  String? _keyFor(CoachConfig cfg) {
    final typed = _aiKey.text.trim();
    if (typed.isNotEmpty) return typed;
    return presetOf(cfg) == _aiPreset && cfg.hasKey ? cfg.apiKey : null;
  }

  Future<void> _pickModel(CoachConfig cfg) async {
    final key = _keyFor(cfg);
    if (key == null) {
      setState(() => (_aiMsg, _aiOk) = ('Erst den Schlüssel eintragen.', false));
      return;
    }
    setState(() {
      _aiBusy = true;
      _aiMsg = null;
    });
    List<String> ids;
    try {
      ids = await CoachEngine.fetchModels(kAiPresets[_aiPreset].base, key);
    } catch (e) {
      if (mounted) setState(() => (_aiBusy, _aiMsg, _aiOk) = (false, 'Modelle laden fehlgeschlagen: $e', false));
      return;
    }
    if (!mounted) return;
    setState(() => _aiBusy = false);
    final pick = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: O.tile,
      builder: (c) => SafeArea(
        child: ListView(children: [
          for (final id in ids)
            ListTile(
              title: Text(id, style: const TextStyle(fontSize: 14, color: O.ink)),
              trailing: id == _aiModel.text ? const Icon(Icons.check, size: 18, color: O.ink2) : null,
              onTap: () => Navigator.of(c).pop(id),
            ),
        ]),
      ),
    );
    if (pick != null && mounted) setState(() => _aiModel.text = pick);
  }

  Future<void> _saveAi(CoachConfig cfg) async {
    final p = kAiPresets[_aiPreset];
    final typed = _aiKey.text.trim();
    final same = presetOf(cfg) == _aiPreset;
    if (typed.isEmpty && !(same && cfg.hasKey)) {
      setState(() => (_aiMsg, _aiOk) = ('Bitte den Schlüssel für ${p.label} eintragen.', false));
      return;
    }
    if (_aiModel.text.trim().isEmpty) {
      setState(() => (_aiMsg, _aiOk) = ('Bitte ein Modell wählen („Modelle“).', false));
      return;
    }
    setState(() {
      _aiBusy = true;
      _aiMsg = null;
    });
    try {
      await cfg.save(
        baseUrl: p.base,
        model: _aiModel.text.trim(),
        // A different provider never inherits the old key.
        apiKey: typed.isNotEmpty ? typed : (same ? null : ''),
        useApple: false,
        useChatGpt: false,
      );
      _aiKey.clear();
      final r = await CoachEngine.completeText(
          config: cfg, system: 'Antworte nur mit dem Wort OK.', user: 'Test', temperature: 0);
      if (!mounted) return;
      setState(() => (_aiMsg, _aiOk) =
          (r.isEmpty ? 'Gespeichert, aber leere Antwort vom Anbieter.' : 'Gespeichert · Verbindung ok.', r.isNotEmpty));
      NotionStore.instance.addLog('KI', true, '${p.label} verbunden (${cfg.savedModel})');
    } on CoachException catch (e) {
      if (mounted) setState(() => (_aiMsg, _aiOk) = ('Gespeichert, Test fehlgeschlagen: ${e.message}', false));
    } catch (e) {
      if (mounted) setState(() => (_aiMsg, _aiOk) = ('Fehlgeschlagen: $e', false));
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  // ── Daten ──

  Future<void> _exportCsv() async {
    final origin = shareOrigin(context);
    setState(() => _exporting = true);
    try {
      final res = await exportCsvFiles(kCsvExportSets);
      if (res.paths.isEmpty) {
        _exported = res.hasFailures ? 'Export fehlgeschlagen' : 'Noch nichts zu exportieren';
      } else {
        await Share.shareXFiles([for (final p in res.paths) XFile(p)],
            subject: 'OPGG Export', sharePositionOrigin: origin);
        _exported = '${res.paths.length} CSV-Dateien um ${hhmm(DateTime.now())}'
            '${res.hasFailures ? ' (${res.failed.length} fehlgeschlagen)' : ''}';
      }
    } catch (_) {
      _exported = 'Export fehlgeschlagen';
    }
    if (mounted) setState(() => _exporting = false);
  }

  // ── Update ──

  Future<void> _checkUpdates() async {
    setState(() => _checking = true);
    final t = hhmm(DateTime.now());
    Future<Map<String, dynamic>?> get(String path) async {
      try {
        final r = await http.get(Uri.parse('https://api.github.com/repos/$path'),
            headers: {'Accept': 'application/vnd.github+json'}).timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) return null;
        final j = jsonDecode(r.body);
        return j is Map ? j.cast<String, dynamic>() : null;
      } catch (_) {
        return null;
      }
    }

    final head = await get('$_kRepo/commits/opgg/build');
    final sha = '${head?['sha'] ?? ''}';
    if (head == null) {
      _appCheck = 'Prüfen fehlgeschlagen · $t';
    } else if (kOpggSha.isNotEmpty && sha.startsWith(kOpggSha)) {
      _appCheck = 'Aktuell · geprüft um $t';
    } else {
      final date = DateTime.tryParse('${head['commit']?['committer']?['date'] ?? ''}')?.toLocal();
      _appCheck = 'Neuer Stand im Repo: ${sha.length >= 7 ? sha.substring(0, 7) : sha}'
          '${date == null ? '' : ' vom ${wdDm(date)}'} · neue IPA aus dem Build-Ordner installieren';
    }
    // New commits on OpenStrap's main that opgg/build does not have yet.
    final cmp = await get('$_kRepo/compare/opgg/build...OpenStrap:main');
    final ahead = (cmp?['ahead_by'] as num?)?.toInt();
    _osCheck = ahead == null
        ? 'Prüfen fehlgeschlagen · $t'
        : ahead == 0
            ? 'Aktuell · geprüft um $t'
            : '$ahead neue Änderungen bei OpenStrap · übernimmt der Entwicklungs-Chat';
    if (mounted) setState(() => _checking = false);
  }

  // ── Debug ──

  Future<void> _toggleLog() async {
    if (_logLines != null) {
      setState(() => _logLines = null);
      return;
    }
    final path = await FileLog.path();
    // Reading and splitting up to 2 MB stays off the UI isolate.
    final lines = path == null
        ? <String>[]
        : await Isolate.run(() {
            final f = File(path);
            if (!f.existsSync()) return <String>[];
            final all = f.readAsLinesSync();
            return all.length > 200 ? all.sublist(all.length - 200) : all;
          });
    if (mounted) setState(() => _logLines = lines);
  }

  Future<void> _shareLog() async {
    final origin = shareOrigin(context);
    final path = await FileLog.path();
    if (path == null || !File(path).existsSync()) {
      OToast.instance.show('Noch kein Log vorhanden');
      return;
    }
    await Share.shareXFiles([XFile(path)], subject: 'OPGG Log', sharePositionOrigin: origin);
  }

  // ── building blocks ──

  Future<bool> _confirm(String title, String body, String yes) async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          backgroundColor: O.tile,
          title: Text(title, style: const TextStyle(fontSize: 16, color: O.ink)),
          content: Text(body, style: const TextStyle(color: O.ink2)),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(d).pop(false),
                child: const Text('Abbrechen', style: TextStyle(color: O.ink3))),
            TextButton(onPressed: () => Navigator.of(d).pop(true), child: Text(yes, style: const TextStyle(color: O.red))),
          ],
        ),
      ) ==
      true;

  Widget _field(TextEditingController c, String hint, {bool obscure = false}) => TextField(
        controller: c,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(color: O.ink, fontSize: 14),
        cursorColor: O.ink,
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          hintText: hint,
          hintStyle: const TextStyle(color: O.ink3, fontSize: 13),
          filled: true,
          fillColor: O.well,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        ),
      );

  void _push(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));

  Widget _card(List<Widget> rows) => Container(
        decoration: tileDeco(),
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1, thickness: 1, color: O.line, indent: 14),
            rows[i],
          ],
        ]),
      );

  Widget _line(Widget lead, String text, String? trailing) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(children: [
          lead,
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13, color: O.ink))),
          if (trailing != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(trailing, style: O.small),
            ),
        ]),
      );

  /// Mockup row: label + optional sub, and on the right a value, a switch or
  /// a small action button.
  Widget _row(String label,
          {String? sub,
          String? value,
          (bool, ValueChanged<bool>?)? toggle,
          (String, VoidCallback?)? act}) =>
      Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: O.ink)),
              if (sub != null) ...[
                const SizedBox(height: 2),
                Text(sub, style: const TextStyle(fontSize: 11, height: 1.35, color: O.ink3)),
              ],
            ]),
          ),
          if (value != null && value.isNotEmpty)
            Padding(padding: const EdgeInsets.only(left: 8, right: 4), child: Text(value, style: O.small)),
          if (toggle != null) _Switch(on: toggle.$1, onChanged: toggle.$2, label: label),
          if (act != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SizedBox(
                  width: 104, child: OButton(act.$1, primary: false, height: 34, onTap: act.$2)),
            ),
        ]),
      );

  /// Action row: one button, or two side by side ([second] is the quieter one).
  Widget _btn(String text, VoidCallback onTap, {(String, VoidCallback)? second}) => Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          Expanded(child: OButton(text, primary: false, height: 44, onTap: onTap)),
          if (second != null) ...[
            const SizedBox(width: 8),
            Expanded(child: OButton(second.$1, primary: false, height: 44, onTap: second.$2)),
          ],
        ]),
      );
}

/// Mockup switch: light track when on, dark knob.
class _Switch extends StatelessWidget {
  final bool on;
  final ValueChanged<bool>? onChanged;
  final String label;
  const _Switch({required this.on, required this.onChanged, required this.label});
  @override
  Widget build(BuildContext context) => Semantics(
        toggled: on,
        label: label,
        child: Opacity(
          opacity: onChanged == null ? 0.4 : 1,
          child: GestureDetector(
            onTap: onChanged == null ? null : () => onChanged!(!on),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 46,
              height: 26,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                  color: on ? O.ink : const Color(0xFF46464B), borderRadius: BorderRadius.circular(999)),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                alignment: on ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(color: on ? O.bg : O.ink, shape: BoxShape.circle),
                ),
              ),
            ),
          ),
        ),
      );
}
