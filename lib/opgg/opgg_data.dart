// Everything the OPGG screens read, loaded once per sync from the existing
// repository. No computation of metrics here: values come from OpenStrap's
// derivation as-is, and an absent value stays null (rendered "—" / "--").

import '../data/local_repository.dart';
import '../models/payloads.dart';

class OpggDay {
  final TodayData today;

  /// Daily series by metric key (getChart): t = epoch sec of the local day.
  final Map<String, List<TrendPoint>> series;
  const OpggDay(this.today, this.series);

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
];

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
  return OpggDay(today, series);
}
