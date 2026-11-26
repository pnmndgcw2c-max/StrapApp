// OPGG shell: fixed top bar (tab logo, tab menu with status dot, band pill,
// settings), Heute/Woche/Monat pager, and the tabs. Built on the existing
// OpenStrap engine — every value is read from AppState / the repository.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../ui2/profile/devices.dart' show RePair;
import '../ui2/screens/health_screen.dart' show HealthScreen;
import '../ui2/screens/workout_screen.dart' show WorkoutScreen;
import 'opgg_data.dart';
import 'opgg_focus.dart';
import 'opgg_overview.dart';
import 'opgg_sleep.dart';
import 'opgg_settings.dart';
import 'opgg_style.dart';
import 'opgg_sync.dart';
import 'opgg_tasks.dart';

enum OTab {
  overview('Überblick', 'Energie, Biomarker, Tag', Icons.change_history_rounded, true),
  tasks('Aufgaben', 'aus Notion, nach Energie', Icons.check_box_outlined, true),
  fitness('Fitness', 'Workouts – kommt in Etappe 3', Icons.fitness_center, false),
  focus('Fokus', 'Sessions mit Pausen', Icons.timer_outlined, true),
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
  bool _syncPop = false;
  int _bandLogAt = 0;
  bool _holdSync = false, _holdBand = false; // orange while a held sync runs
  Future<OpggDay>? _data;
  int? _syncKey;

  final _focus = FocusStore.instance;
  final _notion = NotionStore.instance;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _focus.buzz = app.buzzBand;
    _focus.addListener(_onFocus);
    _notion.addListener(_onFocus);
  }

  void _onFocus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _notion.removeListener(_onFocus);
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

  void _closePops() {
    _menu = false;
    _bandPop = false;
    _syncPop = false;
  }

  void _settings() => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const OpggSettings(bandState: bandState)));

  void _startTask(OTask t) {
    HapticFeedback.mediumImpact();
    _focus.startTask(t.id, t.name); // no-op while a session runs
    _go(OTab.focus);
  }

  /// Status dot of the current tab: orange = something open.
  Color _tabDot() => switch (_tab) {
        OTab.focus => _focus.phase == FPhase.paused ? O.orange : O.green,
        OTab.tasks => _notion.started.isNotEmpty ? O.orange : O.green,
        _ => O.green,
      };

  /// Hold-to-sync: buzz, show orange for at least a second, buzz twice when done.
  Future<void> _held(Future<void> Function() work, void Function(bool) flag) async {
    await HapticFeedback.heavyImpact();
    setState(() => flag(true));
    await Future.wait([work(), Future<void>.delayed(const Duration(milliseconds: 1000))]);
    if (!mounted) return;
    setState(() => flag(false));
    await HapticFeedback.mediumImpact();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await HapticFeedback.mediumImpact();
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
      // Band syncs go to the Protokoll — at most every 30 min, not per drain.
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_syncKey != null && key > 0 && now - _bandLogAt > 30 * 60000) {
        _bandLogAt = now;
        _notion.addLog('Band', true,
            'Daten bis ${hhmm(DateTime.fromMillisecondsSinceEpoch(key * 1000))}');
      }
      _syncKey = key;
      _data = loadOpggDay(app.repo);
    }

    final pages = _tab.hasTrend ? const ['Heute', 'Woche', 'Monat'] : const <String>[];

    return Scaffold(
      backgroundColor: O.bg,
      body: Stack(children: [
        Column(children: [
          _TopBar(
            dot: _tabDot(),
            tab: _tab,
            app: app,
            sync: _notion.state,
            holdSync: _holdSync,
            holdBand: _holdBand,
            onMenu: () => setState(() {
              final v = !_menu;
              _closePops();
              _menu = v;
            }),
            onBand: () => setState(() {
              final v = !_bandPop;
              _closePops();
              _bandPop = v;
            }),
            onSync: () => setState(() {
              final v = !_syncPop;
              _closePops();
              _syncPop = v;
            }),
            onSyncHold: () => _held(() async {
                  if (app.isPaired) {
                    try {
                      await app.syncNow();
                    } catch (_) {}
                  }
                  await _notion.sync(manual: true);
                }, (v) => _holdSync = v),
            onBandHold: () => _held(() async {
                  if (!app.isPaired) return;
                  try {
                    await app.syncNow();
                  } catch (_) {}
                }, (v) => _holdBand = v),
            onSettings: _settings,
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
        if (_menu || _bandPop || _syncPop)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(_closePops),
              child: Container(color: Colors.black.withValues(alpha: _menu ? .4 : 0)),
            ),
          ),
        if (_menu)
          _TabMenu(
              current: _tab,
              onPick: _go,
              focus: _focus.phase,
              tasksOpen: _notion.started.isNotEmpty),
        if (_bandPop) _BandPopover(app: app),
        if (_syncPop) _SyncPopover(n: _notion),
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
      case OTab.focus:
      case OTab.tasks:
        final Widget today = switch (_tab) {
          OTab.tasks => TasksPage(
              energy: Energy.of(d).total, onStart: _startTask, onSettings: _settings),
          OTab.overview =>
            OverviewToday(day: d, onStart: _startTask, onTasks: () => _go(OTab.tasks)),
          OTab.sleep => SleepToday(day: d),
          _ => FocusToday(energy: Energy.of(d).total),
        };
        return PageView(
          controller: _pager,
          onPageChanged: (i) => setState(() => _page = i),
          children: [
            today,
            for (final n in const [7, 30])
              switch (_tab) {
                OTab.overview => OverviewPeriod(day: d, n: n),
                OTab.sleep => SleepPeriod(day: d, n: n),
                OTab.tasks => TasksPeriod(n: n),
                _ => FocusPeriod(n: n),
              },
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
    }
  }
}

/// Rounded header button with the same border everywhere.
class _Pill extends StatefulWidget {
  final List<Widget> children;
  final VoidCallback? onTap, onLongPress;
  final double height;
  final EdgeInsets padding;
  const _Pill(
      {required this.children,
      this.onTap,
      this.onLongPress,
      this.height = 30,
      this.padding = const EdgeInsets.symmetric(horizontal: 10)});
  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> with SingleTickerProviderStateMixin {
  // A short damped wiggle as visual confirmation of a long press.
  late final AnimationController _w =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 520));

  @override
  void dispose() {
    _w.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                _w.forward(from: 0);
                widget.onLongPress!();
              },
        child: AnimatedBuilder(
          animation: _w,
          builder: (context, child) {
            final t = _w.value;
            return Transform.rotate(
                angle: math.sin(t * math.pi * 6) * 0.09 * (1 - t), child: child);
          },
          child: Container(
            height: widget.height,
            padding: widget.padding,
            decoration: BoxDecoration(
              color: O.pill,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: O.line),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: widget.children),
          ),
        ),
      );
}

