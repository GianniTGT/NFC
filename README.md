# Tiff NFC Reader

Android-App (Flutter) zum Lesen von NFC-Karten und -Tags.

- Liest UID, Kartentyp (MIFARE Classic, Ultralight/NTAG, DESFire, ISO 15693 …), ATQA/SAK
- Zeigt NDEF-Inhalte (Text, URL, sonstige Daten als Text oder Hex)
- Serienmodus: mehrere Karten nacheinander lesen
- Text auf beschreibbare Tags schreiben
- UID kopieren, ganze Liste als CSV kopieren

## Build

Jeder Push auf `main` baut über GitHub Actions eine APK.
Download: **Releases** im Repo → neueste `NFC-Reader-<nr>.apk` auf dem Handy öffnen und installieren
(einmalig „Installation aus unbekannten Quellen“ erlauben).

Der Android-Ordner wird im Build automatisch erzeugt (`flutter create`) und mit der NFC-Berechtigung ergänzt.
