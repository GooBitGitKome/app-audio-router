(() => {
  const mediaDevices = navigator.mediaDevices;
  if (!mediaDevices || typeof mediaDevices.getUserMedia !== "function") return;

  const originalGetUserMedia = mediaDevices.getUserMedia.bind(mediaDevices);
  let loggedDeviceLabel = false;

  async function findLoopbackInput() {
    const devices = await mediaDevices.enumerateDevices();
    const inputs = devices.filter((device) => device.kind === "audioinput" && device.deviceId);
    return (
      inputs.find((device) => device.label.toLowerCase().includes("blackhole 2ch")) ||
      inputs.find((device) => device.label.toLowerCase().includes("appaudiorouter virtual microphone")) ||
      null
    );
  }

  mediaDevices.getUserMedia = function appAudioRouterGetUserMedia(constraints) {
    if (!constraints || !constraints.audio) {
      return originalGetUserMedia(constraints);
    }

    return (async () => {
      const input = await findLoopbackInput();
      if (!input) {
        const error = new DOMException(
          "Allow microphone access for this site, then reload. AppAudioRouter Mic Lock requires BlackHole 2ch or AppAudioRouter Virtual Microphone and will not fall back to the system default.",
          "NotFoundError"
        );
        console.error("[AppAudioRouter Mic Lock] No permitted loopback microphone was found.", error);
        throw error;
      }

      if (!loggedDeviceLabel) {
        console.info(`[AppAudioRouter Mic Lock] Voice capture pinned to: ${input.label}`);
        loggedDeviceLabel = true;
      }

      const audioConstraints =
        typeof constraints.audio === "object" ? { ...constraints.audio } : {};
      audioConstraints.deviceId = { exact: input.deviceId };
      return originalGetUserMedia({ ...constraints, audio: audioConstraints });
    })();
  };
})();
