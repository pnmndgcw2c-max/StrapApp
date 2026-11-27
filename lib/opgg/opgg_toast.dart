// "gespeichert · an Notion" with a 10-second "Rückgängig", as in the mockup.
// One toast at a time; a new one replaces the old (its undo lapses).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'opgg_style.dart';
import 'opgg_sync.dart' show NotionStore;

class OToast extends ChangeNotifier {
  OToast._();
  static final OToast instance = OToast._();

  String? msg;
  VoidCallback? _undo;
  int _at = 0;
  Timer? _tick;

  bool get canUndo => _undo != null;
  int get secondsLeft {
    final left = NotionStore.kUndoWindow.inMilliseconds -
        (DateTime.now().millisecondsSinceEpoch - _at);
    return (left / 1000).ceil().clamp(0, 99);
  }

  void show(String message, {VoidCallback? undo}) {
    msg = message;
    _undo = undo;
    _at = DateTime.now().millisecondsSinceEpoch;
    _tick?.cancel();
    final life = undo == null ? const Duration(seconds: 4) : NotionStore.kUndoWindow;
    _tick = Timer.periodic(const Duration(milliseconds: 250), (t) {
      if (DateTime.now().millisecondsSinceEpoch - _at >= life.inMilliseconds) {
        t.cancel();
        msg = null;
        _undo = null;
      }
      notifyListeners();
    });
    notifyListeners();
  }

  void undo() {
    final u = _undo;
    _tick?.cancel();
    msg = null;
    _undo = null;
    notifyListeners();
    if (u != null) {
      HapticFeedback.mediumImpact();
      u();
    }
  }
}

/// Bottom toast bar; place it in the shell's Stack.
class ToastBar extends StatelessWidget {
  final Color dot;
  const ToastBar({super.key, required this.dot});
  @override
  Widget build(BuildContext context) {
    final t = OToast.instance;
    return ListenableBuilder(
      listenable: t,
      builder: (context, _) {
        final m = t.msg;
        return AnimatedPositioned(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          left: 16,
          right: 16,
          bottom: m == null ? -90 : 26 + MediaQuery.of(context).padding.bottom,
          child: m == null
              ? const SizedBox.shrink()
              : Container(
                  padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                  constraints: const BoxConstraints(minHeight: 52),
                  decoration: BoxDecoration(
                    color: O.raised,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: const [
                      BoxShadow(color: Color(0x80000000), blurRadius: 30, offset: Offset(0, 12))
                    ],
                  ),
                  child: Row(children: [
                    Dot(dot, blink: false),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(m, style: const TextStyle(fontSize: 13, color: O.ink))),
                    if (t.canUndo)
                      GestureDetector(
                        onTap: t.undo,
                        child: Container(
                          height: 36,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [O.ink, Color(0xFFE2E2E5)]),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('Rückgängig ${t.secondsLeft} s',
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: O.bg,
                                  fontFeatures: O.tabular)),
                        ),
                      ),
                  ]),
                ),
        );
      },
    );
  }
}
