# Rust migration (experimental)

The Cargo workspace implements a native Rust backend alongside the Swift application.
Swift remains the default packaging backend until the hardware and UI acceptance gates below pass. The earlier Swift reliability changes are retained. Do not remove Swift or describe the Rust backend as faster or more stable without measured results.

## Build and run

Requirements: macOS 14.2+, an Apple SDK, the pinned Rust toolchain (`rust-toolchain.toml`), and an existing bidirectional loopback driver such as BlackHole 2ch. Rust 2024 is used. Builds set `MACOSX_DEPLOYMENT_TARGET=14.2`.

```sh
cargo build --workspace --locked
cargo test --workspace --all-targets --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo fmt --all -- --check
cargo run -p router-cli -- devices
cargo run -p router-cli -- --help
AAR_BACKEND=rust ./scripts/package_app.sh
open AppAudioRouter.app
```

The opt-in Rust bundle contains both `AppAudioRouterApp` and `AppAudioRouterCLI` in `Contents/MacOS`. It retains bundle ID `com.devai.AppAudioRouter`, privacy descriptions, icon, Dock presence, and ad-hoc signing. Run the packaged app for permission and UI validation. The Rust package is a 2.0.0 preview; the Cargo version is `2.0.0-alpha.1`.

`AAR_BACKEND=rust ./scripts/package_release.sh` uses the existing ZIP layout, including the unchanged browser extension and Japanese installation guide. Both packaging backends write the same generated app and archive paths; package Swift again to restore the default build:

```sh
./scripts/package_app.sh
```

## Components and safety

- `router-core`: stereo Float32 ring, atomic controls and counters, gain/mute, peak, clipping, exclusion resolution, and PCM WAV encoding. No third-party dependencies.
- `router-macos`: typed HAL queries, discovery and property listeners, owned/borrowed aggregates, process taps, IOProc capture/rendering, recording workers, and in-process AVAudioPlayer playback. `Engine` uses exclusive mutable access for topology changes.
- `router-cli`: device/process lists, process monitoring, public aggregate creation, virtual-mic management, recording and tone/desktop diagnostics, and 500ms device watching. Existing command aliases are retained. Invalid arguments and unavailable hardware return nonzero status.
- `router-app`: main-thread AppKit status item/popover, regular Dock application, default-device selectors, desktop and microphone controls, exclusions, aggregate dialogs, and recording/playback controls. The existing `desktopTapExcludedBundleIDs` NSUserDefaults key is reused.

Global taps always resolve and include the calling process IDs. If these IDs cannot be resolved, global capture refuses to start. Exclusions match bundle IDs and dotted helper suffixes. Unavailable selected processes remain stored; they must have active CoreAudio process objects when the tap is recreated.

The dedicated virtual microphone retains UID `com.appaudiorouter.virtualmic.default`. Setup reuses a compatible existing aggregate without transferring ownership. Normal cleanup destroys only owned aggregates. Explicit CLI cleanup is intentionally allowed to destroy the dedicated fixed-UID aggregate. CLI aggregate/setup commands explicitly relinquish RAII ownership so the public device can remain available after the command exits. Browser enumeration/selection retention remains environment-dependent.

IOProc contexts and scratch buffers are allocated before device start. Callbacks perform no file I/O, UI work, dynamic allocation, or waiting acquisition. Rings use one atomic acquisition attempt; writes drop on contention and reads produce silence. Renderer membership uses `try_lock`; membership changes and resource destruction happen on control threads. Scratch work is bounded to 16,384 stereo frames per callback. Tests exercise the callback functions directly without hardware, and a counting allocator verifies that core audio operations neither allocate nor deallocate.

Native input/output must be Float32 PCM. Mono capture duplicates into stereo, stereo interleaved and planar capture are handled, and unused output channels are zeroed. Tap aggregate nominal rates are read back. Routing rejects mismatched source/output rates rather than assuming that HAL converted them. There is no new software resampler. Recording uses the effective capture format rate, has a maximum 30-second duration, and writes PCM16 WAV outside callbacks. Playback stays in-process to preserve self-exclusion.

If HAL cannot confirm callback unregistration, the backend retains the callback storage instead of freeing potentially live memory. Actual teardown semantics and device failure behavior require the hardware gates below.

## Remaining acceptance gates and differences

The implementation is a preview, not a completed migration acceptance report:

