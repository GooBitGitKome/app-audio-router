# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Documentation
- Recorded the 2026-10-29 Brave / GeForce NOW microphone recovery, distinguishing observed physical-device reacquisition from the inferred stale-page cause, with rebuild requirements, extension/tab reload steps, and actual-track verification.

### Mic Lock toggle
- Added a persistent ON/OFF toolbar popup in Mic Lock 1.2.0, with live settings propagation and audio shutdown on mode changes. OFF restores the site's normal microphone selection; reconnect voice after switching.


### Browser input separation
- Mic Lock 1.1.0 verifies returned audio tracks, blocks physical fallback, resolves IDs again on reconnection, and covers related frames.


### Rust audio test and readability fixes
- Moved audio tests/status ahead of advanced settings, enlarged text and controls, added an adaptive background, and labeled the menu bar item Audio.
- Added an in-app desktop-route test that plays a system sound only after actual input buffers arrive; recordings use the active loopback input.
- Recording enabled sources now explains missing routes, detects effectively silent captures, and avoids automatically playing silence as a successful test.
- Showed playback destination and microphone sample-rate incompatibility beside controls; preserved scroll position during control updates.
- Added recording reports/readiness to the Rust worker interface and regression tests for empty routes, muted tests, target selection, silence, and physical microphone frame delivery.


### Rust migration preview
- Added a Cargo workspace with a preallocated Rust audio core, native CoreAudio backend, compatible CLI command names/aliases, and AppKit menu bar/Dock application.
- Added Rust unit, concurrent-buffer, synthetic IOProc, zero-allocation, and explicitly opt-in hardware tests, plus Rust CI checks.
- Added opt-in `AAR_BACKEND=rust` app/release packaging while preserving Swift as the default pending hardware and UI validation.
- Preserved fixed virtual-mic identity, self-exclusion, borrowed-device ownership, exclusion preferences, and browser extension packaging. Rust rejects unresolved self-exclusion and unverified/incompatible capture clocks; runtime parity and performance gains remain unverified.


### Reliability
- Detach obsolete process-output consumers when changing routing destinations.
- Verify tap aggregate nominal sample rates and reject unverified clocks.

### Changed
- App now appears in the Dock as a regular macOS application while retaining the menu bar controls and Quit action.
- Added a release packaging script that creates a downloadable ZIP containing the app, Brave extension, and Japanese installation guide.

### Added
- Added a custom audio-routing app icon to the Dock and packaged application.

### Fixed
- Added an optional Brave extension that pins ChatGPT/Gemini `getUserMedia()` audio requests to BlackHole or AppAudioRouter Virtual Microphone with an exact device ID, preventing an automatic fallback to GFN's current physical/default input.
- Aggregate creation now rejects missing or nested aggregate subdevices instead of accepting stale tap UIDs or silently dropping invalid members. `diagnose` reports unavailable members of the current default input.
- Dedicated virtual-microphone identification no longer accepts unrelated Combined Microphones aggregates or matching display names. The current system input remains visible in Master Input.
- Reusing an aggregate microphone no longer transfers ownership to a second app/CLI/test instance; normal cleanup cannot destroy a borrowed device. Reuse compares configured subdevice UIDs instead of only active devices.
- Expanded `watch-input` to report BlackHole/Bluetooth and other device additions, removals, object IDs, channel counts, sample rates and default input/output changes.
- Reduced real-time audio callback allocations and moved meter notifications off CoreAudio callback queues.
- Audio ring callbacks now use non-waiting lock acquisition; a contended input block is dropped or the output block is filled with silence to keep CoreAudio callbacks moving.
- App device/process lists now refresh from CoreAudio and workspace notifications rather than a 1.5-second full-enumeration poll.
- Desktop-to-microphone routing now stays off when tap/device startup fails, and loopback selection requires a non-aggregate virtual device with both input and output channels.
- Replacing an active desktop tap detaches its old renderer buffer before starting the new route.
- Virtual microphone setup reuses the existing deterministic-UID device when its loopback source is unchanged, and the second launch-time setup call has been removed.
- Desktop capture can exclude selected apps (including Chromium helper processes) by bundle identifier, with exclusions persisted and applied immediately to an active route.

### Documentation
- Clarified the GeForce NOW setup: keep the physical microphone as macOS default and explicitly select BlackHole 2ch in Brave instead of Automatically.
- Made `BlackHole 2ch` the recommended Gemini/Chromium microphone because the browser may not enumerate the app-created Aggregate Input Device; documented how to verify input in the browser.
- Documented Safari YouTube + Chrome Gemini Live routing and separate Brave virtual-mic / GeForce NOW physical-mic selection.
- Added `watch-input` diagnostics for tracking macOS default-input and virtual-microphone identity changes around GeForce NOW sessions.

---

## [1.0.1] - 2026-10-05

### Fixed
- **Persistent Virtual Microphone UID (`com.appaudiorouter.virtualmic.default`)**: Resolved an issue where random UUID generation for ephemeral aggregate devices caused Chromium-based browsers (Brave, Chrome) to lose device bindings upon relaunch, resulting in silent fallback to physical microphones (Bluetooth/USB).
- **Default Master Input Override Protection**: Changed the default state of `setAsDefaultInputUponCreation` in the UI to `false` to avoid unintentional hijacking of the system default input device.
- **Aggregate Device Cleanup by UID**: Added `destroyDeviceByUID(_:)` to `AggregateDeviceManager` to safely purge previous aggregate devices with matching static UIDs before re-creating the virtual microphone.

### Added
- **Automated Desktop Audio Pipeline CLI Test (`test-desktop`)**: Added `swift run AppAudioRouterCLI test-desktop` command to verify end-to-end routing of desktop audio (playing system sound, captured by ProcessTap, routed through loopback driver, and recorded from virtual mic input).
- **Chromium / Brave Direct Loopback Guidance**: Added UI hints and documentation for Brave and Chrome users noting that selecting the direct loopback sub-device (`BlackHole 2ch`) bypasses Chromium's CoreAudio AUHAL aggregate device enumeration limitations.
- **Unit Test for Persistent Virtual Mic UID**: Added `testVirtualMicrophonePersistentUID` to verify deterministic UID assignment.

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
