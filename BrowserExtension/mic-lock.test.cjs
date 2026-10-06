const assert = require("node:assert/strict");
const fs = require("node:fs");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(new URL("./mic-lock.js", `file://${__filename}`), "utf8");

function makePage(devices) {
  const calls = [];
  const mediaDevices = {
    async enumerateDevices() {
      return devices;
    },
    async getUserMedia(constraints) {
      calls.push(constraints);
      return { requested: constraints };
    },
  };
  const logs = [];
  const context = {
    navigator: { mediaDevices },
    DOMException,
    console: { info: (...args) => logs.push(args), error: (...args) => logs.push(args) },
  };
  vm.runInNewContext(source, context);
  return { mediaDevices, calls, logs };
}

test("pins audio to BlackHole and preserves video and audio processing constraints", async () => {
  const { mediaDevices, calls } = makePage([
    { kind: "audioinput", label: "Beats Solo Buds", deviceId: "physical" },
    { kind: "audioinput", label: "BlackHole 2ch", deviceId: "loopback" },
  ]);

  await mediaDevices.getUserMedia({ audio: { echoCancellation: true }, video: true });
  assert.equal(calls.length, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(calls[0].audio.deviceId)), { exact: "loopback" });
  assert.equal(calls[0].audio.echoCancellation, true);
  assert.equal(calls[0].video, true);
});

test("uses the AppAudioRouter virtual mic if BlackHole is unavailable", async () => {
  const { mediaDevices, calls } = makePage([
    { kind: "audioinput", label: "Beats Solo Buds", deviceId: "physical" },
    { kind: "audioinput", label: "AppAudioRouter Virtual Microphone", deviceId: "virtual" },
  ]);

  await mediaDevices.getUserMedia({ audio: true });
  assert.equal(calls[0].audio.deviceId.exact, "virtual");
});

test("fails closed instead of opening the system default microphone", async () => {
  const { mediaDevices, calls } = makePage([
    { kind: "audioinput", label: "Beats Solo Buds", deviceId: "physical" },
  ]);

  await assert.rejects(mediaDevices.getUserMedia({ audio: true }), { name: "NotFoundError" });
  assert.equal(calls.length, 0);
});

test("leaves requests without audio unchanged", async () => {
  const { mediaDevices, calls } = makePage([]);

  await mediaDevices.getUserMedia({ video: true });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].video, true);
});
