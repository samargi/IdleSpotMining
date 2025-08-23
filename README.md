# Idle Spot Mining — NHQM (NiceHash QuickMiner) controller

“Just for fun” project that pauses/resumes mining based on **spot price** (Finland: `spot-hinta.fi`)
while letting **NiceHash QuickMiner (NHQM)** keep control of algorithms, profitability and UI.

- **OS:** Windows 11 (tested)
- **NHQM:** v0.6.12.0 stable (tested)
- **Miner engine:** Excavator (controlled via NHQM **HTTP API** on localhost)

---

## What it does

- Polls `https://api.spot-hinta.fi/JustNow` every `60s`
- If price **> threshold** → sends `miner.stop` (no process killing)
- If price **≤ threshold** → sends `miner.start` (fallback to `quit` only if needed)
- Reads NHQM API settings (`watchDogAPIHost/Port/Auth`) from `nhqm.conf`
- Tries both `[::1]` and `127.0.0.1` automatically when host is `localhost`
- Rotates logs to prevent infinite growth

---

## Repo layout

```text
.
├─ IdleSpotMining.ps1     # controller (PowerShell)
├─ make.bat               # helper for Task Scheduler (create/run/delete/status)
├─ .env.example           # copy to .env and set machine-specific values
└─ README.md
```

---

## Requirements

- Windows 11  
- PowerShell 5+ (inbox)  
- **NiceHash QuickMiner** installed (creates `nhqm.conf` containing HTTP API token)  
- Default path for `nhqm.conf`:  

```text
C:\NiceHash\NiceHash QuickMiner\nhqm.conf
```

> NHQM often binds the API to IPv6 loopback → `http://[::1]:18000/`

---

## Install

1. **Clone & copy**

   ```powershell
   git clone https://github.com/you/idle-spot-mining-nhqm.git
   cd idle-spot-mining-nhqm
   # Put files to C:\Scripts (or adjust paths in .env)
   Copy-Item .\IdleSpotMining.ps1,.\make.bat -Destination C:\Scripts
   ```

2. **Create `.env` from template**

   ```powershell
   Copy-Item .env.example .env
   ```

   Edit `.env` and set values:

   ```env
   RUNUSER=COMPUTERNAME\Username
   TASKNAME=IdleSpotMining
   SCRIPT=C:\Scripts\IdleSpotMining.ps1
   LOGFILE=C:\Scripts\miner-switch.log
   ```

   - `RUNUSER`: Windows account that runs the scheduled task  
   - `TASKNAME`: Name of the scheduled task  
   - Adjust paths if you placed scripts elsewhere

3. **Test script manually**

   ```powershell
   cd C:\Scripts
   .\IdleSpotMining.ps1
   ```

4. **Install scheduled task** (asks for password once)

   ```powershell
   cd C:\Scripts
   make create
   ```

---

## Usage

```powershell
make status     # show task status
make run        # run immediately
make end        # stop the running task
make delete     # remove the scheduled task
make tail       # follow log file
make who        # check Run As User / last result
```

---

## Disclaimer

- This is **just for fun / testing** ⚠️
- No guarantees of profitability, stability or safety.
- Use at your own risk.
