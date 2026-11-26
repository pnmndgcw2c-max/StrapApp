// Minimal Notion REST client for OPGG (API version 2025-09-03: databases are
// containers, rows live in data sources). Only what OPGG needs: find the
// shared "OPGG" page, create the two databases on it, query and write rows.
//
// The integration secret is entered in the app and kept in the iOS keychain;
// it is never part of the repo or of any log line.

import 'dart:convert';

import 'package:http/http.dart' as http;

const kNotionVersion = '2025-09-03';

class NotionError implements Exception {
  final int status;
  final String code, message;
  NotionError(this.status, this.code, this.message);

  /// Short German text for the UI.
  String get human => switch (status) {
        0 => 'Keine Verbindung zu Notion',
        401 => 'Schlüssel ungültig',
        403 => 'Integration hat keinen Zugriff',
        404 => 'Nicht gefunden – ist die Seite mit OPGG verbunden?',
        409 => 'Notion war beschäftigt, nächster Versuch folgt',
        429 => 'Zu viele Anfragen, kurz warten',
        _ => 'Notion-Fehler ($status)',
      };

  @override
  String toString() => 'NotionError($status $code: $message)';
}

class NotionApi {
  final String token;
  final http.Client _c;
  NotionApi(this.token, {http.Client? client}) : _c = client ?? http.Client();

  static final _base = Uri.parse('https://api.notion.com/v1/');

  Future<Map<String, dynamic>> _call(String method, String path,
      [Map<String, Object?>? body]) async {
    final req = http.Request(method, _base.resolve(path))
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Notion-Version': kNotionVersion,
        'Content-Type': 'application/json',
      });
    if (body != null) req.body = jsonEncode(body);
    http.StreamedResponse res;
    try {
      res = await _c.send(req).timeout(const Duration(seconds: 20));
    } catch (e) {
      throw NotionError(0, 'network', '$e');
    }
    final text = await res.stream.bytesToString();
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      j = {};
    }
    if (res.statusCode >= 300) {
      throw NotionError(res.statusCode, '${j['code'] ?? ''}', '${j['message'] ?? text}');
    }
    return j;
  }

  /// Bot user — a cheap "is the key valid" check.
  Future<Map<String, dynamic>> me() => _call('GET', 'users/me');

  /// Pages shared with the integration, best title match first.
  Future<List<({String id, String title})>> searchPages(String query) async {
    final j = await _call('POST', 'search', {
      'query': query,
      'filter': {'property': 'object', 'value': 'page'},
      'page_size': 25,
    });
    return [
      for (final r in (j['results'] as List? ?? const []))
        if (r is Map && r['object'] == 'page' && r['archived'] != true && r['in_trash'] != true)
          (id: '${r['id']}', title: pageTitle(r)),
    ];
  }

  /// Data sources shared with the integration whose title matches.
  Future<List<({String id, String title, String? parentPage})>> searchDataSources(
      String query) async {
    final j = await _call('POST', 'search', {
      'query': query,
      'filter': {'property': 'object', 'value': 'data_source'},
      'page_size': 25,
    });
    return [
      for (final r in (j['results'] as List? ?? const []))
        if (r is Map && r['archived'] != true && r['in_trash'] != true)
          (
            id: '${r['id']}',
            title: richText(r['title']),
            parentPage: _parentPage(r),
          ),
    ];
  }

  static String? _parentPage(Map r) {
    // A data source's parent is its database; the database's parent the page.
    final dp = r['database_parent'];
    if (dp is Map && dp['type'] == 'page_id') return '${dp['page_id']}';
    final p = r['parent'];
    if (p is Map && p['type'] == 'page_id') return '${p['page_id']}';
    return null;
  }

  /// Creates a database under [pageId]; returns its first data source id.
  Future<String> createDatabase(
      String pageId, String title, String emoji, Map<String, Object?> properties) async {
    final j = await _call('POST', 'databases', {
      'parent': {'type': 'page_id', 'page_id': pageId},
      'title': [
        {
          'type': 'text',
          'text': {'content': title}
        }
      ],
      'icon': {'type': 'emoji', 'emoji': emoji},
      'initial_data_source': {'properties': properties},
    });
    String? first(Map m) {
      final ds = m['data_sources'];
      return ds is List && ds.isNotEmpty && ds.first is Map ? '${ds.first['id']}' : null;
    }

    final id = first(j) ?? first(await _call('GET', 'databases/${j['id']}'));
    if (id != null) return id;
    throw NotionError(500, 'no_data_source', 'database created without data source');
  }

  /// All rows of a data source matching [filter] (follows pagination).
  Future<List<Map<String, dynamic>>> query(String dataSourceId,
      {Map<String, Object?>? filter, List<Map<String, Object?>>? sorts}) async {
    final out = <Map<String, dynamic>>[];
    String? cursor;
    do {
      final j = await _call('POST', 'data_sources/$dataSourceId/query', {
        'filter': ?filter,
        'sorts': ?sorts,
        'page_size': 100,
        'start_cursor': ?cursor,
      });
      for (final r in (j['results'] as List? ?? const [])) {
        if (r is Map) out.add(r.cast<String, dynamic>());
      }
      cursor = j['has_more'] == true ? j['next_cursor'] as String? : null;
    } while (cursor != null && out.length < 1000);
    return out;
  }

  Future<String> createPage(String dataSourceId, Map<String, Object?> properties) async {
    final j = await _call('POST', 'pages', {
      'parent': {'type': 'data_source_id', 'data_source_id': dataSourceId},
      'properties': properties,
    });
    return '${j['id']}';
  }

  Future<Map<String, dynamic>> updatePage(String pageId, Map<String, Object?> properties) =>
      _call('PATCH', 'pages/$pageId', {'properties': properties});

  Future<Map<String, dynamic>> getPage(String pageId) => _call('GET', 'pages/$pageId');

  // ── property helpers ──
  static String richText(Object? rt) => rt is List
      ? rt.map((e) => e is Map ? (e['plain_text'] ?? e['text']?['content'] ?? '') : '').join()
      : '';

  static String pageTitle(Map page) {
    final props = page['properties'];
    if (props is Map) {
      for (final v in props.values) {
        if (v is Map && v['type'] == 'title') return richText(v['title']);
      }
    }
    return '';
  }

  static Map<String, Object?> title(String t) => {
        'title': [
          {
            'type': 'text',
            'text': {'content': t}
          }
        ]
      };
  static Map<String, Object?> select(String? name) =>
      {'select': name == null ? null : {'name': name}};
  static Map<String, Object?> number(num? v) => {'number': v};
  static Map<String, Object?> date(DateTime? start, [DateTime? end]) => {
        'date': start == null
            ? null
            : {
                'start': start.toUtc().toIso8601String(),
                if (end != null) 'end': end.toUtc().toIso8601String(),
              }
      };
  static Map<String, Object?> dateOnly(DateTime? d) => {
        'date': d == null
            ? null
            : {'start': '${d.year}-${_p(d.month)}-${_p(d.day)}'}
      };
  static Map<String, Object?> relation(List<String> ids) => {
        'relation': [for (final i in ids) {'id': i}]
      };
  static String _p(int v) => v.toString().padLeft(2, '0');
}
