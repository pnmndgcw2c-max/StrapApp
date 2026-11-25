// OPGG shell: fixed top bar (tab logo, tab menu with status dot, band pill,
// settings), Heute/Woche/Monat pager, and the tabs. Built on the existing
// OpenStrap engine — every value is read from AppState / the repository.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../ui2/profile/devices.dart' show RePair;
import '../ui2/profile/settings.dart' show MoreSettings;
import '../ui2/screens/health_screen.dart' show HealthScreen;
import '../ui2/screens/workout_screen.dart' show WorkoutScreen;
import 'opgg_data.dart';
import 'opgg_overview.dart';
import 'opgg_sleep.dart';
import 'opgg_style.dart';

enum OTab {
  overview('Überblick', 'Energie, Biomarker, Tag', Icons.change_history_rounded, true),
  tasks('Aufgaben', 'Notion – kommt in Etappe 2', Icons.check_box_outlined, false),
  fitness('Fitness', 'Workouts – kommt in Etappe 3', Icons.fitness_center, false),
  focus('Fokus', 'Lern-Sessions – kommt in Etappe 2', Icons.timer_outlined, false),
  body('Körper', 'Körperwerte – kommt in Etappe 3', Icons.monitor_weight_outlined, false),
  sleep('Schlaf', 'Nacht, Wecker, Wind-down', Icons.dark_mode_rounded, true);

  const OTab(this.label, this.hint, this.icon, this.hasTrend);
  final String label;
  final String hint;
  final IconData icon;
  final bool hasTrend;
}

class OpggShell extends StatefulWidget {
  const OpggShell({super.key});
  @override
  State<OpggShell> createState() => _OpggShellState();
}

class _OpggShellState extends State<OpggShell> {
  OTab _tab = OTab.overview;
  int _page = 0;
  final _pager = PageController();
  bool _menu = false;
  bool _bandPop = false;
  Future<OpggDay>? _data;
  int? _syncKey;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  void _go(OTab t) {
    setState(() {
      _tab = t;
      _menu = false;
      _page = 0;
    });
    if (_pager.hasClients) _pager.jumpToPage(0);
  }

  void _goPage(int i) {
    setState(() => _page = i);
    if (_pager.hasClients) {
      _pager.animateToPage(i,
          duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    // Reload the derived data whenever a sync lands (newest sample moved).
    final key = app.lastSynced?.tsEpoch ?? -1;
    if (_data == null || key != _syncKey) {
      _syncKey = key;
      _data = loadOpggDay(app.repo);
    }

    final pages = _tab.hasTrend ? const ['Heute', 'Woche', 'Monat'] : const <String>[];

    return Scaffold(
      backgroundColor: O.bg,
      body: Stack(children: [
        Column(children: [
          _TopBar(
            tab: _tab,
            app: app,
            onMenu: () => setState(() {
              _menu = !_menu;
              _bandPop = false;
            }),
            onBand: () => setState(() {
              _bandPop = !_bandPop;
              _menu = false;
            }),
            onBandHold: () {
              if (app.isPaired) app.syncNow();
            },
            onSettings: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => const MoreSettings())),
            pages: pages,
            page: _page,
            onPage: _goPage,
          ),
          Expanded(
            child: FutureBuilder<OpggDay>(
              future: _data,
              builder: (c, snap) {
                final d = snap.data;
                if (d == null) {
                  return const Center(
                      child: CircularProgressIndicator(color: O.ink3, strokeWidth: 2));
                }
                return _body(d, app);
              },
            ),
          ),
        ]),
        if (_menu || _bandPop)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() {
                _menu = false;
                _bandPop = false;
              }),
              child: Container(color: Colors.black.withValues(alpha: _menu ? .4 : 0)),
            ),
          ),
        if (_menu) _TabMenu(current: _tab, onPick: _go),
        if (_bandPop) _BandPopover(app: app),
      ]),
    );
  }

  Widget _body(OpggDay d, AppState app) {
    if (!app.isPaired) {
      return _Placeholder(
        icon: Icons.watch_outlined,
        title: 'Kein Band gekoppelt',
        text: 'Ohne Band wird nichts gemessen.',
        action: 'Band koppeln',
        onAction: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => const RePair())),
      );
    }
    switch (_tab) {
      case OTab.overview:
      case OTab.sleep:
        final today = _tab == OTab.overview
            ? OverviewToday(day: d)
            : SleepToday(day: d);
        return PageView(
          controller: _pager,
          onPageChanged: (i) => setState(() => _page = i),
          children: [
            today,
            for (final n in const [7, 30])
              _tab == OTab.overview
                  ? OverviewPeriod(day: d, n: n)
                  : SleepPeriod(day: d, n: n),
          ],
        );
      case OTab.fitness:
        return _Placeholder(
          icon: OTab.fitness.icon,
          title: 'Fitness kommt in Etappe 3',
          text: 'Bis dahin kannst du Workouts in der bisherigen Ansicht starten.',
          action: 'Bisherige Ansicht öffnen',
          onAction: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: SafeArea(child: WorkoutScreen())))),
        );
      case OTab.body:
        return _Placeholder(
          icon: OTab.body.icon,
          title: 'Körper kommt in Etappe 3',
          text: 'Die Gesundheitswerte von OpenStrap findest du bis dahin hier.',
          action: 'Bisherige Ansicht öffnen',
          onAction: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: SafeArea(child: HealthScreen())))),
        );
      case OTab.tasks:
      case OTab.focus:
        return _Placeholder(
          icon: _tab.icon,
          title: '${_tab.label} kommt in Etappe 2',
          text: 'Mit Notion-Anbindung, Fortschritt und Sync-Status.',
        );
    }
  }
}

