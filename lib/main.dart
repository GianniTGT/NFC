import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:ndef/ndef.dart' as ndef;

import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Fehler sichtbar auf dem Bildschirm zeigen statt leerer Fläche.
  ErrorWidget.builder = (details) => Material(
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: SelectableText(
              'Fehler:\n${details.exceptionAsString()}',
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
        ),
      );
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FLUTTER ERROR: ${details.exceptionAsString()}');
  };

  final store = Store();
  try {
    await store.load().timeout(const Duration(seconds: 5));
  } catch (e) {
    debugPrint('Store laden fehlgeschlagen: $e');
  }
  runApp(NfcApp(store: store));
}

class NfcApp extends StatelessWidget {
  const NfcApp({super.key, required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0F7A5C);
    return MaterialApp(
      title: 'Tiff Access',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: HomePage(store: store),
    );
  }
}

String fmtDate(DateTime t) =>
    '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}.${t.year}';
String fmtTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
String fmtDateTime(DateTime t) => '${fmtDate(t)} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

void copyText(BuildContext context, String text, {String? info}) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(info ?? 'Kopiert'), duration: const Duration(seconds: 2)),
  );
}

String formatUid(String hex) {
  final clean = hex.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
  if (clean.isEmpty) return '';
  final parts = <String>[];
  for (var i = 0; i < clean.length; i += 2) {
    parts.add(clean.substring(i, i + 2 > clean.length ? clean.length : i + 2));
  }
  return parts.join(':');
}

/// Hält eine NFC-Sitzung offen, liest UID und – falls vorhanden – die Mitglieds-ID aus dem NDEF-Text.
class ReadTag {
  ReadTag(this.uid, this.type, this.ndefText, this.writable);
  final String uid;
  final String type;
  final String? ndefText; // erster Textrecord, z. B. unsere Mitglieds-ID
  final bool writable;
}

Future<ReadTag> pollTag() async {
  final tag = await FlutterNfcKit.poll(timeout: const Duration(seconds: 20), iosAlertMessage: 'Karte ans Handy halten');
  String? text;
  if (tag.ndefAvailable == true) {
    try {
      final recs = await FlutterNfcKit.readNDEFRecords(cached: false);
      for (final r in recs) {
        if (r is ndef.TextRecord && r.text != null && r.text!.isNotEmpty) {
          text = r.text;
          break;
        }
      }
    } catch (_) {}
  }
  return ReadTag(formatUid(tag.id), _typeName(tag), text, tag.ndefWritable == true);
}

String _typeName(NFCTag tag) {
  switch (tag.type) {
    case NFCTagType.mifare_classic:
      return 'MIFARE Classic';
    case NFCTagType.mifare_ultralight:
      return 'MIFARE Ultralight / NTAG';
    case NFCTagType.mifare_desfire:
      return 'MIFARE DESFire';
    case NFCTagType.iso15693:
      return 'ISO 15693';
    case NFCTagType.iso7816:
      return 'ISO 7816';
    default:
      return tag.standard.isNotEmpty ? tag.standard : 'Unbekannt';
  }
}

// =====================================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store});
  final Store store;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final refresh = () => setState(() {});
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          CheckinPage(store: widget.store, onChanged: refresh),
          EnrollPage(store: widget.store, onChanged: refresh),
          MembersPage(store: widget.store, onChanged: refresh),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.login), label: 'Check-in'),
          const NavigationDestination(icon: Icon(Icons.add_card), label: 'Erfassen'),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: widget.store.members.isNotEmpty,
              label: Text('${widget.store.members.length}'),
              child: const Icon(Icons.groups_outlined),
            ),
            label: 'Mitglieder',
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// Check-in
// =====================================================================

class CheckinPage extends StatefulWidget {
  const CheckinPage({super.key, required this.store, required this.onChanged});
  final Store store;
  final VoidCallback onChanged;

  @override
  State<CheckinPage> createState() => _CheckinPageState();
}

class _CheckinPageState extends State<CheckinPage> {
  bool _loop = false;
  bool _busy = false;
  Member? _member;
  bool? _granted;
  String _reason = '';
  String _hint = 'Karte halten zum Check-in';

  Store get store => widget.store;

