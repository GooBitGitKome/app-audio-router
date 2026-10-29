(() => {
  const mediaDevices = navigator.mediaDevices;
  if (!mediaDevices || typeof mediaDevices.getUserMedia !== "function") return;

  const originalGetUserMedia = mediaDevices.getUserMedia.bind(mediaDevices);
  const installed = Symbol.for("AppAudioRouter.MicLock");
  if (mediaDevices[installed]) return;
  mediaDevices[installed] = true;

  let enabled = true;
  let generation = 0;
  const active = new Set();
  let resolveSettings;
  const settingsReady = new Promise((resolve) => { resolveSettings = resolve; });
  document.addEventListener("AppAudioRouter:settings", (event) => {
    const next = event.detail?.enabled;
    if (typeof next !== "boolean") return;
    if (next !== enabled) {
      generation += 1;
      for (const stop of active) stop();
      active.clear();
    }
    enabled = next;
    resolveSettings();
  });
  document.dispatchEvent(new Event("AppAudioRouter:ready"));

  async function findLoopbackInput() {
    const devices = await mediaDevices.enumerateDevices();
    const inputs = devices.filter((device) => device.kind === "audioinput" && device.deviceId);
    return (
      inputs.find((device) => device.label.toLowerCase().includes("blackhole 2ch")) ||
      inputs.find((device) => device.label.toLowerCase().includes("appaudiorouter virtual microphone")) ||
      null
    );
  }

  const lockedGetUserMedia = function appAudioRouterGetUserMedia(constraints) {
    if (!constraints || !constraints.audio) {
      return originalGetUserMedia(constraints);
    }

    return (async () => {
      await settingsReady;
      const requestGeneration = generation;
      if (!enabled) {
        const stream = await originalGetUserMedia(constraints);
        if (generation !== requestGeneration) {
          stream.getTracks().forEach((track) => track.stop());
          throw new DOMException("Mic Lock changed; reconnect voice.", "AbortError");
        }
        const stop = () => { stream.getAudioTracks().forEach((track) => track.stop()); active.delete(stop); };
        active.add(stop);
        stream.getAudioTracks().forEach((track) => track.addEventListener?.("ended", () => { if (stream.getAudioTracks().every((item) => item.readyState === "ended")) active.delete(stop); }));
        return stream;
      }
      const input = await findLoopbackInput();
      if (!input) {
        const error = new DOMException(
          "Allow microphone access for this site, then reload. AppAudioRouter Mic Lock requires BlackHole 2ch or AppAudioRouter Virtual Microphone and will not fall back to the system default.",
          "NotFoundError"
        );
        console.error("[AppAudioRouter Mic Lock] No permitted loopback microphone was found.", error);
        throw error;
      }

      const audioConstraints =
        typeof constraints.audio === "object" ? { ...constraints.audio } : {};
      audioConstraints.deviceId = { exact: input.deviceId };
      delete audioConstraints.groupId;
      const stream = await originalGetUserMedia({ ...constraints, audio: audioConstraints });
      if (generation !== requestGeneration) {
        stream.getTracks().forEach((track) => track.stop());
        throw new DOMException("Mic Lock changed; reconnect voice.", "AbortError");
      }
      const tracks = stream.getAudioTracks();
      if (!tracks.length || tracks.some((track) => track.getSettings().deviceId !== input.deviceId)) {
        stream.getTracks().forEach((track) => track.stop());
        throw new DOMException("Mic Lock stopped an unexpected input device. Physical microphone fallback is blocked.", "NotReadableError");
      }
      console.info(`[AppAudioRouter Mic Lock] Verified voice input: ${input.label}`);
      const verify = async () => {
        const devices = await mediaDevices.enumerateDevices();
        const available = devices.some((device) => device.kind === "audioinput" && device.deviceId === input.deviceId);
        for (const track of tracks) {
          if (!available || track.getSettings().deviceId !== input.deviceId) {
            track.stop();
            console.error("[AppAudioRouter Mic Lock] Virtual input lost. Reconnect voice after restoring the loopback; physical fallback is blocked.");
          }
        }
      };
      const stop = () => { tracks.forEach((track) => track.stop()); mediaDevices.removeEventListener?.("devicechange", onChange); active.delete(stop); };
      active.add(stop);
      const cleanup = () => {
        if (tracks.every((track) => track.readyState === "ended")) { mediaDevices.removeEventListener?.("devicechange", onChange); active.delete(stop); }
      };
      const onChange = () => { verify().catch(() => tracks.forEach((track) => track.stop())).finally(cleanup); };
      mediaDevices.addEventListener?.("devicechange", onChange);
      tracks.forEach((track) => track.addEventListener?.("ended", cleanup));
      return stream;
    })();
  };
  mediaDevices.getUserMedia = lockedGetUserMedia;
  const prototype = Object.getPrototypeOf(mediaDevices);
  if (prototype && prototype !== Object.prototype && typeof prototype.getUserMedia === "function") {
    prototype.getUserMedia = lockedGetUserMedia;
  }
})();
