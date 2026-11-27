// Everything the OPGG screens read, loaded once per sync from the existing
// repository. No computation of metrics here: values come from OpenStrap's
// derivation as-is, and an absent value stays null (rendered "—" / "--").

import '../data/db.dart' show LocalDb;
import '../data/local_repository.dart';
import '../models/payloads.dart';

class OpggDay {
  final TodayData today;

  /// Daily series by metric key (getChart): t = epoch sec of the local day.
  final Map<String, List<TrendPoint>> series;

  /// Today's heart rate in 5-minute buckets: (minute of day, bpm).
  final List<(int, double)> hr;

  /// Most recent night's window (epoch seconds), null when unknown.
  final ({int onset, int wake})? night;

  /// Workouts that touch today (OpenStrap sessions table).
  final List<Map<String, dynamic>> workouts;

  const OpggDay(this.today, this.series,
      {this.hr = const [], this.night, this.workouts = const []});

  /// Average of today's HR buckets between two minutes of the day.
  double? hrAvg(int fromMin, int toMin) {
    var n = 0, sum = 0.0;
    for (final (m, v) in hr) {
      if (m >= fromMin && m <= toMin) {
        n++;
        sum += v;
      }
    }
    return n == 0 ? null : sum / n;
  }

  /// Value of [key] on the local day [day] (midnight), or null.
  double? on(String key, DateTime day) {
    final pts = series[key];
    if (pts == null) return null;
    for (final p in pts) {
      final d = DateTime.fromMillisecondsSinceEpoch(p.t * 1000);
      if (d.year == day.year && d.month == day.month && d.day == day.day) {
        return p.v;
      }
    }
    return null;
  }

  /// Newest value of [key] if it belongs to today or the last [maxAgeDays]
  /// days, with its local day. Used where the Today bundle still withholds a
  /// night that the derive already stored (it waits ~1 h past wake): the value
  /// is the real stored one, shown with its date — never a substitute.
  ({double v, DateTime day})? recent(String key, {int maxAgeDays = 1}) {
    final p = latest(key);
    if (p == null) return null;
    final d = DateTime.fromMillisecondsSinceEpoch(p.t * 1000);
    final now = DateTime.now();
    final age = DateTime(now.year, now.month, now.day)
        .difference(DateTime(d.year, d.month, d.day))
        .inDays;
    if (age < 0 || age > maxAgeDays) return null;
    return (v: p.v, day: DateTime(d.year, d.month, d.day));
  }

  /// Newest point of [key], or null.
  TrendPoint? latest(String key) {
    final pts = series[key];
    if (pts == null || pts.isEmpty) return null;
    return pts.reduce((a, b) => a.t >= b.t ? a : b);
  }
}

/// Metric keys understood by `getChart` (see `_trendKey`).
const kSeriesKeys = [
  'recovery', // readiness 0–100
  'hrv', // rmssd ms
  'resting_hr', // bpm
  'sleep', // time asleep, minutes
  'deep', // deep sleep, minutes
  'light',
  'rem',
  'efficiency', // sleep efficiency %
  'stress', // 0–100 (Baevsky SI over the scored night)
  'resp_rate', // breaths/min
  'skin_temp_z', // skin temperature vs. personal norm (z)
];

/// Today's HR averaged into [bucketSec] buckets, straight from the band's
/// 1 Hz table (worn seconds only) — the database does the averaging.
Future<List<(int, double)>> loadHrBuckets(DateTime day, {int bucketSec = 300}) async {
  final start = DateTime(day.year, day.month, day.day);
  final from = start.millisecondsSinceEpoch ~/ 1000;
  final to = DateTime(day.year, day.month, day.day + 1).millisecondsSinceEpoch ~/ 1000;
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
      'SELECT (rec_ts - ?) / ? AS b, AVG(hr) AS v FROM decoded_onehz '
      'WHERE rec_ts >= ? AND rec_ts < ? AND hr > 0 GROUP BY b ORDER BY b',
      [from, bucketSec, from, to]);
  return [
    for (final r in rows)
      if (r['v'] != null)
        (((r['b'] as num).toInt() * bucketSec) ~/ 60, (r['v'] as num).toDouble()),
  ];
}

Future<OpggDay> loadOpggDay(LocalRepository? repo) async {
  if (repo == null) return OpggDay(TodayData.fromJson(const {}), const {});
  TodayData today;
  try {
    today = TodayData.fromJson(await repo.getToday());
  } catch (_) {
    today = TodayData.fromJson(const {});
  }
  final series = <String, List<TrendPoint>>{};
  for (final k in kSeriesKeys) {
    try {
      series[k] = ChartSeries.fromJson(await repo.getChart(k)).points;
    } catch (_) {
      series[k] = const [];
    }
  }
  final now = DateTime.now();
  List<(int, double)> hr = const [];
  try {
    hr = await loadHrBuckets(now);
  } catch (_) {}
  ({int onset, int wake})? night;
  try {
    final w = await repo.sleepWindows(days: 2);
    // The newest night (latest wake) wins.
    for (final e in w) {
      final on = (e['onset_ts'] as num?)?.toInt(), wk = (e['wake_ts'] as num?)?.toInt();
      if (on != null && wk != null && (night == null || wk > night.wake)) {
        night = (onset: on, wake: wk);
      }
    }
  } catch (_) {}
  List<Map<String, dynamic>> workouts = const [];
  try {
    final from = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch ~/ 1000;
    workouts = await repo.getSessions(from: from, includeDetected: false);
  } catch (_) {}
  return OpggDay(today, series, hr: hr, night: night, workouts: workouts);
}
