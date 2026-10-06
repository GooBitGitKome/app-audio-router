# AppAudioRouter Mic Lock for Brave

GFN can select the microphone associated with its active output device. In the current machine logs, GeForce NOW opens the Beats Solo Buds microphone while the system default input is also Beats. A site that asks for the browser's default microphone can therefore receive that device when a voice conversation begins.

This extension intercepts `getUserMedia()` on ChatGPT and Gemini pages before their page scripts run. It pins audio capture to `BlackHole 2ch`, or to `AppAudioRouter Virtual Microphone` if BlackHole is unavailable. It does not change macOS's default input, and it leaves calls that request no audio alone. If a loopback microphone cannot be identified, the request fails instead of silently opening the GFN/physical default microphone.

## Install in Brave

1. Open `brave://extensions`.
2. Turn on **Developer mode**.
3. Choose **Load unpacked** and select this repository's `BrowserExtension` folder.
4. Give ChatGPT and Gemini microphone permission in each site's settings. The browser hides microphone labels until the site has permission.
5. Reload the ChatGPT/Gemini tab and start a voice conversation. Open DevTools Console and confirm it reports `Voice capture pinned to: BlackHole 2ch` (or `AppAudioRouter Virtual Microphone`).

`BlackHole 2ch` must be present and allowed for the site. AppAudioRouter's desktop-to-mic route must be enabled while sending desktop audio. If neither loopback input is visible, the extension stops with `NotFoundError`; it will not use the system default.

The extension pins audio requests made through the web `getUserMedia()` API on the listed ChatGPT/Gemini pages. It does not change macOS dictation, GeForce NOW, or other sites. A page using a different capture API is outside its scope.

## Verify

Run `node --test BrowserExtension/mic-lock.test.cjs` from the repository root.
