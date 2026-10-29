const assert = require("node:assert/strict");
const fs = require("node:fs");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(new URL("./mic-lock.js", `file://${__filename}`), "utf8");

function makePage(devices, returnedId, enabled = true) {
  const document = new EventTarget();
  document.addEventListener("AppAudioRouter:ready", () => document.dispatchEvent(new CustomEvent("AppAudioRouter:settings", {detail:{enabled}})));
  const calls = [];
  const mediaDevices = {
    async enumerateDevices() {
      return devices;
    },
    async getUserMedia(constraints) {
      calls.push(constraints);
      const track = { readyState: "live", getSettings: () => ({deviceId: returnedId || constraints.audio?.deviceId?.exact}), stop() { this.readyState = "ended"; } };
      return { requested: constraints, getAudioTracks: () => constraints.audio ? [track] : [], getTracks: () => [track] };
    },
  };
  const logs = [];
  const context = {
    navigator: { mediaDevices }, document, Event, CustomEvent,
    DOMException,
    console: { info: (...args) => logs.push(args), error: (...args) => logs.push(args) },
  };
  vm.runInNewContext(source, context);
  return { mediaDevices, calls, logs, document };
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

test("rejects and stops a physical fallback returned by the browser", async () => {
 const page=makePage([{kind:"audioinput",label:"BlackHole 2ch",deviceId:"loopback"}],"physical");
 await assert.rejects(page.mediaDevices.getUserMedia({audio:true}),{name:"NotReadableError"});
});
test("reconnection resolves the current loopback ID each time", async () => {
 const devices=[{kind:"audioinput",label:"BlackHole 2ch",deviceId:"first"}];
 const page=makePage(devices);
 await page.mediaDevices.getUserMedia({audio:true});
 devices[0].deviceId="second";
 await page.mediaDevices.getUserMedia({audio:true});
 assert.equal(page.calls[1].audio.deviceId.exact,"second");
});

test("OFF passes physical device constraints through unchanged", async () => {
 const page=makePage([],undefined,false);const constraints={audio:{deviceId:{exact:"physical"}},video:true};
 await page.mediaDevices.getUserMedia(constraints);assert.equal(page.calls[0],constraints);
});
test("toggle stops existing audio and applies to the next request", async () => {
 const page=makePage([{kind:"audioinput",label:"BlackHole 2ch",deviceId:"loopback"}]);
 const stream=await page.mediaDevices.getUserMedia({audio:true});
 page.document.dispatchEvent(new CustomEvent("AppAudioRouter:settings",{detail:{enabled:false}}));
 assert.equal(stream.getAudioTracks()[0].readyState,"ended");
 await page.mediaDevices.getUserMedia({audio:true});assert.equal(page.calls[1].audio,true);
 page.document.dispatchEvent(new CustomEvent("AppAudioRouter:settings",{detail:{enabled:true}}));
 await page.mediaDevices.getUserMedia({audio:true});assert.equal(page.calls[2].audio.deviceId.exact,"loopback");
});
