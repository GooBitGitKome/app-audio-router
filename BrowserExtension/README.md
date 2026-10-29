# AppAudioRouter Mic Lock for Brave

GFN can select the microphone associated with its active output device. In the current machine logs, GeForce NOW opens the Beats Solo Buds microphone while the system default input is also Beats. A site that asks for the browser's default microphone can therefore receive that device when a voice conversation begins.

This extension intercepts `getUserMedia()` on ChatGPT and Gemini pages before their page scripts run. It pins audio capture to `BlackHole 2ch`, or to `AppAudioRouter Virtual Microphone` if BlackHole is unavailable. It does not change macOS's default input, and it leaves calls that request no audio alone. If a loopback microphone cannot be identified, the request fails instead of silently opening the GFN/physical default microphone.

## Install in Brave

1. Open `brave://extensions`.
2. Turn on **Developer mode**.
3. Choose **Load unpacked** and select this repository's `BrowserExtension` folder.
4. Give ChatGPT and Gemini microphone permission in each site's settings. The browser hides microphone labels until the site has permission.
5. Reload the ChatGPT/Gemini tab and start a voice conversation. Open DevTools Console and confirm it reports `Verified voice input: BlackHole 2ch` (or `AppAudioRouter Virtual Microphone`).

For recovery after rebuilding or updating, see the [Brave / GeForce NOW recovery record](../docs/brave-gfn-microphone-recovery.md). Reload both the extension and existing supported tabs; an ON popup alone does not prove the current page is using the updated hook.

`BlackHole 2ch` must be present and allowed for the site. AppAudioRouter's desktop-to-mic route must be enabled while sending desktop audio. If neither loopback input is visible, the extension stops with `NotFoundError`; it will not use the system default.

The extension pins audio requests made through the web `getUserMedia()` API on the listed ChatGPT/Gemini pages. It does not change macOS dictation, GeForce NOW, or other sites. A page using a different capture API is outside its scope.

## Verify

Run `node --test BrowserExtension/mic-lock.test.cjs` from the repository root.

## Version 1.1.0
Reload this unpacked extension in Brave and reload ChatGPT tabs. Each new voice acquisition verifies the returned track ID. Unexpected physical inputs are stopped before the stream reaches the page. Keep the game on the macOS default physical microphone; enable only desktop routing for ChatGPT. Native Rust UI/reconnection changes remain pending.

## ON / OFF toggle (1.2.0)
Reload the extension in `brave://extensions`, then reload existing ChatGPT/Gemini tabs once. Click the extension's toolbar icon to open the **入力固定 ON/OFF** switch. Default is ON; the choice is saved locally across browser restarts and applies to all supported tabs.

ON fixes new audio requests to the verified loopback input. OFF passes the site's original microphone constraints unchanged. Toggling stops audio tracks acquired through this extension in either mode, including pending acquisitions when they resolve; reconnect the voice conversation to use the new mode. No physical microphone is automatically opened by toggling. Video-only requests and macOS/game microphone settings are unchanged. When OFF, the site may choose a physical microphone normally.
