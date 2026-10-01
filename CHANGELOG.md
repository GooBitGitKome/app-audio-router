# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Standard repository documentation suite (`docs/specification.md`, `docs/architecture.md`, `docs/installation.md`, `docs/usage.md`, `docs/development.md`, `docs/versioning.md`, `docs/release-process.md`, `docs/roadmap.md`).
- AI agent collaboration guidelines (`AGENTS.md`, `AI_USAGE.md`).
- Contribution guidelines and templates (`CONTRIBUTING.md`, GitHub issue/PR templates).

---

## [1.0.0] - 2026-10-01

### Added
- **Ephemeral Virtual Microphone**: Dynamic publication of `AppAudioRouter Virtual Microphone` via CoreAudio Aggregate Device on launch, and automatic destruction on application exit.
- **Desktop Audio to Virtual Mic**: Real-time macOS desktop audio capture using `CATapDescription(stereoGlobalTapButExcludeProcesses:)` with volume scaling, muting, and level metering.
- **Process Tap Self-Exclusion**: Automatic detection of the application's own `AudioObjectID`s and inclusion in `excludeProcesses` to eliminate digital feedback loops.
- **48kHz Sample Rate Synchronization**: HAL-level sample rate alignment on `TapAggregateDevice` to prevent buffer underruns, click artifacts, and pitch drift.
- **Soft Clamping & Output Safety**: Accelerated `vDSP_vclip` output clamping in `AudioOutputRenderer` and overflow protection in `AudioRingBuffer`.
- **Live Multi-Microphone Mixing**: Support for physical input devices with independent gain, mute, VU metering, and mono-to-stereo/planar buffer handling.
- **Virtual Input Self-Tester**: Built-in 5-second test capture from the virtual microphone, 16-bit WAV encoding, and automatic speaker playback.
- **Desktop Audio Gauge**: Real-time level meter gauge in menu bar with rendering toggle.
- **Multi-Output & Aggregate Device Wizards**: One-click creation of Multi-Output and Aggregate Microphone devices.
- **Standalone CLI Tools**: `app-audio-router` CLI with commands `devices`, `processes`, `tap`, `multi-output`, `multi-input`, `setup-virtual-mic`, `cleanup-virtual-mic`, `test-virtual-mic`, `test-tone`, and `diagnose`.

### Removed
- Removed application-specific process list from MenuBar UI per user request, simplifying interface to focused microphone and desktop audio routing.
