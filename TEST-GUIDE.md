# AD Unlock / Password Reset — Test Guide (Dry Run)

## What this is

`Respawn.ps1` automates the two AD Tool buttons — **Unlock AD** and
**Reset AD** — for users in your AD domain. It runs in the VDI,
where the AD Tool already runs.

**It does NOT automate:** caller verification (manual, every time), the
ServiceNow ticket, the passphrase generator, or telling the user their
password. Those stay with you.

**Hard rules baked into the script:**
- Disabled account = full stop, nothing changes, you handle it by hand.
- No verification confirmation = no reset, no unlock.
- The passphrase is never shown on screen and never written to the log.
- Dry run is the default. It only changes AD when you add `-Live`.

## Step 0 — Configure it for your environment (first use only)

Open `Respawn.ps1` and fill in the CONFIG block at the top with your AD
domain and your passphrase generator URL. The script refuses to run on the
placeholders — it will stop and tell you to fill them in first.

## Step 1 — Get the file into the VDI

The VDI is a separate machine, so the file has to get there first. Easiest ways:
- Open this file on your phone, copy the contents, paste into Notepad in the
  VDI, save as `Respawn.ps1`.
- Or email the file to your work email and open it in the VDI.

**Before you run anything on a work machine, show it to your lead** and get
his OK. A 30-second check that keeps you in the clear — this changes user
accounts in your directory.

## Step 2 — Check the VDI is ready

In PowerShell in the VDI, run:

```powershell
Get-Module -ListAvailable -Name ActiveDirectory
$PSVersionTable.PSVersion
Get-ExecutionPolicy
```

- If the ActiveDirectory module is missing, RSAT isn't installed — ask your
  lead about getting it installed on the VDI. The script will refuse to run
  without it.
- If the execution policy blocks scripts, try:
  `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`
  If a group policy blocks that, don't work around it — ask your lead.

## Step 3 — Dry run tests (nothing changes)

Run it with no `-Live` flag:

```powershell
.\Respawn.ps1
```

It will ask for the EID, look the user up, and print what it WOULD do.

**Test these cases:**
1. **A normal user** — it should show their AD Info (name, enabled, locked
   status, password last set), ask for verification, then show the plan.
2. **A locked user** (if you have a safe one to check) — it should say it
   would unlock.
3. **A disabled user** — it must STOP immediately with the red message and
   change nothing. This is the most important test.
4. **A wrong EID** — it should say "No user found" and stop.
5. **Say NO at the verification prompt** — it must stop without doing
   anything.

After each run, open `ADTool-Log.csv` (created next to the script) and check
it recorded the run — and that the passphrase is nowhere in it.

## Step 4 — Go live (only after dry runs look right + your lead's OK)

On a real ticket, after you've verified the caller:

```powershell
.\Respawn.ps1 -EID 1000001 -Live
```

Flow: EID in → AD Info shows → confirm verification → pick unlock / reset /
both → paste the passphrase from your generator → type
YES → done. Then tell the user the passphrase verbally like always, and they
create their own new password at next login (the script expires it, same as
the "Expire AD Password?" checkbox).

## Troubleshooting

- **"ActiveDirectory module was not found"** — RSAT isn't installed on that
  machine. Run it in the VDI, or ask your lead about RSAT.
- **"Cannot find the server" / AD connection error** — the `-Domain`
  value may need the full DNS domain name instead of the short name. Check
  what the AD Tool's domain dropdown uses, or ask your lead.
- **"No user found"** — double-check the EID. The script searches the
  employeeID field in AD.
- **Password reset fails with a policy error** — the passphrase doesn't meet
  the domain's password rules. Generate a fresh one and try again.
- **"More than one user has this EID"** — the script stops on purpose so
  nothing hits the wrong account. Flag it to your lead.