- Validate the native popover, dialogs, slider/mute interactions, menu bar/Dock behavior, and permission prompts in an interactive macOS session. AppKit styling intentionally differs from SwiftUI.
- Verify desktop and multiple microphone mixing with BlackHole and, where available, ZoomAudioDevice. Test both supported architectures and macOS 14.2 deployment. A host build does not establish either hardware matrix.
- Run `diagnose`, `test-tone`, `test-desktop`, and `test-virtual-mic` in the same environment as Swift. Enumeration and nonzero test peaks do not prove distortion-free audio or long-session continuity.
- Check repeated launch/quit, borrowed virtual-mic cleanup, driver restart, device disappearance, sample-rate changes, and sleep/wake. Re-enable routing explicitly after an invalidated output.
- Compare release-build CPU, resident memory, callback timing, and dropout counts during a 60-minute combined-audio session. No performance gain is asserted yet.
- Physical microphone meters currently run with enabled routes; they do not independently capture an unrouted microphone. The Rust exclusion list includes running GUI apps and saved selections, marks unresolved selections, and refreshes through Workspace and CoreAudio notifications. Existing stored exclusions are preserved.
- Per-process capture/routing and gain/mute are available in the backend, but there is no new per-app volume list in the UI. The CLI `tap` command monitors without enabling a loopback route.
- Review effective-format conversion behavior on each device. Unsupported formats fail explicitly; support parity with devices that require conversion remains unverified.

Hardware tests are opt-in, serial, and must not disturb a running app:

```sh
# Stop AppAudioRouter and remove its dedicated microphone first.
cargo test -p router-macos --test hardware -- --ignored --test-threads=1
cargo run -p router-cli -- diagnose
cargo run -p router-cli -- test-tone
cargo run -p router-cli -- test-desktop
```

If no devices are visible, report hardware access as unverified. Do not turn those tests into successful skips or infer that drivers are absent. Keep Swift as the default until these gates pass; retire SPM/Swift/C only in the subsequent validated cutover.

## Verification recorded during implementation

On 2026-10-29, on the Intel host running macOS 15.8.2:

- Cargo workspace checks, Clippy with warnings denied, and all 15 automatic tests passed. The two opt-in hardware tests also passed when run separately with real CoreAudio access. The ownership test exposed an asynchronous publication race; aggregate creation now waits up to 500ms on the control thread for discoverability before returning. Tap rate readback likewise waits for bounded asynchronous settlement.
- The existing Swift suite passed all 13 tests with CoreAudio access. Inside the execution sandbox, hardware enumeration returned no devices and the existing Swift process-list test crashed; these sandbox results do not establish a hardware regression.
- Packaged Rust `diagnose`, `test-tone`, and `test-desktop` succeeded with actual CoreAudio access. The tone recording peak was 16383/32767 and the desktop test peak was 10227/32767. These signal-presence checks do not measure distortion or continuity.
- Swift `diagnose` completed. Swift `test-tone` completed with a verification warning (672.9 zero crossings/sec versus the command's expected approximately 880); this is retained as a baseline limitation, not reported as clean audio acceptance.
- The Rust native startup/shutdown smoke test passed (`AppAudioRouter.app/Contents/MacOS/AppAudioRouterApp --smoke-test`). This constructs the AppKit controls and quits automatically; it is not visual interaction coverage. The UI inspection tool timed out, so visual QA remains outstanding.
- The Rust app and local ZIP were built, ad-hoc signed, and the app signature verified. Icon packaging requires access to the host's macOS image services and failed inside the restricted sandbox.

Apple Silicon execution, macOS 14.2 execution, interactive permission/UI testing, and the 60-minute performance/continuity comparison remain unverified. No measured performance advantage is claimed.

## Audio-test/readability follow-up

The native panel now labels the menu bar item **Audio**, uses larger adaptive text/background colors, keeps tests/status at the top, and collapses advanced settings. Use **Test desktop route** for an automatic test sound; **Record enabled sources** only records sources explicitly enabled by the user. Recordings now use the active loopback input and distinguish silence from a captured signal. See [usage](usage.md) and [specification](specification.md) for exact behavior.

Developer-only host checks:

```sh
# Executes the exact in-app desktop test, plays the result, and exits with
# failure if no recorded signal is detected. Maximum runtime is bounded.
AppAudioRouter.app/Contents/MacOS/AppAudioRouterApp --test-desktop-in-app

# Render only the app's own view; no other windows are captured.
AAR_PREVIEW_PNG=/tmp/router-light.png AppAudioRouter.app/Contents/MacOS/AppAudioRouterApp --smoke-test
AAR_PREVIEW_APPEARANCE=dark AAR_PREVIEW_PNG=/tmp/router-dark.png AppAudioRouter.app/Contents/MacOS/AppAudioRouterApp --smoke-test

# Physical input frame counts only: no file and no output route.
cargo test -p router-macos --lib physical_microphone_delivers_frames_without_routing_or_saving_audio -- --ignored --test-threads=1
```

Follow-up verification on the same host: all 19 automatic Rust tests passed; the physical microphone input-frame test passed without saving/routing microphone audio. The in-app desktop test recorded 5.00s with peak 0.30016 and detected a signal. Native view renders were inspected in light and dark appearance. Swift build and tests passed (13 reported, one ownership test skipped because another virtual mic existed). Swift diagnostics completed; its tone check still emitted a signal-verification warning (711.2 zero crossings/sec versus approximately 880 expected). This warning is not presented as a clean Swift audio acceptance result.
