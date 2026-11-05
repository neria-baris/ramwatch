# RamWatch

A small Windows watchdog for the things Task Manager doesn't tell you: background processes that were
"closed" but still hold memory, slow memory leaks (user-mode and kernel pool), and power / GPU / Bluetooth /
battery trouble. Local rules run every 15 minutes; when something looks wrong, a ChatGPT model reviews the
full snapshot and an always-on-top window pops up (it shows even in Do Not Disturb).

It uses **Sign in with ChatGPT** (your ChatGPT Plus/Pro plan), not an API key.

## What it does

| When | Script | What |
|---|---|---|
| every 15 min | `ram-monitor.ps1` | ~10 s local check, no model call. Writes one compact line to `metrics\<date>.jsonl` and escalates when a rule fires (cooldown per rule). |
| 10:00 and 20:00, or on escalation | `ram-watch.ps1` | Full snapshot → ChatGPT review → report in `reports\`, popup on `STATUS: ALERT`. |
| 09:45 daily | `daily.ps1` | Battery report, driver changes, Reliability Monitor, pending reboot/updates, disks, event-log reach. |
| hourly (inside the monitor) | `github-sync.ps1` | Optional: pushes data to a **private** GitHub repo through the API (no local clone) and prunes local copies. |

Rules that escalate (`ram-monitor.ps1`, thresholds at the top of the file):

- available RAM < 3 GB, commit charge ≥ 85 %, C: free < 15 GB
- non-paged pool ≥ 1.5 GB, ≥ 10 processes that exited but are stuck in the kernel
- ≥ 10 headless browser processes in one family (leaked automation)
- a single process holding ≥ 4 GB private memory for over 24 h
- unexpected shutdowns, BSODs, GPU driver resets, WHEA errors, Bluetooth driver errors
- the discrete GPU or Bluetooth device changing state, thermal throttling / ≥ 90 °C

What gets sent to the model: process names, counts, memory, ages, flag **names** of command lines (values
stripped, token-like strings redacted), script file names, kernel pool tags, device states, and event-log
summaries. No file contents.

## Safety by design

- Nothing stays resident: each run is a short-lived process (~140 MB peak, ~10 s), tasks never overlap,
  every slow query (WMI, battery, Windows Update) runs time-boxed in a child process, and a watchdog kills
  any RamWatch process older than 20 minutes.
- It only reads and reports. It never closes processes or changes settings on its own.

## Install

Requirements: Windows 10/11, PowerShell 5.1, Node.js 22+, git, a ChatGPT plan with app usage sharing
enabled (chatgpt.com/settings/usage). Optional: GitHub CLI (`gh auth login`) for the data backup.

```powershell
git clone https://github.com/neria-baris/ramwatch.git $env:USERPROFILE\RamWatch
cd $env:USERPROFILE\RamWatch
powershell -ExecutionPolicy Bypass -File .\setup.ps1                                   # basic
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -GitHubRepo <you>/ramwatch-data   # + private backup
```

Don't install it under `AppData`: apps packaged as MSIX (e.g. some desktop AI apps) see a virtualized copy of
that folder, and the scheduled tasks would not find the files.

`setup.ps1` downloads and builds OpenAI's
[Sign-in-with-ChatGPT DevKit](https://github.com/openai/sign-in-with-chatgpt-devkit) (noncommercial license,
not bundled here), enables a `reasoning` option in it (marked as a local change), registers the scheduled
tasks and opens the ChatGPT sign-in.

Optional, as Administrator (`setup-admin.ps1`): larger System/Application event logs, a daily SSD-health
task (SMART-style counters), switching a stray Surface battery INF back to Windows' own driver on non-Surface
PCs, and applying your `startup-config.json`.

## Configuration (all local, git-ignored)

| File | Purpose |
|---|---|
| `model.txt` | model slug, e.g. `gpt-6-luna` (default: first model with "mini", else the first listed). `RAMWATCH_REASONING` env var sets the effort (default `high`). |
| `machine-notes.txt` | known history of your PC and the answer language; appended to the model instructions. See `machine-notes.example.txt`. |
| `startup-config.json` | apps/services for `disable-startup.ps1`. See `startup-config.example.json`. |
| `github-repo.txt` | `owner/name` of the private data repo (written by `setup.ps1 -GitHubRepo`). |

## Power guard (charger ↔ battery crashes)

`power-guard.ps1 -Install` (Administrator) targets laptops that crash when they fall from the charger to the battery
under load. Nothing can react within the milliseconds of a real power loss, so it works around that:

1. **Remove the trigger** – battery uses the same device power policy as the charger in every power plan (PCIe Link
   State Power Management off, Wi-Fi adapter at maximum performance, USB selective suspend off). A charger cut-out no
   longer makes the GPU / Wi-Fi / Bluetooth drivers switch power states at that very moment.
2. **Lower load peaks** – maximum processor state 99 % (Turbo Boost off) so the charger is less likely to be overloaded.
   `-UncapTurbo` / `-CapTurbo` toggle only this layer.
3. **Black box** – a task started by the power-source event itself (no resident process) records CPU/GPU load, top
   processes and device state at every switch, and pops up when the charger came back within 60 s (a cut-out, not an
   unplug). A 1-second circular performance log (Windows' own logging service) runs alongside; after an unexpected
   shutdown the minutes before it are exported to `power-events\crash-*.csv`.

`-Status` shows what is applied; `-Uninstall` restores the original values from `power-guard-backup.json`.

## Extra tools

- `fix-wlanext.ps1` – when `wlanext.exe` keeps growing (Wi-Fi vendor extension leak): `-Status`,
  `-DisableIhv` / `-RestoreIhv` (stop loading the vendor extension, reversible), or `-InstallGuard`
  (hourly SYSTEM task that restarts WlanSvc above a limit).
- `disable-startup.ps1 -WhatIf` – preview the auto-start changes before applying them.

## Handy commands

```powershell
node .\ram-watch.mjs status            # ChatGPT connection
node .\ram-watch.mjs models            # models your plan can use
powershell -File .\ram-watch.ps1 -NoNotify     # run a review now, no popup
Disable-ScheduledTask RamWatchMonitor          # pause the 15-minute checks
powershell -File .\setup.ps1 -Uninstall        # remove the scheduled tasks
```

## License

MIT for this repository. The DevKit that `setup.ps1` downloads is under OpenAI's own noncommercial license.
