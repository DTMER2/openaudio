<div align="center">

# OpenAudio

**macOS-Audio routen, aufnehmen, abhören und mitschneiden — ganz ohne Audio-MIDI-Setup.**

[English](README.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · **Deutsch** · [Français](README.fr.md)

[**⬇ Neueste Version herunterladen**](https://github.com/DTMER2/openaudio/releases/latest)

</div>

---

OpenAudio ist ein Audio-Werkzeug für macOS, das Routing und Aufnahme vereint — eine integrierte Alternative zu BlackHole und Loopback. Es nimmt Audio pro App oder systemweit auf, mischt und routet es und stellt das Ergebnis als virtuelles Eingabegerät bereit, das andere Apps und DAWs auswählen können. Abhören und Mitschneiden sind ebenfalls möglich — und du musst nie von Hand Aggregat- oder Mehrfachausgabegeräte einrichten.

## Funktionen

- 🎙 **Aufnahme pro App und systemweit** über Core Audio Process Tap (macOS 14.4+) — nimm „nur Spotify“ oder alles auf.
- 🎚 **Routing-Matrix** — verbinde jede Quelle mit jedem Bus, mit Gain, Panorama, Stumm und Solo je Quelle.
- 🔌 **Virtuelle Ausgabegeräte** — dein gerouteter Mix erscheint in jeder App oder DAW als **OpenAudio**-Eingang.
- 🎧 **Echtzeit-Monitoring** auf deinen eigenen Ausgang, mit Pegelregelung.
- 📊 **Live-Pegelanzeigen pro Kanal** mit Peak-Hold.
- ⏺ **Aufnahme** des finalen Mixes (oder eines einzelnen Busses) in eine Datei.
- 🎛 **Mehrere Busse** (bis zu 8) für parallele Routen.
- 🎤 **Mikrofon- / Audio-Interface-Eingang** als mischbare Quelle.
- 🖥 **Schlanke Menüleisten-App** — kein Ballast im Dock.

## Voraussetzungen

- macOS **14.4** oder neuer (Apple Silicon oder Intel)
- Administratorrechte für die einmalige Treiberinstallation

## Installation

1. [**`OpenAudio-1.0.0.pkg` herunterladen**](https://github.com/DTMER2/openaudio/releases/latest) aus der neuesten Version.
2. Installationsprogramm öffnen und den Schritten folgen. Es installiert einen HAL-Audiotreiber und die App und startet Core Audio neu.
3. **OpenAudio** aus dem Programme-Ordner starten — das Symbol erscheint in der Menüleiste.
4. Wenn du dazu aufgefordert wirst, erteile die **Berechtigung zur Audioaufnahme** (Systemeinstellungen › Datenschutz & Sicherheit). Sie ist zum Aufnehmen von App-/Systemaudio erforderlich.

Das Installationsprogramm ist mit einer **Developer ID signiert** und von **Apple notariell beglaubigt**.

> **Tipp:** OpenAudio ist eine Menüleisten-App und hat daher kein Dock-Symbol. Für den automatischen Start füge sie unter Systemeinstellungen › Allgemein › Anmeldeobjekte hinzu.

## Funktionsweise

OpenAudio kombiniert zwei macOS-Technologien:

- Ein **Core Audio Process Tap** nimmt Audio aus ausgewählten Apps oder dem gesamten System auf (macOS 14.4+).
- Ein mitgeliefertes **virtuelles AudioServerPlugIn-Gerät** stellt den gerouteten Mix als Eingang bereit, den andere Apps und DAWs auswählen können.

Das Mischen und Routen dazwischen übernimmt die App — kein Audio-MIDI-Setup, keine von Hand erstellten Aggregat- oder Mehrfachausgabegeräte.

## Deinstallation

```sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/OpenAudioDriver.driver /Applications/OpenAudio.app
sudo killall coreaudiod
```

## Nicht im Mac App Store

OpenAudio installiert einen System-Audiotreiber (nach `/Library/Audio/Plug-Ins/HAL`) und startet `coreaudiod` neu, was die App-Store-Sandbox nicht zulässt. Deshalb wird es außerhalb des Stores als signiertes, notariell beglaubigtes Installationsprogramm vertrieben.

## Lizenz

**Proprietär — alle Rechte vorbehalten.** Der Quellcode ist ausschließlich zur Transparenz und Bewertung öffentlich. Siehe [LICENSE](LICENSE).
