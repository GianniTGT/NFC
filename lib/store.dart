import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Abo-Typen. Frei erweiterbar, Studio wählt beim Anlegen.
const kAboTypen = ['Monatsabo', 'Jahresabo', '10er-Karte', 'Probe', 'Tageskarte'];

/// Ein Mitglied, verknüpft mit einer Karten-UID und einer eindeutigen Mitglieds-ID.
class Member {
  Member({
    required this.uid,
    required this.memberId,
    required this.name,
    this.aboTyp = 'Monatsabo',
    this.validUntil,
    this.blocked = false,
    this.note = '',
    this.entries = 0,
  });

  final String uid; // Karten-UID (fest)
  String memberId; // eindeutige, von uns vergebene ID, wird auf die Karte geschrieben
  String name;
  String aboTyp;
  DateTime? validUntil; // null = unbefristet
  bool blocked;
  String note; // z. B. Telefon, Bemerkung
  int entries; // Anzahl verbleibender Eintritte (nur für 10er-Karte); -1 = unbegrenzt

  bool get expired => validUntil != null && validUntil!.isBefore(DateTime.now());
  bool get noEntriesLeft => aboTyp == '10er-Karte' && entries <= 0;

  /// true = darf rein.
  bool get valid => !blocked && !expired && !noEntriesLeft;

  String get statusText {
    if (blocked) return 'Gesperrt';
    if (expired) return 'Abgelaufen';
    if (noEntriesLeft) return 'Keine Eintritte mehr';
    return 'Aktiv';
  }

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'mid': memberId,
        'name': name,
        'abo': aboTyp,
        'until': validUntil?.toIso8601String(),
        'blocked': blocked,
        'note': note,
        'entries': entries,
      };

  factory Member.fromJson(Map<String, dynamic> j) => Member(
        uid: j['uid'] as String,
        memberId: j['mid'] as String? ?? '',
        name: j['name'] as String? ?? '',
        aboTyp: j['abo'] as String? ?? 'Monatsabo',
        validUntil: (j['until'] as String?) != null ? DateTime.tryParse(j['until'] as String) : null,
        blocked: j['blocked'] as bool? ?? false,
        note: j['note'] as String? ?? '',
        entries: j['entries'] as int? ?? -1,
      );
}

/// Ein Check-in (Eintritt) im Protokoll.
class CheckinEvent {
  CheckinEvent({
    required this.time,
    required this.uid,
    required this.memberId,
    required this.name,
    required this.granted,
    required this.reason,
  });

  final DateTime time;
  final String uid;
  final String memberId;
  final String name;
  final bool granted;
  final String reason; // z. B. "Aktiv", "Abgelaufen", "Unbekannte Karte"

  Map<String, dynamic> toJson() => {
        't': time.toIso8601String(),
        'uid': uid,
        'mid': memberId,
        'name': name,
        'ok': granted,
        'r': reason,
      };

  factory CheckinEvent.fromJson(Map<String, dynamic> j) => CheckinEvent(
        time: DateTime.parse(j['t'] as String),
        uid: j['uid'] as String? ?? '',
        memberId: j['mid'] as String? ?? '',
        name: j['name'] as String? ?? '',
        granted: j['ok'] as bool? ?? false,
        reason: j['r'] as String? ?? '',
      );
}

/// Speichert Mitglieder, Check-in-Protokoll und Einstellungen lokal auf dem Handy.
class Store {
  static const _kMembers = 'members_v1';
  static const _kCheckins = 'checkins_v1';
  static const _kCounter = 'id_counter_v1';
  static const _kPrefix = 'id_prefix_v1';
  static const maxCheckins = 2000;

  final Map<String, Member> members = {}; // key = uid
  final List<CheckinEvent> checkins = [];
  int _counter = 0;
  String idPrefix = 'M';
  SharedPreferences? _prefs;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    try {
      final m = _prefs!.getString(_kMembers);
      if (m != null) {
        members.clear();
        for (final e in jsonDecode(m) as List) {
          final c = Member.fromJson(Map<String, dynamic>.from(e as Map));
          members[c.uid] = c;
        }
      }
      final ch = _prefs!.getString(_kCheckins);
      if (ch != null) {
        checkins
          ..clear()
          ..addAll((jsonDecode(ch) as List).map((e) => CheckinEvent.fromJson(Map<String, dynamic>.from(e as Map))));
      }
      _counter = _prefs!.getInt(_kCounter) ?? 0;
      idPrefix = _prefs!.getString(_kPrefix) ?? 'M';
    } catch (_) {
      // Defekte Daten ignorieren, App startet trotzdem.
    }
  }

  /// Nächste eindeutige Mitglieds-ID, z. B. "AKA-00042".
  String nextMemberId() {
    _counter++;
    _prefs?.setInt(_kCounter, _counter);
    return '$idPrefix-${_counter.toString().padLeft(5, '0')}';
  }

  Future<void> setPrefix(String p) async {
    idPrefix = p.trim().isEmpty ? 'M' : p.trim().toUpperCase();
    await _prefs?.setString(_kPrefix, idPrefix);
  }

  Member? byUid(String uid) => members[uid];

  Member? byMemberId(String mid) {
    for (final m in members.values) {
      if (m.memberId == mid) return m;
    }
    return null;
  }

  Future<void> saveMember(Member m) async {
    members[m.uid] = m;
    await _saveMembers();
  }

  Future<void> removeMember(String uid) async {
    members.remove(uid);
    await _saveMembers();
  }

  Future<void> addCheckin(CheckinEvent e) async {
    checkins.insert(0, e);
    if (checkins.length > maxCheckins) checkins.removeRange(maxCheckins, checkins.length);
    await _prefs?.setString(_kCheckins, jsonEncode(checkins.map((x) => x.toJson()).toList()));
  }

  Future<void> clearCheckins() async {
    checkins.clear();
    await _prefs?.setString(_kCheckins, jsonEncode([]));
  }

  String membersCsv() {
    final rows = members.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final b = StringBuffer('MitgliedsID;Name;Abo;GueltigBis;Status;UID;Notiz\n');
    for (final m in rows) {
      b.writeln('${m.memberId};${m.name};${m.aboTyp};${m.validUntil != null ? _d(m.validUntil!) : ''};${m.statusText};${m.uid};${m.note}');
    }
    return b.toString();
  }

  String checkinsCsv() {
    final b = StringBuffer('Zeit;Status;Name;MitgliedsID;UID;Grund\n');
    for (final e in checkins.reversed) {
      b.writeln('${_dt(e.time)};${e.granted ? "OK" : "ABGEWIESEN"};${e.name};${e.memberId};${e.uid};${e.reason}');
    }
    return b.toString();
  }

  static String _d(DateTime t) =>
      '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}.${t.year}';
  static String _dt(DateTime t) =>
      '${_d(t)} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _saveMembers() async =>
      _prefs?.setString(_kMembers, jsonEncode(members.values.map((e) => e.toJson()).toList()));
}
