import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:ndef/ndef.dart' as ndef;

void main() => runApp(const NfcReaderApp());

class NfcReaderApp extends StatelessWidget {
  const NfcReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0F7A5C);
    return MaterialApp(
      title: 'NFC Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const ReaderPage(),
    );
  }
}

/// Ein gelesener Tag mit allen Infos, die wir anzeigen.
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
}

class RecordInfo {
  RecordInfo(this.label, this.value);
  final String label;
  final String value;
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final List<ScanResult> _history = [];
  bool _scanning = false;
  bool _loop = false;
  String _status = 'Bereit';
  NFCAvailability? _availability;

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
      setState(() {
        _history.insert(0, result);
        _status = 'Gelesen: ${result.uid}';
      });
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

  /// Serienmodus: liest Karte für Karte, bis gestoppt wird.
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
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Schreiben'),
          ),
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
      if (tag.ndefWritable != true) {
        throw Exception('Dieser Tag ist nicht beschreibbar.');
      }
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
    if (r is ndef.TextRecord) {
      return RecordInfo('$label · Text', r.text ?? '');
    }
    if (r is ndef.UriRecord) {
      return RecordInfo('$label · URL', r.uriString ?? '');
    }
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

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Kopiert: $text'), duration: const Duration(seconds: 1)),
    );
  }

  void _copyAllUids() {
    if (_history.isEmpty) return;
    final lines = _history.reversed.map((r) => '${_time(r.time)};${r.uid};${r.type}').join('\n');
    _copy('Zeit;UID;Typ\n$lines');
  }

  String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final nfcOk = _availability == null || _availability == NFCAvailability.available;

    return Scaffold(
      appBar: AppBar(
        title: const Text('NFC Reader'),
        actions: [
          IconButton(
            tooltip: 'Alle als CSV kopieren',
            icon: const Icon(Icons.copy_all),
            onPressed: _history.isEmpty ? null : _copyAllUids,
          ),
          IconButton(
            tooltip: 'Liste leeren',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _history.isEmpty ? null : () => setState(_history.clear),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Icon(Icons.nfc, size: 56, color: _scanning ? cs.primary : cs.outline),
                const SizedBox(height: 8),
                Text(_status, textAlign: TextAlign.center),
                const SizedBox(height: 16),
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
          Expanded(
            child: _history.isEmpty
                ? Center(
                    child: Text('Noch keine Karte gelesen.',
                        style: TextStyle(color: cs.onSurfaceVariant)),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: _history.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _ResultCard(
                      result: _history[i],
                      time: _time(_history[i].time),
                      onCopy: _copy,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result, required this.time, required this.onCopy});

  final ScanResult result;
  final String time;
  final void Function(String) onCopy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = TextStyle(fontSize: 12, color: cs.onSurfaceVariant, letterSpacing: .4);
    const mono = TextStyle(fontFamily: 'monospace');

    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        shape: const Border(),
        title: Text(result.uid, style: mono.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text('${result.type} · $time'),
        trailing: IconButton(
          tooltip: 'UID kopieren',
          icon: const Icon(Icons.copy),
          onPressed: () => onCopy(result.uid),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in result.details.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 120, child: Text(e.key, style: label)),
                  Expanded(child: SelectableText(e.value, style: mono)),
                ],
              ),
            ),
          for (final r in result.records) ...[
            const Divider(),
            Text(r.label, style: label),
            const SizedBox(height: 2),
            SelectableText(r.value, style: mono),
          ],
        ],
      ),
    );
  }
}
