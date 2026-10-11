import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:ndef/ndef.dart' as ndef;

import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = Store();
  await store.load();
  runApp(NfcReaderApp(store: store));
}

class NfcReaderApp extends StatelessWidget {
  const NfcReaderApp({super.key, required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0F7A5C);
    return MaterialApp(
      title: 'NFC Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: HomePage(store: store),
    );
  }
}

IconData categoryIcon(String c) => switch (c) {
      'Mitarbeiter' => Icons.badge_outlined,
      'Equipment' => Icons.precision_manufacturing_outlined,
      _ => Icons.label_outline,
    };

String fmtTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.day)}.${two(t.month)}.${t.year} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

void copyText(BuildContext context, String text, {String? info}) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(info ?? 'Kopiert: $text'), duration: const Duration(seconds: 2)),
  );
}

/// Dialog zum Benennen einer Karte. Gibt true zurück, wenn gespeichert oder gelöscht wurde.
Future<bool> editLabel(BuildContext context, Store store, String uid) async {
  final existing = store.labels[uid];
  final name = TextEditingController(text: existing?.name ?? '');
  final note = TextEditingController(text: existing?.note ?? '');
  var category = existing?.category ?? 'Mitarbeiter';

  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(existing == null ? 'Karte benennen' : 'Karte bearbeiten'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(uid, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: [
                  for (final c in kCategories)
                    ButtonSegment(value: c, label: Text(c, style: const TextStyle(fontSize: 12))),
                ],
                selected: {category},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setLocal(() => category = s.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: name,
                autofocus: existing == null,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Name',
                  hintText: category == 'Mitarbeiter'
                      ? 'z. B. Max Muster'
                      : category == 'Equipment'
                          ? 'z. B. Silo F57 Förderband'
                          : 'Bezeichnung',
                ),
              ),
              TextField(
                controller: note,
                decoration: InputDecoration(
                  labelText: category == 'Mitarbeiter'
                      ? 'Personalnummer / Abteilung'
                      : category == 'Equipment'
                          ? 'SAP-Equipment / Techn. Platz'
                          : 'Notiz',
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'delete'),
              child: const Text('Entfernen'),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Speichern')),
        ],
      ),
    ),
  );

  if (result == 'delete') {
    await store.removeLabel(uid);
    return true;
  }
  if (result == 'save' && name.text.trim().isNotEmpty) {
    await store.setLabel(CardLabel(uid: uid, name: name.text.trim(), category: category, note: note.text.trim()));
    return true;
  }
  return false;
}

