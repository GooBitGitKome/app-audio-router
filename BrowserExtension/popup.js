const toggle = document.getElementById("enabled");
const state = document.getElementById("state");
const status = document.getElementById("status");
function show(enabled) { toggle.checked = enabled; state.textContent = enabled ? "ON" : "OFF"; }
chrome.storage.local.get({ enabled: true }).then(({ enabled }) => { show(enabled !== false); toggle.disabled = false; }).catch(() => { status.textContent = "設定を読み込めません。拡張を再読み込みしてください。"; });
toggle.addEventListener("change", async () => {
  const enabled = toggle.checked;
  toggle.disabled = true;
  try { await chrome.storage.local.set({ enabled }); show(enabled); status.textContent = "保存しました。音声会話を再接続してください。"; }
  catch { show(!enabled); status.textContent = "保存に失敗しました。"; }
  finally { toggle.disabled = false; }
});
