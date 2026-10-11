import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Kategorien für benannte Karten.
const kCategories = ['Mitarbeiter', 'Equipment', 'Sonstiges'];

/// Name und Zuordnung einer bekannten Karte (UID).
class CardLabel {
  CardLabel({required this.uid, required this.name, this.category = 'Sonstiges', this.note = ''});

  final String uid;
  String name;
  String category;
  String note; // z. B. SAP-Equipment-Nr., Personalnummer, Standort

  Map<String, dynamic> toJson() => {'uid': uid, 'name': name, 'category': category, 'note': note};

  factory CardLabel.fromJson(Map<String, dynamic> j) => CardLabel(
        uid: j['uid'] as String,
        name: j['name'] as String? ?? '',
        category: j['category'] as String? ?? 'Sonstiges',
        note: j['note'] as String? ?? '',
      );
}

class RecordInfo {
  RecordInfo(this.label, this.value);
  final String label;
  final String value;

  Map<String, dynamic> toJson() => {'l': label, 'v': value};
  factory RecordInfo.fromJson(Map<String, dynamic> j) => RecordInfo(j['l'] as String, j['v'] as String);
}

/// Ein einzelner Lesevorgang.
class ScanResult {
  ScanResult({
    required this.time,
    required this.uid,
    required this.type,
    required this.details,
    required this.records,
  });

  final DateTime time;
  final String uid;
  final String type;
  final Map<String, String> details;
  final List<RecordInfo> records;

  Map<String, dynamic> toJson() => {
        't': time.toIso8601String(),
        'uid': uid,
        'type': type,
        'd': details,
        'r': records.map((e) => e.toJson()).toList(),
      };

  factory ScanResult.fromJson(Map<String, dynamic> j) => ScanResult(
        time: DateTime.parse(j['t'] as String),
        uid: j['uid'] as String,
        type: j['type'] as String,
        details: Map<String, String>.from(j['d'] as Map),
        records: (j['r'] as List).map((e) => RecordInfo.fromJson(Map<String, dynamic>.from(e as Map))).toList(),
      );
}

/// Speichert Verlauf und Kartennamen lokal auf dem Handy.
class Store {
  static const _kHistory = 'history_v1';
  static const _kLabels = 'labels_v1';
  static const maxHistory = 1000;

  final List<ScanResult> history = [];
  final Map<String, CardLabel> labels = {};
  SharedPreferences? _prefs;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    try {
      final h = _prefs!.getString(_kHistory);
      if (h != null) {
        history
          ..clear()
          ..addAll((jsonDecode(h) as List).map((e) => ScanResult.fromJson(Map<String, dynamic>.from(e as Map))));
      }
      final l = _prefs!.getString(_kLabels);
      if (l != null) {
        labels.clear();
        for (final e in jsonDecode(l) as List) {
          final c = CardLabel.fromJson(Map<String, dynamic>.from(e as Map));
          labels[c.uid] = c;
        }
      }
    } catch (_) {
      // Defekte Daten ignorieren, App startet trotzdem.
    }
  }

  Future<void> addScan(ScanResult r) async {
    history.insert(0, r);
    if (history.length > maxHistory) history.removeRange(maxHistory, history.length);
    await _saveHistory();
  }

  Future<void> clearHistory() async {
    history.clear();
    await _saveHistory();
  }

  Future<void> setLabel(CardLabel c) async {
    labels[c.uid] = c;
    await _saveLabels();
  }

  Future<void> removeLabel(String uid) async {
    labels.remove(uid);
    await _saveLabels();
  }

  /// Importiert Zeilen im Format UID;Name;Kategorie;Notiz. Gibt die Anzahl zurück.
  Future<int> importCsv(String text) async {
    var n = 0;
    for (final raw in const LineSplitter().convert(text)) {
      final p = raw.split(';');
      if (p.length < 2) continue;
      final uid = p[0].trim().toUpperCase();
      if (uid.isEmpty || uid == 'UID') continue;
      final cat = p.length > 2 && kCategories.contains(p[2].trim()) ? p[2].trim() : 'Sonstiges';
      labels[uid] = CardLabel(uid: uid, name: p[1].trim(), category: cat, note: p.length > 3 ? p[3].trim() : '');
      n++;
    }
    await _saveLabels();
    return n;
  }

  String labelsCsv() {
    final rows = labels.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return 'UID;Name;Kategorie;Notiz\n${rows.map((c) => '${c.uid};${c.name};${c.category};${c.note}').join('\n')}';
  }

  Future<void> _saveHistory() async =>
      _prefs?.setString(_kHistory, jsonEncode(history.map((e) => e.toJson()).toList()));

  Future<void> _saveLabels() async =>
      _prefs?.setString(_kLabels, jsonEncode(labels.values.map((e) => e.toJson()).toList()));
}