  Future<void> _safeFinish() async {
    try {
      await FlutterNfcKit.finish();
    } catch (_) {}
  }

  Future<void> _checkOnce() async {
    setState(() {
      _busy = true;
      _hint = 'Karte halten …';
    });
    try {
      final tag = await pollTag();
      await FlutterNfcKit.finish();

      // Erst über UID suchen, sonst über die auf die Karte geschriebene Mitglieds-ID.
      var m = store.byUid(tag.uid);
      m ??= tag.ndefText != null ? store.byMemberId(tag.ndefText!.trim()) : null;

      final granted = m?.valid ?? false;
      final reason = m == null ? 'Unbekannte Karte' : m.statusText;
      await store.addCheckin(CheckinEvent(
        time: DateTime.now(),
        uid: tag.uid,
        memberId: m?.memberId ?? '',
        name: m?.name ?? '',
        granted: granted,
        reason: reason,
      ));
      if (m != null && granted && m.aboTyp == '10er-Karte' && m.entries > 0) {
        m.entries -= 1;
        await store.saveMember(m);
      }
      HapticFeedback.mediumImpact();
      setState(() {
        _member = m;
        _granted = granted;
        _reason = reason;
        _hint = 'Nächste Karte halten';
      });
      widget.onChanged();
    } catch (e) {
      await _safeFinish();
      setState(() => _hint = e is Exception ? 'Keine Karte erkannt' : 'Fehler: $e');
      _loop = false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loopCheck() async {
    setState(() => _loop = true);
    while (_loop && mounted) {
      await _checkOnce();
      if (_loop) await Future.delayed(const Duration(milliseconds: 1800));
    }
  }

  void _stop() {
    _loop = false;
    _safeFinish();
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final today = store.checkins.where((e) {
      final n = DateTime.now();
      return e.time.year == n.year && e.time.month == n.month && e.time.day == n.day;
    }).length;

    Color bg = cs.surfaceContainerHighest;
    IconData icon = Icons.contactless;
    if (_granted == true) {
      bg = const Color(0xFF1B5E20);
      icon = Icons.check_circle;
    } else if (_granted == false) {
      bg = const Color(0xFF8E1B1B);
      icon = Icons.cancel;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Check-in'),
        actions: [
          IconButton(
            tooltip: 'Protokoll als CSV',
            icon: const Icon(Icons.copy_all),
            onPressed: store.checkins.isEmpty ? null : () => copyText(context, store.checkinsCsv(), info: 'Protokoll kopiert'),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                Icon(icon, size: 64, color: _granted == null ? cs.outline : Colors.white),
                const SizedBox(height: 10),
                if (_member != null) ...[
                  Text(_member!.name,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: _granted == null ? null : Colors.white, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('${_member!.aboTyp} · $_reason',
                      style: TextStyle(color: _granted == null ? null : Colors.white70)),
                  if (_member!.validUntil != null)
                    Text('gültig bis ${fmtDate(_member!.validUntil!)}',
                        style: TextStyle(color: _granted == null ? null : Colors.white70)),
                  if (_member!.aboTyp == '10er-Karte')
                    Text('${_member!.entries} Eintritte übrig',
                        style: TextStyle(color: _granted == null ? null : Colors.white70)),
                ] else
                  Text(_granted == false ? 'Unbekannte Karte' : _hint,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(color: _granted == null ? null : Colors.white)),
                const SizedBox(height: 16),
                if (!_busy && !_loop)
                  Wrap(
                    spacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.icon(onPressed: _checkOnce, icon: const Icon(Icons.login), label: const Text('Check-in')),
                      OutlinedButton.icon(onPressed: _loopCheck, icon: const Icon(Icons.repeat), label: const Text('Dauerbetrieb')),
                    ],
                  )
                else
                  FilledButton.tonalIcon(onPressed: _stop, icon: const Icon(Icons.stop), label: const Text('Stopp')),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Text('HEUTE', style: TextStyle(fontSize: 12, letterSpacing: 1, color: cs.onSurfaceVariant)),
                const Spacer(),
                Text('$today Check-ins', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: store.checkins.isEmpty
                ? Center(child: Text('Noch keine Check-ins.', style: TextStyle(color: cs.onSurfaceVariant)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    itemCount: store.checkins.length,
                    itemBuilder: (_, i) {
                      final e = store.checkins[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(e.granted ? Icons.check_circle : Icons.cancel,
                            color: e.granted ? const Color(0xFF2E7D32) : const Color(0xFFC62828)),
                        title: Text(e.name.isEmpty ? e.uid : e.name),
                        subtitle: Text('${fmtTime(e.time)} · ${e.reason}'),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// Erfassen / Karte beschreiben
// =====================================================================

class EnrollPage extends StatefulWidget {
  const EnrollPage({super.key, required this.store, required this.onChanged});
  final Store store;
  final VoidCallback onChanged;

  @override
  State<EnrollPage> createState() => _EnrollPageState();
}

class _EnrollPageState extends State<EnrollPage> {
  String _status = 'Neue Karte halten, um ein Mitglied anzulegen';
  bool _busy = false;

  Store get store => widget.store;

  Future<void> _safeFinish() async {
    try {
      await FlutterNfcKit.finish();
    } catch (_) {}
  }

  /// Liest eine Karte, legt bei Bedarf ein Mitglied an und schreibt die Mitglieds-ID auf die Karte.
  Future<void> _enroll() async {
    setState(() {
      _busy = true;
      _status = 'Karte halten …';
    });
    try {
      final tag = await pollTag();
      await FlutterNfcKit.finish();
      if (!mounted) return;

      final existing = store.byUid(tag.uid);
      final member = await _memberDialog(tag, existing);
      if (member == null) {
        setState(() => _status = 'Abgebrochen');
        return;
      }
      await store.saveMember(member);

      // Mitglieds-ID auf die Karte schreiben, wenn beschreibbar.
      var written = false;
      if (tag.writable) {
        setState(() => _status = 'Mitglieds-ID auf Karte schreiben – Karte nochmals halten …');
        try {
          await FlutterNfcKit.poll(timeout: const Duration(seconds: 20));
          await FlutterNfcKit.writeNDEFRecords([
            ndef.TextRecord(text: member.memberId, language: 'de'),
          ]);
          await FlutterNfcKit.finish();
          written = true;
          HapticFeedback.mediumImpact();
        } catch (e) {
          await _safeFinish();
        }
      }
      widget.onChanged();
      setState(() => _status = written
          ? '${member.name} gespeichert, ID ${member.memberId} auf Karte geschrieben'
          : '${member.name} gespeichert (ID ${member.memberId}). '
              '${tag.writable ? "Schreiben fehlgeschlagen." : "Karte nicht beschreibbar – UID genügt."}');
    } catch (e) {
      await _safeFinish();
      setState(() => _status = 'Keine Karte erkannt oder Fehler');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Member?> _memberDialog(ReadTag tag, Member? existing) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final note = TextEditingController(text: existing?.note ?? '');
    final entries = TextEditingController(text: existing != null && existing.entries >= 0 ? '${existing.entries}' : '10');
    var abo = existing?.aboTyp ?? kAboTypen.first;
    DateTime? until = existing?.validUntil ?? DateTime.now().add(const Duration(days: 365));
    var blocked = existing?.blocked ?? false;
    final memberId = existing?.memberId ?? store.nextMemberId();

    return showDialog<Member>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(existing == null ? 'Neues Mitglied' : 'Mitglied bearbeiten'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ID $memberId', style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('Karte ${tag.uid}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                const SizedBox(height: 12),
                TextField(
                  controller: name,
                  autofocus: existing == null,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: abo,
                  decoration: const InputDecoration(labelText: 'Abo'),
                  items: [for (final a in kAboTypen) DropdownMenuItem(value: a, child: Text(a))],
                  onChanged: (v) => setLocal(() => abo = v ?? abo),
                ),
                if (abo == '10er-Karte')
                  TextField(
                    controller: entries,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Eintritte übrig'),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: Text(until == null ? 'Unbefristet' : 'Gültig bis ${fmtDate(until!)}')),
                    TextButton(
                      onPressed: () async {
                        final d = await showDatePicker(
                          context: ctx,
                          initialDate: until ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (d != null) setLocal(() => until = d);
                      },
                      child: const Text('Datum'),
                    ),
                  ],
                ),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(labelText: 'Notiz / Telefon'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Gesperrt'),
                  value: blocked,
                  onChanged: (v) => setLocal(() => blocked = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) return;
                Navigator.pop(
                  ctx,
                  Member(
                    uid: tag.uid,
                    memberId: memberId,
                    name: name.text.trim(),
                    aboTyp: abo,
                    validUntil: until,
                    blocked: blocked,
                    note: note.text.trim(),
                    entries: abo == '10er-Karte' ? (int.tryParse(entries.text) ?? 0) : -1,
                  ),
                );
              },
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _settings() async {
    final c = TextEditingController(text: store.idPrefix);
    final p = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ID-Kürzel'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Kürzel vor der Mitgliedsnummer, z. B. AKA für Aarburg Kampfsport Akademie.'),
            const SizedBox(height: 8),
            TextField(controller: c, textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Kürzel')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Speichern')),
        ],
      ),
    );
    if (p != null) {
      await store.setPrefix(p);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Erfassen'),
        actions: [
          IconButton(tooltip: 'ID-Kürzel', icon: const Icon(Icons.settings_outlined), onPressed: _settings),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_card, size: 64, color: cs.primary),
              const SizedBox(height: 16),
              Text(_status, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('Nächste ID: ${store.idPrefix}-…', style: TextStyle(color: cs.onSurfaceVariant)),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _busy ? null : _enroll,
                icon: const Icon(Icons.contactless),
                label: const Text('Karte erfassen & beschreiben'),
              ),
              const SizedBox(height: 12),
              Text(
                'Die Mitglieds-ID wird auf beschreibbare Karten (NTAG) geschrieben. '
                'Bei MIFARE-Classic-Karten (z. B. ohne NDEF) dient die fest eingebrannte UID als Schlüssel.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// Mitglieder
// =====================================================================

class MembersPage extends StatefulWidget {
  const MembersPage({super.key, required this.store, required this.onChanged});
  final Store store;
  final VoidCallback onChanged;

  @override
  State<MembersPage> createState() => _MembersPageState();
}

class _MembersPageState extends State<MembersPage> {
  String _query = '';

  Store get store => widget.store;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final q = _query.toLowerCase();
    final items = store.members.values
        .where((m) =>
            q.isEmpty ||
            m.name.toLowerCase().contains(q) ||
            m.memberId.toLowerCase().contains(q) ||
            m.uid.toLowerCase().contains(q) ||
            m.note.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mitglieder'),
        actions: [
          IconButton(
            tooltip: 'Als CSV kopieren',
            icon: const Icon(Icons.copy_all),
            onPressed: store.members.isEmpty ? null : () => copyText(context, store.membersCsv(), info: '${store.members.length} Mitglieder kopiert'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Name, ID oder UID suchen',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        store.members.isEmpty
                            ? 'Noch keine Mitglieder.\nIm Tab „Erfassen" eine Karte anlegen.'
                            : 'Keine Treffer.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final m = items[i];
                      final color = m.valid ? const Color(0xFF2E7D32) : const Color(0xFFC62828);
                      final checkins = store.checkins.where((e) => e.uid == m.uid).length;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: color.withValues(alpha: .15),
                          child: Icon(m.valid ? Icons.check : Icons.block, color: color),
                        ),
                        title: Text(m.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          '${m.memberId} · ${m.aboTyp}\n'
                          '${m.statusText}${m.validUntil != null ? " bis ${fmtDate(m.validUntil!)}" : ""} · $checkins Check-ins',
                        ),
                        isThreeLine: true,
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'block') {
                              m.blocked = !m.blocked;
                              await store.saveMember(m);
                              setState(() {});
                              widget.onChanged();
                            } else if (v == 'copy') {
                              if (!context.mounted) return;
                              copyText(context, m.uid, info: 'UID kopiert');
                            } else if (v == 'del') {
                              await store.removeMember(m.uid);
                              setState(() {});
                              widget.onChanged();
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(value: 'block', child: Text(m.blocked ? 'Entsperren' : 'Sperren')),
                            const PopupMenuItem(value: 'copy', child: Text('UID kopieren')),
                            const PopupMenuItem(value: 'del', child: Text('Löschen')),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
