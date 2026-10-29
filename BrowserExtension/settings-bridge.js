(() => {
  let revision = 0;
  const publish = () => { const current = ++revision; return chrome.storage.local.get({ enabled: true }).then(({ enabled }) => {
    if (current !== revision) return;
    document.dispatchEvent(new CustomEvent("AppAudioRouter:settings", { detail: { enabled: enabled !== false } }));
  }).catch((error) => console.error("Mic Lock settings unavailable", error)); };
  document.addEventListener("AppAudioRouter:ready", publish);
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.enabled) publish();
  });
  publish();
})();
