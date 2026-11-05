// ram-watch.mjs - talks to OpenAI through "Sign in with ChatGPT" (official @siwc/local SDK).
// Usage:
//   node ram-watch.mjs login                         one-time browser sign-in
//   node ram-watch.mjs status                        show connection state
//   node ram-watch.mjs review <snapshot.json> <out>  send snapshot, write the model's report
// Credentials are stored encrypted with Windows DPAPI (current user) in .\auth\.
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const { createChatGPT } = await import(pathToFileURL(join(here, "siwc-devkit", "packages", "local", "dist", "index.js")).href);

function dpapi(mode, base64In) {
  const op = mode === "protect" ? "Protect" : "Unprotect";
  const ps = `Add-Type -AssemblyName System.Security; $in=[Convert]::FromBase64String([Console]::In.ReadToEnd().Trim()); ` +
    `[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::${op}($in,$null,'CurrentUser'))`;
  const r = spawnSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", ps], { input: base64In, encoding: "utf8", windowsHide: true });
  if (r.status !== 0) throw new Error("DPAPI failed");
  return r.stdout.trim();
}

const credentialEncryption = {
  id: "windows-dpapi-user",
  isAvailable: () => process.platform === "win32",
  encrypt: (plaintext) => Buffer.from(dpapi("protect", Buffer.from(plaintext, "utf8").toString("base64")), "base64"),
  decrypt: (ciphertext) => Buffer.from(dpapi("unprotect", Buffer.from(ciphertext).toString("base64")), "base64").toString("utf8"),
};

const chatgpt = createChatGPT({
  appName: "RAM Watch",
  appId: "ram-watch",
  redirectPort: 0,
  storageDir: join(here, "auth"),
  credentialEncryption,
});

const BASE_INSTRUCTIONS = `You are a Windows memory- and system-health checker. You get a JSON snapshot of a Windows PC.
Goal: catch background processes that were supposedly closed but are still holding memory, memory leaks, and hardware/power trouble.
Look for: many identical processes (e.g. headless chrome/msedge with --remote-debugging-port, duplicate dev/MCP servers),
orphaned process trees (parent gone), processes that exited but are still alive (stuck in kernel), very old helper processes,
a single long-running process whose private memory keeps growing, commit charge close to its limit, and a large non-paged pool
(normal is under ~1000 MB; "kernel_pool_top_tags" shows which pool tags hold it - name the driver if you recognise the tag).
Ignore normal Windows/system processes and normal app usage (an open browser, an editor, etc.).
The "health" section has power (AC/battery), thermal zones, GPU / Bluetooth / Wi-Fi device state, free space on C:, and System-log events.
Flag: Kernel-Power 41 / EventLog 6008 (unexpected shutdown), BugCheck 1001, nvlddmkm/Display 4101 (GPU driver resets), WHEA hardware errors,
Bluetooth driver errors, frequent Kernel-Power 105 (AC/battery switching = unstable power), high temperatures or thermal throttling.
A device disabled on purpose (CM_PROB_DISABLED / code 22) is worth reporting but is not an error by itself.
The "daily" section (once a day) has: battery report (responsive or hung, design vs full capacity, cycles), driver changes since the
previous day, Reliability Monitor records (app crashes/hangs, Windows failures, installs), pending reboot/updates, volume free space,
SSD health counters, and how far back the System event log reaches. Treat sudden battery capacity drops or a battery that stops
answering as a possible swollen/failing battery.
"power_switches_24h" lists every charger/battery switch with the load at that moment; kind "charger_dropout" means the PC fell to
battery and the charger came back by itself within 60 s (a cut-out under load or a bad cable/plug, not an unplug).
If "local_triggers" is present, this run was started by those local rules: address them first.
Be short and concrete. The FIRST line must be exactly "STATUS: OK" or "STATUS: ALERT".
Then: a 1-2 line summary, then a bullet list of problems (what, how many, how much memory, why it looks stuck), then what to close or do.
If everything is fine, say so briefly. Answer in English unless the machine notes below ask for another language.`;

// Optional, local only (never committed): known history of this machine and the answer language.
let machineNotes = "";
try { machineNotes = readFileSync(join(here, "machine-notes.txt"), "utf8").trim(); } catch { /* no notes */ }
const INSTRUCTIONS = machineNotes ? `${BASE_INSTRUCTIONS}\n\nMachine notes from the owner:\n${machineNotes}` : BASE_INSTRUCTIONS;

async function pickModel() {
  if (process.env.RAMWATCH_MODEL) return process.env.RAMWATCH_MODEL;
  try { const m = readFileSync(join(here, "model.txt"), "utf8").trim(); if (m) return m; } catch { /* no model.txt: auto-pick */ }
  const models = await chatgpt.listModels();
  if (!models.length) throw new Error("No models available for this ChatGPT account.");
  return (models.find((m) => /mini/i.test(m.slug)) ?? models[0]).slug;
}

const [cmd, a1, a2] = process.argv.slice(2);
try {
  if (cmd === "login") {
    console.log("Opening the browser for Sign in with ChatGPT...");
    const s = await chatgpt.signIn({ label: "RAM Watch" });
    console.log(`status=${s.status} sharing=${s.sharing} account=${s.identity?.email ?? ""}`);
    if (!s.sharing) console.log("Signed in, but plan usage (token sharing) is not enabled. Enable it in ChatGPT settings and run login again.");
    else console.log(`models: ${(await chatgpt.listModels()).map((m) => m.slug).join(", ")}`);
  } else if (cmd === "status") {
    const s = await chatgpt.getSession();
    console.log(`status=${s.status} sharing=${s.sharing} account=${s.identity?.email ?? ""}${s.error ? " error=" + s.error.code : ""}`);
  } else if (cmd === "models") {
    const models = await chatgpt.listModels();
    for (const m of models) console.log(`${m.slug}\t${m.displayName}`);
    console.log(`selected: ${await pickModel()}`);
  } else if (cmd === "review") {
    if (!a1 || !a2) throw new Error("usage: review <snapshot.json> <out.md>");
    const s = await chatgpt.getSession();
    if (s.status !== "connected" || !s.sharing) throw new Error(`Not connected to ChatGPT (status=${s.status}, sharing=${s.sharing}). Run: node ram-watch.mjs login`);
    const model = await pickModel();
    const effort = process.env.RAMWATCH_REASONING || "high";
    const { text } = await chatgpt.streamResponse({ model, reasoningEffort: effort, instructions: INSTRUCTIONS, input: "Snapshot:\n" + readFileSync(a1, "utf8") });
    writeFileSync(a2, text, "utf8");
    console.log(`model=${model}/${effort}`);
  } else {
    console.log("usage: node ram-watch.mjs login | status | models | review <snapshot.json> <out.md>");
    process.exitCode = 2;
  }
} catch (e) {
  console.error(`ERROR ${e.code ?? ""}: ${e.message}`);
  process.exitCode = 1;
}
