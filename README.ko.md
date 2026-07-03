<div align="center">

# OpenAudio

**macOS 오디오를 라우팅·캡처·모니터링·녹음 — Audio MIDI 설정을 건드리지 않고.**

[English](README.md) · [日本語](README.ja.md) · **한국어** · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Français](README.fr.md)

[**⬇ 최신 릴리스 다운로드**](https://github.com/DTMER2/openaudio/releases/latest)

</div>

---

OpenAudio는 macOS용 라우팅 + 캡처 통합 오디오 유틸리티로, BlackHole와 Loopback을 하나로 합친 대안입니다. 앱별 또는 시스템 전체 오디오를 캡처해 믹싱·라우팅하고, 그 결과를 다른 앱이나 DAW에서 선택할 수 있는 가상 입력 장치로 노출합니다. 모니터링과 녹음도 가능하며, Aggregate나 다중 출력 장치를 손수 구성할 필요가 전혀 없습니다.

## 주요 기능

- 🎙 **앱별 및 시스템 전체 캡처** — Core Audio Process Tap(macOS 14.4+)으로 "Spotify만" 또는 전체를 녹음.
- 🎚 **라우팅 매트릭스** — 임의의 소스를 임의의 버스로. 소스별 게인 / 팬 / 뮤트 / 솔로.
- 🔌 **가상 출력 장치** — 믹스 결과가 모든 앱과 DAW에서 **OpenAudio** 입력으로 나타남.
- 🎧 **실시간 모니터링** — 자신의 출력으로 패스스루, 레벨 조절 포함.
- 📊 **채널별 실시간 미터**(피크 홀드 포함).
- ⏺ **녹음** — 최종 믹스(또는 개별 버스)를 파일로.
- 🎛 **다중 버스**(최대 8개)로 병렬 라우팅.
- 🎤 **마이크 / 오디오 인터페이스 입력**을 믹스 소스로 사용.
- 🖥 **가벼운 메뉴 막대 앱** — Dock을 차지하지 않음.

## 요구 사항

- macOS **14.4** 이상 (Apple Silicon 또는 Intel)
- 드라이버 최초 설치 시 관리자 권한

## 설치

1. 최신 릴리스에서 [**`OpenAudio-1.0.0.pkg` 다운로드**](https://github.com/DTMER2/openaudio/releases/latest).
2. 설치 프로그램을 열고 진행합니다. HAL 오디오 드라이버와 앱을 설치하고 Core Audio를 재시작합니다.
3. 응용 프로그램 폴더에서 **OpenAudio**를 실행 — 메뉴 막대에 아이콘이 표시됩니다.
4. 메시지가 나타나면 **오디오 캡처 권한**(시스템 설정 › 개인정보 보호 및 보안)을 허용하세요. 앱/시스템 오디오 캡처에 필요합니다.

설치 프로그램은 **Developer ID로 서명**되고 **Apple의 공증**을 받았습니다.

> **팁:** OpenAudio는 메뉴 막대 앱이므로 Dock 아이콘이 없습니다. 자동 실행하려면 시스템 설정 › 일반 › 로그인 항목에 추가하세요.

## 작동 원리

OpenAudio는 두 가지 macOS 기술을 결합합니다.

- **Core Audio Process Tap**이 선택한 앱 또는 시스템 전체의 오디오를 캡처(macOS 14.4+).
- 함께 제공되는 **AudioServerPlugIn 가상 장치**가 라우팅 결과를 다른 앱과 DAW가 선택할 수 있는 입력으로 노출.

그 사이의 믹싱과 라우팅은 앱이 담당합니다. Audio MIDI 설정도, Aggregate / 다중 출력 장치를 수동으로 만들 필요도 없습니다.

## 제거

```sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/OpenAudioDriver.driver /Applications/OpenAudio.app
sudo killall coreaudiod
```

## Mac App Store에 없는 이유

OpenAudio는 시스템 오디오 드라이버를 `/Library/Audio/Plug-Ins/HAL`에 설치하고 `coreaudiod`를 재시작하는데, 이는 App Store 샌드박스에서 허용되지 않습니다. 따라서 서명·공증된 설치 프로그램으로 스토어 외부에서 배포합니다.

## 라이선스

**독점 소프트웨어 — 모든 권리 보유.** 소스는 투명성과 평가 목적으로만 공개됩니다. [LICENSE](LICENSE)를 참조하세요.
