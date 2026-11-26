<div align="center">

# 🎮 Respawn

**AD unlocks and password resets from the help desk without the clicking around.**

[![Respawn](https://img.shields.io/badge/Respawn-v1.8-ff2a3c)](https://github.com/elegantgame/respawn)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)](https://learn.microsoft.com/en-us/powershell/)
[![Platform](https://img.shields.io/badge/Platform-Windows-0078D6)](https://github.com/elegantgame/respawn)
[![Mode](https://img.shields.io/badge/Mode-Dry--Run%20by%20Default-ffd166)](https://github.com/elegantgame/respawn)
[![License](https://img.shields.io/badge/License-MIT-3ddc84)](LICENSE)

*Look a user up by EID, and Respawn figures out the fix, grabs a fresh passphrase, and logs everything in under a minute.*

</div>

---

## What it does

| | |
| --- | --- |
| 🔍 **Lookup** | Finds the user by EID in Active Directory (your AD domain) |
| 🤖 **Auto-detect** | Locked account → Unlock AD, not locked → Reset AD (Enter to accept, or type 1 / 2 / 3 to override) |
| 🔑 **Auto-fetch** | Pulls a passphrase from your passphrase generator and picks one at random — no more copy-pasting |
| ⏳ **Expire** | Resets expire the password, so the user creates their own at next login |
| 📋 **Audit log** | Every run lands in `ADTool-Log.csv` (who, when, EID, user, action, result) — the passphrase is never logged |
| 🛡️ **Dry run** | Nothing changes in AD unless you run it with `-Live` |

## Demo

```
PS C:\Users\1071650\Desktop> .\Respawn.ps1 -EID 1000001

===== DRY RUN MODE - nothing will change in AD =====
Add -Live to actually unlock / reset.
Respawn v1.8

Looking up EID 1000001 in domain YOUR-DOMAIN ...
Found 1 matching account.

----- AD Info -----
User:               Doe, Jane (1000001)
UPN:                1000001@your-domain.example
Account:            Enabled
Locked out:         YES
Password last set:  11/11/2026
-------------------

Detected: this account is LOCKED - the fix is Unlock AD.

DRY RUN - here is what WOULD happen:
  - Unlock the account
[DRY RUN] Would run: Unlock-ADAccount 1000001

Done. Log written to: C:\Users\1071650\Desktop\ADTool-Log.csv
```

## Safety rules (hard-coded)

1. **Caller verification is manual, every time.** The script asks you to confirm it and will not continue until you type `YES`. It never verifies a caller for you.
2. **Disabled accounts are a hard stop.** The script halts immediately, changes nothing, and logs the stop. Handle those by hand.
3. **The temp passphrase is never written to a log or a file.** It is shown once on screen so you can read it to the user, then cleared from memory.
4. **Dry run is the default.** Add `-Live` to actually change AD.

## Files

| File | What it is |
| --- | --- |
| `Respawn.ps1` | The tool (v1.8) |
| `Respawn.bat` | Double-click launcher — dry run |
| `Respawn-LIVE.bat` | Double-click launcher — live run |
| `Test-ServiceNowAPI.ps1` | Read-only test: can your login reach the ServiceNow API? (parked) |
| `TEST-GUIDE.md` | How to test it |
| `LICENSE` | MIT License |

## Quick start

Requirements: run inside the VDI (same place the AD Tool runs), ActiveDirectory PowerShell module (RSAT) installed, and AD rights to unlock accounts / reset passwords in your AD domain.

**First-time setup:** open `Respawn.ps1` and fill in the CONFIG block at the top with your AD domain and your passphrase generator URL. The script refuses to run on the placeholders.

**Easiest way — double-click a launcher on the Desktop:**

- `Respawn.bat` → dry run (safe, read-only)
- `Respawn-LIVE.bat` → live run (actually changes AD)

**Or from PowerShell (Desktop folder):**

```powershell
cd $env:USERPROFILE\Desktop
.\Respawn.ps1            # dry run - prompts you for the EID
.\Respawn.ps1 -Live      # live run - prompts you for the EID
.\Respawn.ps1 -EID 1000001 -Live
```

Flow: enter the EID → check the AD Info it shows you → type `YES` to confirm you verified the caller → press Enter to accept the detected fix (or type 1 / 2 / 3) → type `YES` again to confirm → done. On a reset, the passphrase is shown once on screen — read it to the user verbally.

If the script will not run, check the execution policy:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

If a group policy blocks that, ask your lead — do not work around it.

## Version history

- **v1.8** — Company names and environment values removed. Domain and generator URL now live in a CONFIG block at the top (placeholders) — the script stops and tells you if they aren't filled in.
- **v1.7** — Error messages now tell permissions apart from password policy ("Access is denied" = your account lacks reset/unlock rights for that user).
- **v1.6** — Auto-detects Unlock vs Reset from the account's locked state. Renamed to Respawn.
- **v1.5** — The generator returns 5 passphrases; the script splits them and picks one at random.
- **v1.4** — Fetch tries twice (plain submit, then with `__EVENTTARGET` naming the Generate button) and prints debug info.
- **v1.3** — Fetch sends the full form + debug output on failure.
- **v1.2** — Auto-fetch passphrase from the generator (ASP.NET form POST, reads `lblPassphrase`), paste as fallback.
- **v1.1** — Fixed lookup handling: an empty record can no longer be mistaken for a disabled account.
- **v1.0** — First build: EID lookup, verification gate, disabled hard stop, dry-run mode, CSV logging.

## Parked ideas

- **ServiceNow link-up** — pull the EID from the ticket and write the work note back. Parked: the API test needs a ServiceNow username/password login, which isn't workable right now.
- **Batch mode** — ruled out: too many different callers per shift for a list to help.
- **Clipboard EID** — skipped: privacy concern (the clipboard can hold sensitive stuff).
- **GUI** — mockup shown in chat; working build in progress (screenshot to be added later).

## Notes

- Built for a help-desk AD environment. Fill in the CONFIG section at the top of Respawn.ps1 with your own AD domain and passphrase generator URL before first use — the script refuses to run on placeholders.
- Keep this repo **private** — it documents internal tooling.
