// OPGG settings: band, Notion connection, sync protocol, and the way into
// OpenStrap's own settings. The Notion key is typed here and goes straight to
// the keychain.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../ui2/profile/devices.dart' show RePair;
import '../ui2/profile/settings.dart' show MoreSettings;
import 'opgg_style.dart';
import 'opgg_sync.dart';

Color syncColor(SyncState s) => switch (s) {
      SyncState.off => O.grey,
      SyncState.syncing => O.ink,
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

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final band = widget.bandState(app);
    return Scaffold(
      backgroundColor: O.bg,
      appBar: AppBar(
        backgroundColor: O.bg,
        foregroundColor: O.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('Einstellungen', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: ListenableBuilder(
        listenable: NotionStore.instance,
        builder: (context, _) {
          final n = NotionStore.instance;
          final s = n.state;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              const SectionHead('Band'),
              const SizedBox(height: 10),
              _card([
                _line(Dot(band.color), 'Band ${band.label}',
                    app.device.batteryPct == null ? null : 'Akku ${app.device.batteryPct!.round()} %'),
                _tap('Band koppeln oder wechseln',
                    () => _push(const RePair())),
              ]),
              const SizedBox(height: 22),
              const SectionHead('Notion'),
              const SizedBox(height: 10),
              if (!n.configured) _setup(n) else _connected(n, s),
              const SizedBox(height: 22),
              SectionHead('Protokoll', hint: n.log.isEmpty ? null : '${n.log.length} Einträge'),
              const SizedBox(height: 10),
              _card([
                if (n.log.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(14),
                    child: Text('Noch keine Syncs.', style: O.small),
                  )
                else
                  for (final e in n.log.take(30))
                    _line(
                        Dot(e.ok ? O.green : O.red, size: 6, blink: false),
                        '${e.src} · ${e.msg}',
                        _stamp(e.t)),
              ]),
              const SizedBox(height: 22),
              const SectionHead('Erweitert'),
              const SizedBox(height: 10),
              _card([
                _tap('OpenStrap-Einstellungen', () => _push(const MoreSettings())),
              ]),
            ],
          );
        },
      ),
    );
  }

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
          TextField(
            controller: _key,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(color: O.ink),
            cursorColor: O.ink,
            decoration: InputDecoration(
              hintText: 'ntn_… oder secret_…',
              hintStyle: const TextStyle(color: O.ink3),
              filled: true,
              fillColor: O.well,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
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
        _line(const SizedBox(width: 7), 'Letzter Sync', agoLabel(n.lastOk)),
        _line(const SizedBox(width: 7), 'Offene Aufgaben', '${n.tasks.length}'),
        _tap('Jetzt synchronisieren', () => n.sync(manual: true)),
        _tap('Trennen', () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (d) => AlertDialog(
              backgroundColor: O.tile,
              title: const Text('Notion trennen?', style: TextStyle(fontSize: 16, color: O.ink)),
              content: const Text(
                  'Die Tabellen in Notion bleiben erhalten. Du kannst dich jederzeit neu verbinden.',
                  style: TextStyle(color: O.ink2)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(d).pop(false),
                    child: const Text('Abbrechen', style: TextStyle(color: O.ink3))),
                TextButton(
                    onPressed: () => Navigator.of(d).pop(true),
                    child: const Text('Trennen', style: TextStyle(color: O.red))),
              ],
            ),
          );
          if (ok == true) await n.disconnect();
        }, danger: true),
      ]);

  void _push(Widget w) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));

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

  Widget _tap(String text, VoidCallback onTap, {bool danger = false}) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          child: Row(children: [
            Expanded(
                child: Text(text,
                    style: TextStyle(fontSize: 14, color: danger ? O.red : O.ink))),
            if (!danger) const Icon(Icons.chevron_right, size: 18, color: O.ink3),
          ]),
        ),
      );
}