// ── top bar ────────────────────────────────────────────────────────────────

({Color color, String label}) bandState(AppState app) {
  if (!app.isPaired) return (color: O.grey, label: 'kein Band');
  if (app.syncingNow) return (color: O.ink, label: 'synchronisiert');
  return switch (app.device.connection) {
    'connected' => ((app.device.batteryPct ?? 100) < 20)
        ? (color: O.orange, label: 'Akku fast leer')
        : (color: O.green, label: 'verbunden'),
    'connecting' || 'scanning' => (color: O.orange, label: 'verbindet'),
    _ => (color: O.red, label: 'getrennt'),
  };
}

class _TopBar extends StatelessWidget {
  final OTab tab;
  final AppState app;
  final VoidCallback onMenu, onBand, onBandHold, onSettings;
  final List<String> pages;
  final int page;
  final ValueChanged<int> onPage;
  const _TopBar({
    required this.tab,
    required this.app,
    required this.onMenu,
    required this.onBand,
    required this.onBandHold,
    required this.onSettings,
    required this.pages,
    required this.page,
    required this.onPage,
  });

  @override
  Widget build(BuildContext context) {
    final band = bandState(app);
    return Container(
      decoration: const BoxDecoration(
        color: O.bg,
        border: Border(bottom: BorderSide(color: Color(0xFF2A2A2D))),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(children: [
          SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
              child: Row(children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF424246), O.raised2]),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(tab.icon, size: 16, color: O.ink),
                ),
                const SizedBox(width: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: onMenu,
                  child: Ink(
                    height: 36,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFF36363A), Color(0xFF2A2A2D)]),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(children: [
                      Text(tab.label,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600, color: O.ink)),
                      const SizedBox(width: 8),
                      // Status dot: green = nothing to do (to-dos arrive in Etappe 2).
                      const Dot(O.green),
                    ]),
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: onBand,
                  onLongPress: onBandHold,
                  child: Container(
                    height: 28,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                        color: O.pill, borderRadius: BorderRadius.circular(999)),
                    child: Row(children: [
                      Dot(band.color),
                      const SizedBox(width: 6),
                      const Text('Band',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600, color: O.ink2)),
                    ]),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 40,
                  height: 40,
                  child: IconButton(
                    onPressed: onSettings,
                    tooltip: 'Einstellungen',
                    style: IconButton.styleFrom(backgroundColor: O.raised2),
                    icon: const Icon(Icons.settings_outlined, size: 18, color: O.ink2),
                  ),
                ),
              ]),
            ),
          ),
          if (pages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 2, 24, 10),
              child: Seg(labels: pages, index: page, onPick: onPage, height: 32),
            ),
        ]),
      ),
    );
  }
}

class _TabMenu extends StatelessWidget {
  final OTab current;
  final ValueChanged<OTab> onPick;
  const _TabMenu({required this.current, required this.onPick});
  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top + 46;
    return Positioned(
      top: top,
      left: 48,
      width: 270,
      child: Material(
        color: O.pill,
        borderRadius: BorderRadius.circular(14),
        elevation: 12,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final t in OTab.values)
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onPick(t),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Row(children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                          color: const Color(0xFF3E3E42),
                          borderRadius: BorderRadius.circular(9)),
                      child: Icon(t.icon, size: 17, color: O.ink),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t.label, style: O.body),
                        Text(t.hint, style: O.small),
                      ]),
                    ),
                    if (t == current) const Icon(Icons.check, size: 16, color: O.ink),
                  ]),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _BandPopover extends StatelessWidget {
  final AppState app;
  const _BandPopover({required this.app});
  @override
  Widget build(BuildContext context) {
    final band = bandState(app);
    final top = MediaQuery.of(context).padding.top + 44;
    final batt = app.device.batteryPct;
    final last = app.lastSynced?.tsEpoch;
    final hr = app.liveHr;
    return Positioned(
      top: top,
      right: 56,
      width: 240,
      child: Material(
        color: O.pill,
        borderRadius: BorderRadius.circular(14),
        elevation: 12,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Dot(band.color, size: 8),
              const SizedBox(width: 7),
              Text('Band ${band.label}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: O.ink)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              _stat('Akku', batt == null ? '—' : '${batt.round()} %'),
              _stat('Puls', hr == null ? '—' : '$hr'),
              _stat('Daten bis',
                  last == null ? '—' : hhmm(DateTime.fromMillisecondsSinceEpoch(last * 1000))),
            ]),
            const SizedBox(height: 8),
            const Text('Gedrückt halten: Daten jetzt abholen',
                style: TextStyle(fontSize: 11, color: O.ink3)),
          ]),
        ),
      ),
    );
  }

  Widget _stat(String l, String v) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l, style: const TextStyle(fontSize: 10, color: O.ink3)),
          Text(v,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: O.ink, fontFeatures: O.tabular)),
        ]),
      );
}

class _Placeholder extends StatelessWidget {
  final IconData icon;
  final String title, text;
  final String? action;
  final VoidCallback? onAction;
  const _Placeholder(
      {required this.icon, required this.title, required this.text, this.action, this.onAction});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: O.ink3),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: O.ink)),
            const SizedBox(height: 6),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: O.ink3)),
            if (action != null) ...[
              const SizedBox(height: 18),
              SizedBox(width: 240, child: OButton(action!, onTap: onAction, primary: false, height: 46)),
            ],
          ]),
        ),
      );
}