// =====================================================================
// Startseite mit zwei Bereichen: Lesen und Karten
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
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          ReaderPage(store: widget.store, onChanged: () => setState(() {})),
          CardsPage(store: widget.store, onChanged: () => setState(() {})),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.contactless_outlined), label: 'Lesen'),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: widget.store.labels.isNotEmpty,
              label: Text('${widget.store.labels.length}'),
              child: const Icon(Icons.style_outlined),
            ),
            label: 'Karten',
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// Lesen
// =====================================================================

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.store, required this.onChanged});
  final Store store;
  final VoidCallback onChanged;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  bool _scanning = false;
  bool _loop = false;
  String _status = 'Bereit';
  ScanResult? _last;
  NFCAvailability? _availability;

  Store get store => widget.store;

  @override
  void initState() {
    super.initState();
    _checkAvailability();
  }

  Future<void> _checkAvailability() async {
    try {
      final a = await FlutterNfcKit.nfcAvailability;
      setState(() {
        _availability = a;
        if (a == NFCAvailability.not_supported) {
          _status = 'Dieses Gerät hat kein NFC.';
        } else if (a == NFCAvailability.disabled) {
          _status = 'NFC ist ausgeschaltet. Bitte in den Einstellungen aktivieren.';
        } else {
          _status = 'Bereit';
        }
      });
    } catch (e) {
      setState(() => _status = 'NFC-Status unbekannt: $e');
    }
  }

  Future<void> _scanOnce() async {
    setState(() {
      _scanning = true;
      _status = 'Karte hinten ans Handy halten …';
    });
    try {
      final tag = await FlutterNfcKit.poll(
        timeout: const Duration(seconds: 30),
        iosAlertMessage: 'Karte ans iPhone halten',
      );
      final records = <RecordInfo>[];
      if (tag.ndefAvailable == true) {
        try {
          final recs = await FlutterNfcKit.readNDEFRecords(cached: false);
          for (var i = 0; i < recs.length; i++) {
            records.add(_decodeRecord(i, recs[i]));
          }
        } catch (e) {
          records.add(RecordInfo('NDEF', 'Lesen fehlgeschlagen: $e'));
        }
      }
      await FlutterNfcKit.finish();
      HapticFeedback.mediumImpact();

      final result = ScanResult(
        time: DateTime.now(),
        uid: _formatUid(tag.id),
        type: _typeName(tag),
        details: _details(tag),
        records: records,
      );
      await store.addScan(result);
      final label = store.labels[result.uid];
      setState(() {
        _last = result;
        _status = label != null ? 'Erkannt: ${label.name}' : 'Unbekannte Karte';
      });
      widget.onChanged();
    } on PlatformException catch (e) {
      await _safeFinish();
      setState(() => _status = e.code == '408'
          ? 'Keine Karte erkannt (Zeit abgelaufen).'
          : 'Fehler: ${e.message ?? e.code}');
      _loop = false;
    } catch (e) {
      await _safeFinish();
      setState(() => _status = 'Fehler: $e');
      _loop = false;
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _scanLoop() async {
    setState(() => _loop = true);
    while (_loop && mounted) {
      await _scanOnce();
      if (_loop) await Future.delayed(const Duration(milliseconds: 1200));
    }
  }

  Future<void> _stop() async {
    _loop = false;
    await _safeFinish();
    setState(() {
      _scanning = false;
      _status = 'Gestoppt.';
    });
  }

  Future<void> _safeFinish() async {
    try {
      await FlutterNfcKit.finish();
    } catch (_) {}
  }

  Future<void> _writeText() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Text auf Tag schreiben'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'z. B. Anlage F57 / Silo 3'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Schreiben')),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;

    setState(() {
      _scanning = true;
      _status = 'Tag zum Beschreiben ans Handy halten …';
    });
    try {
      final tag = await FlutterNfcKit.poll(timeout: const Duration(seconds: 30));
      if (tag.ndefWritable != true) throw Exception('Dieser Tag ist nicht beschreibbar.');
      await FlutterNfcKit.writeNDEFRecords([ndef.TextRecord(text: text, language: 'de')]);
      await FlutterNfcKit.finish();
      HapticFeedback.mediumImpact();
      setState(() => _status = 'Geschrieben: $text');
    } catch (e) {
      await _safeFinish();
      setState(() => _status = 'Schreiben fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _rename(String uid) async {
    if (await editLabel(context, store, uid)) {
      final l = store.labels[uid];
      setState(() {
        if (_last?.uid == uid) _status = l != null ? 'Erkannt: ${l.name}' : 'Unbekannte Karte';
      });
      widget.onChanged();
    }
  }

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verlauf löschen?'),
        content: const Text('Alle gespeicherten Scans werden entfernt. Benannte Karten bleiben erhalten.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Löschen')),
        ],
      ),
    );
    if (ok == true) {
      await store.clearHistory();
      setState(() => _last = null);
    }
  }

  void _copyHistoryCsv() {
    final rows = store.history.reversed.map((r) {
      final l = store.labels[r.uid];
      return '${fmtTime(r.time)};${r.uid};${r.type};${l?.name ?? ''};${l?.category ?? ''};${l?.note ?? ''}';
    }).join('\n');
    copyText(context, 'Zeit;UID;Typ;Name;Kategorie;Notiz\n$rows',
        info: '${store.history.length} Scans als CSV kopiert');
  }

  // ---------- Hilfsfunktionen ----------

  String _formatUid(String hex) {
    final clean = hex.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
    if (clean.isEmpty) return 'UID nicht verfügbar';
    final parts = <String>[];
    for (var i = 0; i < clean.length; i += 2) {
      parts.add(clean.substring(i, i + 2 > clean.length ? clean.length : i + 2));
    }
    return parts.join(':');
  }

  String _typeName(NFCTag tag) {
    switch (tag.type) {
      case NFCTagType.mifare_classic:
        return 'MIFARE Classic';
      case NFCTagType.mifare_ultralight:
        return 'MIFARE Ultralight / NTAG';
      case NFCTagType.mifare_desfire:
        return 'MIFARE DESFire';
      case NFCTagType.mifare_plus:
        return 'MIFARE Plus';
      case NFCTagType.iso7816:
        return 'ISO 7816 (Smartcard)';
      case NFCTagType.iso15693:
        return 'ISO 15693 (NFC-V)';
      case NFCTagType.iso18092:
        return 'ISO 18092 (FeliCa)';
      case NFCTagType.webusb:
        return 'WebUSB';
      default:
        return tag.standard.isNotEmpty ? tag.standard : 'Unbekannt';
    }
  }

  Map<String, String> _details(NFCTag tag) {
    final m = <String, String>{};
    void add(String k, String? v) {
      if (v != null && v.isNotEmpty) m[k] = v;
    }

    add('Standard', tag.standard);
    add('ATQA', tag.atqa);
    add('SAK', tag.sak);
    add('Hersteller', tag.manufacturer);
    add('Historical Bytes', tag.historicalBytes);
    add('Protocol Info', tag.protocolInfo);
    add('Application Data', tag.applicationData);
    if (tag.ndefAvailable == true) {
      add('NDEF-Typ', tag.ndefType);
      if (tag.ndefCapacity != null) m['NDEF-Kapazität'] = '${tag.ndefCapacity} Bytes';
      m['Beschreibbar'] = tag.ndefWritable == true ? 'Ja' : 'Nein';
    } else {
      m['NDEF'] = 'Keine NDEF-Daten';
    }
    return m;
  }

  RecordInfo _decodeRecord(int i, ndef.NDEFRecord r) {
    final label = 'Record ${i + 1}';
    if (r is ndef.TextRecord) return RecordInfo('$label · Text', r.text ?? '');
    if (r is ndef.UriRecord) return RecordInfo('$label · URL', r.uriString ?? '');
    final payload = r.payload ?? Uint8List(0);
    final type = r.decodedType ?? r.runtimeType.toString();
    try {
      final asText = utf8.decode(payload);
      if (asText.runes.every((c) => c >= 0x20 || c == 0x0A || c == 0x0D || c == 0x09)) {
        return RecordInfo('$label · $type', asText);
      }
    } catch (_) {}
    final hex = payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ').toUpperCase();
    return RecordInfo('$label · $type', hex.isEmpty ? '(leer)' : hex);
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final nfcOk = _availability == null || _availability == NFCAvailability.available;
    final last = _last;
    final lastLabel = last != null ? store.labels[last.uid] : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('NFC Reader'),
        actions: [
          IconButton(
            tooltip: 'Verlauf als CSV kopieren',
            icon: const Icon(Icons.copy_all),
            onPressed: store.history.isEmpty ? null : _copyHistoryCsv,
          ),
          IconButton(
            tooltip: 'Verlauf löschen',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: store.history.isEmpty ? null : _clearHistory,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Icon(
                  lastLabel != null && !_scanning ? categoryIcon(lastLabel.category) : Icons.nfc,
                  size: 52,
                  color: _scanning ? cs.primary : (lastLabel != null ? cs.primary : cs.outline),
                ),
                const SizedBox(height: 8),
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (last != null && !_scanning) ...[
                  const SizedBox(height: 4),
                  Text(last.uid, style: const TextStyle(fontFamily: 'monospace')),
                  if (lastLabel != null && lastLabel.note.isNotEmpty)
                    Text(lastLabel.note, style: TextStyle(color: cs.onSurfaceVariant)),
                  if (lastLabel == null)
                    TextButton.icon(
                      onPressed: () => _rename(last.uid),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Jetzt benennen'),
                    ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    if (!_scanning && !_loop) ...[
                      FilledButton.icon(
                        onPressed: nfcOk ? _scanOnce : _checkAvailability,
                        icon: const Icon(Icons.contactless),
                        label: const Text('Einmal lesen'),
                      ),
                      OutlinedButton.icon(
                        onPressed: nfcOk ? _scanLoop : null,
                        icon: const Icon(Icons.repeat),
                        label: const Text('Serie lesen'),
                      ),
                      OutlinedButton.icon(
                        onPressed: nfcOk ? _writeText : null,
                        icon: const Icon(Icons.edit),
                        label: const Text('Schreiben'),
                      ),
                    ] else
                      FilledButton.tonalIcon(
                        onPressed: _stop,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stopp'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Row(
              children: [
                Text('VERLAUF', style: TextStyle(fontSize: 12, letterSpacing: 1, color: cs.onSurfaceVariant)),
                const Spacer(),
                Text('${store.history.length} Scans', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          Expanded(
            child: store.history.isEmpty
                ? Center(child: Text('Noch keine Karte gelesen.', style: TextStyle(color: cs.onSurfaceVariant)))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: store.history.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final r = store.history[i];
                      return _ResultCard(
                        result: r,
                        label: store.labels[r.uid],
                        onCopy: (t) => copyText(context, t),
                        onRename: () => _rename(r.uid),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result, required this.label, required this.onCopy, required this.onRename});

  final ScanResult result;
  final CardLabel? label;
  final void Function(String) onCopy;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 12, color: cs.onSurfaceVariant, letterSpacing: .4);
    const mono = TextStyle(fontFamily: 'monospace');
    final l = label;

    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        shape: const Border(),
        leading: Icon(l != null ? categoryIcon(l.category) : Icons.help_outline,
            color: l != null ? cs.primary : cs.outline),
        title: Text(
          l?.name ?? result.uid,
          style: l != null ? const TextStyle(fontWeight: FontWeight.w600) : mono.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          l != null ? '${result.uid}\n${fmtTime(result.time)}' : '${result.type} · ${fmtTime(result.time)}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (l != null && l.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('${l.category} · ${l.note}'),
            ),
          for (final e in result.details.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 120, child: Text(e.key, style: small)),
                  Expanded(child: SelectableText(e.value, style: mono)),
                ],
              ),
            ),
          for (final r in result.records) ...[
            const Divider(),
            Text(r.label, style: small),
            const SizedBox(height: 2),
            SelectableText(r.value, style: mono),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => onCopy(result.uid),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('UID kopieren'),
              ),
              OutlinedButton.icon(
                onPressed: onRename,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(l == null ? 'Benennen' : 'Bearbeiten'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// Benannte Karten
// =====================================================================

class CardsPage extends StatefulWidget {
  const CardsPage({super.key, required this.store, required this.onChanged});
  final Store store;
  final VoidCallback onChanged;

  @override
  State<CardsPage> createState() => _CardsPageState();
}

class _CardsPageState extends State<CardsPage> {
  String _filter = 'Alle';
  String _query = '';

  Store get store => widget.store;

  Future<void> _edit(String uid) async {
    if (await editLabel(context, store, uid)) {
      setState(() {});
      widget.onChanged();
    }
  }

  Future<void> _import() async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Karten importieren'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Eine Zeile pro Karte:\nUID;Name;Kategorie;Notiz'),
            const SizedBox(height: 8),
            TextField(
              controller: c,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                hintText: '04:A1:B2:C3:D4:E5:F6;Max Muster;Mitarbeiter;P-1234',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Importieren')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    final n = await store.importCsv(text);
    setState(() {});
    widget.onChanged();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n Karten importiert')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final q = _query.toLowerCase();
    final items = store.labels.values
        .where((c) => _filter == 'Alle' || c.category == _filter)
        .where((c) =>
            q.isEmpty ||
            c.name.toLowerCase().contains(q) ||
            c.note.toLowerCase().contains(q) ||
            c.uid.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Karten'),
        actions: [
          IconButton(tooltip: 'Importieren', icon: const Icon(Icons.file_download_outlined), onPressed: _import),
          IconButton(
            tooltip: 'Als CSV kopieren',
            icon: const Icon(Icons.copy_all),
            onPressed: store.labels.isEmpty
                ? null
                : () => copyText(context, store.labelsCsv(), info: '${store.labels.length} Karten als CSV kopiert'),
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
                hintText: 'Name, Nummer oder UID suchen',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (final f in ['Alle', ...kCategories])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        store.labels.isEmpty
                            ? 'Noch keine Karten benannt.\nKarte lesen und dann „Benennen“ tippen.'
                            : 'Keine Treffer.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final c = items[i];
                      final count = store.history.where((r) => r.uid == c.uid).length;
                      final lastSeen = store.history.where((r) => r.uid == c.uid).firstOrNull;
                      return Card(
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          leading: Icon(categoryIcon(c.category), color: cs.primary),
                          title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            [
                              if (c.note.isNotEmpty) c.note,
                              c.uid,
                              if (lastSeen != null) 'Zuletzt: ${fmtTime(lastSeen.time)} · $count×',
                            ].join('\n'),
                          ),
                          isThreeLine: true,
                          onTap: () => _edit(c.uid),
                          trailing: IconButton(
                            tooltip: 'UID kopieren',
                            icon: const Icon(Icons.copy, size: 20),
                            onPressed: () => copyText(context, c.uid),
                          ),
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