// ── top bar ────────────────────────────────────────────────────────────────

({Color color, String label}) bandState(AppState app) {
  if (!app.isPaired) return (color: O.grey, label: 'kein Band');
  if (app.syncingNow) return (color: O.orange, label: 'synchronisiert gerade');
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
  final VoidCallback onMenu, onBand, onBandHold, onSettings, onSync, onSyncHold;
  final SyncState sync;
  final bool holdSync, holdBand;
  final List<String> pages;
  final int page;
  final ValueChanged<int> onPage;
  final Color dot;
  const _TopBar({
    required this.dot,
    required this.tab,
    required this.app,
    required this.onMenu,
    required this.onBand,
    required this.onBandHold,
    required this.onSync,
    required this.onSyncHold,
    required this.sync,
    required this.holdSync,
    required this.holdBand,
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
                _Pill(
                  onTap: onMenu,
                  height: 34,
                  padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
                  children: [
                    Text(tab.label,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600, color: O.ink)),
                    const SizedBox(width: 8),
                    // Status dot: green = all good, orange = something open.
                    Dot(dot),
                  ],
                ),
                const Spacer(),
                _Pill(
                  onTap: onSync,
                  onLongPress: onSyncHold,
                  children: [
                    Dot(holdSync ? O.orange : syncColor(sync)),
                    const SizedBox(width: 6),
                    const Text('Sync',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600, color: O.ink2)),
                  ],
                ),
                const SizedBox(width: 6),
                _Pill(
                  onTap: onBand,
                  onLongPress: onBandHold,
                  children: [
                    Dot(holdBand ? O.orange : band.color),
                    const SizedBox(width: 6),
                    const Text('Band',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600, color: O.ink2)),
                  ],
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 40,
                  height: 40,
                  child: IconButton(
                    onPressed: onSettings,
                    tooltip: 'Einstellungen',
                    style: IconButton.styleFrom(
                        backgroundColor: O.pill,
                        side: const BorderSide(color: O.line)),
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
  final FPhase focus;
  final bool tasksOpen;
  const _TabMenu(
      {required this.current, required this.onPick, required this.focus, required this.tasksOpen});
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
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Material(
                  color: t == current ? const Color(0xFF232326) : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
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
                        if (t == OTab.tasks && tasksOpen) const Dot(O.orange),
                        if (t == OTab.focus && focus != FPhase.idle)
                          Dot(focus == FPhase.running ? O.green : O.orange),
                      ]),
                    ),
                  ),
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

class _SyncPopover extends StatelessWidget {
  final NotionStore n;
  const _SyncPopover({required this.n});
  @override
  Widget build(BuildContext context) {
    final st = n.state;
    final top = MediaQuery.of(context).padding.top + 44;
    return Positioned(
      top: top,
      right: 110,
      width: 240,
      child: Material(
        color: O.pill,
        borderRadius: BorderRadius.circular(14),
        elevation: 12,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Dot(syncColor(st), size: 8),
              const SizedBox(width: 7),
              Expanded(
                child: Text(st == SyncState.off ? 'Notion nicht verbunden' : 'Notion ${syncLabel(st, n)}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: O.ink)),
              ),
            ]),
            const SizedBox(height: 8),
            Text('Letzter Sync ${agoLabel(n.lastOk)} · ${n.queue.length} ausstehend',
                style: const TextStyle(fontSize: 12, color: O.ink2)),
            const SizedBox(height: 8),
            const Text('Gedrückt halten: Band und Notion jetzt abgleichen',
                style: TextStyle(fontSize: 11, color: O.ink3)),
          ]),
        ),
      ),
    );
  }
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
