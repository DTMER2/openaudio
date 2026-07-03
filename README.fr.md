<div align="center">

# OpenAudio

**Router, capturer, écouter et enregistrer l'audio de macOS — sans toucher à Configuration audio et MIDI.**

[English](README.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · **Français**

[**⬇ Télécharger la dernière version**](https://github.com/DTMER2/openaudio/releases/latest)

</div>

---

OpenAudio est un utilitaire audio pour macOS qui réunit routage et capture — une alternative intégrée à BlackHole et Loopback. Il capture l'audio par application ou à l'échelle du système, le mixe et le route, puis expose le résultat comme un périphérique d'entrée virtuel que d'autres apps et STAN (DAW) peuvent sélectionner. L'écoute de contrôle et l'enregistrement sont également possibles — sans jamais avoir à construire à la main des périphériques agrégés ou de sortie multiple.

## Fonctionnalités

- 🎙 **Capture par application et à l'échelle du système** via Core Audio Process Tap (macOS 14.4+) — capturez « seulement Spotify » ou tout.
- 🎚 **Matrice de routage** — reliez n'importe quelle source à n'importe quel bus, avec gain, panoramique, coupure et solo par source.
- 🔌 **Périphériques de sortie virtuels** — votre mixage routé apparaît comme une entrée **OpenAudio** dans n'importe quelle app ou STAN.
- 🎧 **Écoute de contrôle en temps réel** vers votre propre sortie, avec réglage de niveau.
- 📊 **Vumètres en direct par canal** avec maintien de crête.
- ⏺ **Enregistrement** du mixage final (ou d'un bus individuel) dans un fichier.
- 🎛 **Plusieurs bus** (jusqu'à 8) pour des routes parallèles.
- 🎤 **Entrée micro / interface audio** comme source mixable.
- 🖥 **App légère dans la barre des menus** — sans encombrer le Dock.

## Prérequis

- macOS **14.4** ou ultérieur (Apple Silicon ou Intel)
- Droits d'administrateur pour l'installation unique du pilote

## Installation

1. [**Téléchargez `OpenAudio-1.0.0.pkg`**](https://github.com/DTMER2/openaudio/releases/latest) depuis la dernière version.
2. Ouvrez le programme d'installation et suivez les étapes. Il installe un pilote audio HAL et l'application, puis redémarre Core Audio.
3. Lancez **OpenAudio** depuis le dossier Applications — son icône apparaît dans la barre des menus.
4. Lorsque vous y êtes invité, accordez l'**autorisation de capture audio** (Réglages Système › Confidentialité et sécurité). Elle est nécessaire pour capturer l'audio des apps/du système.

Le programme d'installation est **signé avec un Developer ID** et **certifié (notarized) par Apple**.

> **Astuce :** OpenAudio est une app de barre des menus, elle n'a donc pas d'icône dans le Dock. Pour un lancement automatique, ajoutez-la dans Réglages Système › Général › Ouverture.

## Fonctionnement

OpenAudio combine deux technologies de macOS :

- Un **Core Audio Process Tap** capture l'audio des apps choisies ou du système entier (macOS 14.4+).
- Un **périphérique virtuel AudioServerPlugIn** fourni expose le mixage routé comme une entrée que d'autres apps et STAN peuvent sélectionner.

L'application se charge du mixage et du routage entre les deux — sans Configuration audio et MIDI, sans périphériques agrégés ou de sortie multiple à créer manuellement.

## Désinstallation

```sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/OpenAudioDriver.driver /Applications/OpenAudio.app
sudo killall coreaudiod
```

## Absent du Mac App Store

OpenAudio installe un pilote audio système (dans `/Library/Audio/Plug-Ins/HAL`) et redémarre `coreaudiod`, ce que le bac à sable de l'App Store n'autorise pas. Il est donc distribué hors du store sous forme de programme d'installation signé et certifié.

## Licence

**Propriétaire — tous droits réservés.** Le code source est public uniquement à des fins de transparence et d'évaluation. Voir [LICENSE](LICENSE).
