<#
.SYNOPSIS
    AD Unlock / Password Reset helper for the help desk
    DRY RUN BY DEFAULT. Nothing changes in AD unless you run it with -Live.

    Version 1.1 (Nov 25, 2026) - fixed lookup result handling: the lookup is
    forced into a real list, and an empty record can no longer be mistaken
    for a disabled account.
    Version 1.2 (Nov 25, 2026) - the script now fetches the passphrase from
    the generator itself (form POST, reads lblPassphrase), with paste as a
    fallback if the fetch fails.
    Version 1.3 (Nov 25, 2026) - fetch sends the full form (incl. empty
    __EVENTTARGET/__EVENTARGUMENT/__LASTFOCUS + Referer) and prints debug
    lines when the fetch fails, so we can see why.
    Version 1.4 (Nov 25, 2026) - fetch tries twice (plain submit, then with
    __EVENTTARGET naming the Generate button) and prints the raw span
    content + reply length, so we can see what the server actually sent.
    Version 1.5 (Nov 25, 2026) - the generator returns several passphrases
    separated by <br />; the script now splits them and picks one at random.
    Version 1.6 (Nov 26, 2026) - auto-detects the action from the account
    state: locked -> Unlock AD, not locked -> Reset AD. Press Enter to go
    with the detected fix, or type 1 / 2 / 3 to override.
    Version 1.7 (Nov 26, 2026) - error messages now tell permissions apart
    from password policy: "Access is denied" means your account lacks Reset
    Password / Unlock rights for that user, not a bad passphrase.
    Version 1.8 (Nov 26, 2026) - company names and environment values
    removed: the AD domain and passphrase generator URL now live in a CONFIG
    block at the top (placeholders). The script stops and tells you if they
    are not filled in.

.DESCRIPTION
    Replicates the AD Tool buttons (AD Info / Unlock AD / Reset AD / Expire PW)
    for users in your AD domain, from inside the VDI.

    SAFETY RULES - hard-coded, do not remove:
      1. Caller verification is MANUAL and happens before anything changes.
         The script asks you to confirm it and will not continue until you
         type YES. The lookup itself helps: check the name it shows you
         matches the person on the phone.
      2. DISABLED accounts are a HARD STOP. The script halts immediately,
         changes nothing, logs the stop, and you handle it by hand.
      3. The temp passphrase is NEVER written to the log or a file. The script
         fetches it from the passphrase generator
         and shows it to you once so you can read it to the user; if the fetch
         fails it asks you to paste one instead. It lives only in memory.
      4. DRY RUN is the default. Add -Live to actually change AD.

.NOTES
    Requirements:
      - Run inside the VDI (same place the AD Tool runs).
      - ActiveDirectory PowerShell module (RSAT) installed in the VDI.
      - Your account needs AD rights to unlock accounts / reset passwords
        in your AD domain.
      - If the script will not run, check the execution policy:
            Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
        If a group policy blocks that, ask your lead - do not work around it.

    Usage:
      Dry run (safe - read-only lookup, prints what it WOULD do):
          .\Respawn.ps1
          .\Respawn.ps1 -EID 1000001

      Live run (actually unlocks / resets - only after dry-run testing
      and your lead's OK):
          .\Respawn.ps1 -EID 1000001 -Live

    Log: ADTool-Log.csv is written next to the script. It records WHO ran it,
    WHEN, for WHICH EID/user, WHAT action, and the result. It never records
    the passphrase.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "The user's EID (the same number you type in the AD Tool).")]
    [string]$EID,

    [Parameter(Mandatory = $false)]
    [string]$Domain = "",

    [Parameter(Mandatory = $false, HelpMessage = "Without -Live the script only looks the user up and prints what it WOULD do. Nothing changes.")]
    [switch]$Live
)

# ================= CONFIG - FILL IN FOR YOUR ENVIRONMENT =================
# The only environment-specific values in this script. Set them to your own
# AD domain and passphrase generator URL before first use. Nothing here
# names a company on purpose - this copy is the clean template.
$ConfigDomain = "YOUR-DOMAIN"                            # e.g. the NetBIOS name your AD Tool uses
$ConfigGeneratorUrl = "https://your-passphrase-generator.example/"
# ==========================================================================

# Use the -Domain parameter if given, otherwise the CONFIG value.
if ([string]::IsNullOrWhiteSpace($Domain)) { $Domain = $ConfigDomain }

# Refuse to run on placeholders - silently looking up the wrong domain
# would be worse than stopping here.
if ($Domain -eq "YOUR-DOMAIN" -or $ConfigGeneratorUrl -match "your-passphrase-generator") {
    Write-Host "CONFIG NOT SET: edit the CONFIG section at the top of this script first." -ForegroundColor Red
    Write-Host "Fill in your AD domain and your passphrase generator URL, then run it again."
    exit 1
}

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = (Get-Location).Path }
$LogFile = Join-Path $ScriptRoot "ADTool-Log.csv"

function Write-ActionLog {
    param(
        [string]$EID,
        [string]$SamAccountName,
        [string]$DisplayName,
        [string]$Action,
        [string]$Result,
        [bool]$DryRun
    )
    $row = [pscustomobject]@{
        Timestamp      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Operator       = $env:USERNAME
        Computer       = $env:COMPUTERNAME
        EID            = $EID
        SamAccountName = $SamAccountName
        DisplayName    = $DisplayName
        Action         = $Action
        Result         = $Result
        DryRun         = $(if ($DryRun) { "Yes" } else { "No" })
    }
    if (-not (Test-Path $LogFile)) {
        $row | Export-Csv -Path $LogFile -NoTypeInformation
    }
    else {
        $row | Export-Csv -Path $LogFile -NoTypeInformation -Append
    }
}

function Get-GeneratedPassphrase {
    param(
        [string]$GeneratorUrl,
        [string]$WordCount = "3"
    )
    if ([string]::IsNullOrWhiteSpace($GeneratorUrl)) { return $null }
    try {
        # The generator is an ASP.NET form: a plain GET returns an empty
        # passphrase box, and clicking Generate POSTs the form back.
        # Step 1: GET the page to grab the hidden fields + session cookie.
        $get = Invoke-WebRequest -Uri $GeneratorUrl -SessionVariable genSession -UseBasicParsing -ErrorAction Stop
        $html = $get.Content

        $viewState = ([regex]::Match($html, 'name="__VIEWSTATE"[^>]*value="([^"]*)"')).Groups[1].Value
        $viewStateGen = ([regex]::Match($html, 'name="__VIEWSTATEGENERATOR"[^>]*value="([^"]*)"')).Groups[1].Value
        $eventValidation = ([regex]::Match($html, 'name="__EVENTVALIDATION"[^>]*value="([^"]*)"')).Groups[1].Value

        if ([string]::IsNullOrWhiteSpace($viewState) -or [string]::IsNullOrWhiteSpace($eventValidation)) {
            Write-Host "  [fetch debug] GET worked but the form fields were not found in the page." -ForegroundColor Yellow
            return $null
        }

        # Step 2: POST the whole form exactly like clicking Generate.
        # Two attempts: plain submit, then with __EVENTTARGET naming the
        # Generate button (some ASP.NET pages only fire the click that way).
        $baseBody = @{
            __EVENTARGUMENT      = ""
            __LASTFOCUS          = ""
            __VIEWSTATE          = $viewState
            __VIEWSTATEGENERATOR = $viewStateGen
            __EVENTVALIDATION    = $eventValidation
            ddlWordCount         = $WordCount
            btnGenerate          = "Generate"
        }
        $attempts = @(
            @{ __EVENTTARGET = "" },
            @{ __EVENTTARGET = "btnGenerate" }
        )
        foreach ($attempt in $attempts) {
            $body = $baseBody.Clone()
            $body["__EVENTTARGET"] = $attempt["__EVENTTARGET"]
            $post = Invoke-WebRequest -Uri $GeneratorUrl -WebSession $genSession -Method Post -Body $body `
                -Headers @{ Referer = $GeneratorUrl } -UseBasicParsing -ErrorAction Stop
            Write-Host "  [fetch debug] POST status: $($post.StatusCode), reply length: $($post.Content.Length) chars" -ForegroundColor Yellow

            # Step 3: read the passphrase out of the result page.
            # The generator returns several passphrases separated by <br />.
            # Split them, clean them up, and pick one at random.
            $span = [regex]::Match($post.Content, '<span id="lblPassphrase"[^>]*>(.*?)</span>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            if ($span.Success) {
                $raw = $span.Groups[1].Value
                $choices = @($raw -split '<br\s*/?>' | ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Trim()) } | Where-Object { $_ -ne "" })
                Write-Host "  [fetch debug] $($choices.Count) passphrase(s) returned, picking one." -ForegroundColor Yellow
                if ($choices.Count -gt 0) { return ($choices | Get-Random) }
            }
            else {
                Write-Host "  [fetch debug] lblPassphrase span not found in the reply at all." -ForegroundColor Yellow
            }
        }
        Write-Host "  [fetch debug] POST worked but no passphrase was in the reply." -ForegroundColor Yellow
        return $null
    }
    catch {
        Write-Host "  [fetch debug] Fetch error: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

# ---------- Mode banner ----------
$DryRun = -not $Live.IsPresent
Write-Host ""
if ($DryRun) {
    Write-Host "===== DRY RUN MODE - nothing will change in AD =====" -ForegroundColor Yellow
    Write-Host "Add -Live to actually unlock / reset." -ForegroundColor Yellow
}
else {
    Write-Host "===== LIVE MODE - this WILL change AD =====" -ForegroundColor Red
}
Write-Host "Respawn v1.8"
Write-Host ""

# ---------- Module check ----------
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Host "ERROR: The ActiveDirectory PowerShell module was not found on this machine." -ForegroundColor Red
    Write-Host "This script has to run in the VDI where RSAT / the AD module is installed."
    Write-Host "If it is missing, ask your lead about getting RSAT installed on the VDI."
    exit 1
}
Import-Module ActiveDirectory -ErrorAction Stop

# ---------- Step 1: get the EID (the only thing you type) ----------
if ([string]::IsNullOrWhiteSpace($EID)) {
    $EID = Read-Host "Enter the user's EID (same number you type in the AD Tool)"
}
$EID = $EID.Trim()
if ($EID -notmatch '^\d+$') {
    Write-Host "That does not look like an EID - numbers only, e.g. 1000001. Stopping." -ForegroundColor Red
    exit 1
}

# ---------- Step 2: AD Info lookup (read-only) ----------
Write-Host "Looking up EID $EID in domain $Domain ..."
try {
    # @(...) forces a real list so .Count and [0] always behave the same,
    # whether AD returns zero, one, or several matches.
    $users = @(Get-ADUser -Filter "employeeID -eq '$EID'" -Server $Domain `
        -Properties DisplayName, Enabled, LockedOut, PasswordLastSet, SamAccountName, UserPrincipalName `
        -ErrorAction Stop)
}
catch {
    Write-Host "ERROR talking to AD: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "If it says it cannot find the server, the Domain value may need the full"
    Write-Host "DNS name instead of the short NetBIOS name - check with your lead what the AD Tool uses."
    exit 1
}

if ($users.Count -eq 0) {
    Write-Host "No user found with EID $EID in $Domain. Check the number and try again." -ForegroundColor Red
    Write-ActionLog -EID $EID -SamAccountName "" -DisplayName "" -Action "Lookup" -Result "Not found" -DryRun $DryRun
    exit 1
}
if ($users.Count -gt 1) {
    Write-Host "More than one user has EID $EID - stopping so nothing hits the wrong account." -ForegroundColor Red
    exit 1
}
$user = $users[0]

# Guard: never mistake a bad lookup for a disabled account. If the record
# came back without a username, stop here with a clear error instead of
# falling through to the disabled check below.
if ($null -eq $user -or [string]::IsNullOrWhiteSpace($user.SamAccountName)) {
    Write-Host "ERROR: The lookup did not return a usable account record for EID $EID." -ForegroundColor Red
    Write-Host "Stopping. Nothing was changed."
    Write-ActionLog -EID $EID -SamAccountName "" -DisplayName "" -Action "Lookup" -Result "FAILED - empty record returned" -DryRun $DryRun
    exit 1
}
Write-Host "Found 1 matching account."

Write-Host ""
Write-Host "----- AD Info -----"
Write-Host "User:               $($user.DisplayName) ($($user.SamAccountName))"
Write-Host "UPN:                $($user.UserPrincipalName)"
Write-Host "Account:            $(if ($user.Enabled) { 'Enabled' } else { 'DISABLED' })"
Write-Host "Locked out:         $(if ($user.LockedOut) { 'YES' } else { 'No' })"
Write-Host "Password last set:  $($user.PasswordLastSet)"
Write-Host "-------------------"
Write-Host ""

# ---------- HARD STOP: disabled account ----------
if (-not $user.Enabled) {
    Write-Host "STOP - this account is DISABLED." -ForegroundColor Red
    Write-Host "The script changes nothing. Handle this one by hand, per the process."
    Write-ActionLog -EID $EID -SamAccountName $user.SamAccountName -DisplayName $user.DisplayName `
        -Action "Lookup" -Result "STOPPED - account disabled" -DryRun $DryRun
    exit 1
}

# ---------- Verification gate (MANUAL - the script never does this for you) ----------
Write-Host "Caller verification is MANUAL and must be done before any reset or unlock."
Write-Host "Check the name above matches the person you verified."
$verified = Read-Host "Have you verified this caller's identity? (type YES to continue)"
if ($verified -ne "YES") {
    Write-Host "Verification not confirmed - stopping. Nothing was changed."
    Write-ActionLog -EID $EID -SamAccountName $user.SamAccountName -DisplayName $user.DisplayName `
        -Action "Verification gate" -Result "STOPPED - not verified" -DryRun $DryRun
    exit 1
}

# ---------- Auto-detect the action from the account state ----------
# Locked out  -> the fix is Unlock AD.
# Not locked  -> the fix is Reset AD (forgotten/expired password).
# Press Enter to go with the detected fix, or type 1 / 2 / 3 to override.
Write-Host ""
if ($user.LockedOut) {
    Write-Host "Detected: this account is LOCKED - the fix is Unlock AD." -ForegroundColor Cyan
    $detected = "1"
    $detectedText = "Unlock AD"
}
else {
    Write-Host "Detected: this account is NOT locked - the fix is Reset AD password." -ForegroundColor Cyan
    $detected = "2"
    $detectedText = "Reset AD password"
}
Write-Host "  [1] Unlock AD"
Write-Host "  [2] Reset AD password"
Write-Host "  [3] Both - unlock AND reset password"
$choice = Read-Host "Press Enter for $detectedText, or type 1, 2 or 3 (Q to quit)"
if ([string]::IsNullOrWhiteSpace($choice)) { $choice = $detected }
switch ($choice) {
    "1" { $doUnlock = $true;  $doReset = $false }
    "2" { $doUnlock = $false; $doReset = $true }
    "3" { $doUnlock = $true;  $doReset = $true }
    default {
        Write-Host "Quitting - nothing was changed."
        exit 0
    }
}

# ---------- Get the passphrase (only if resetting) ----------
# Auto-fetch from the generator, with paste as a fallback.
$newPassword = $null
if ($doReset) {
    Write-Host ""
    Write-Host "Fetching a passphrase from the generator ..."
    $plainPhrase = Get-GeneratedPassphrase -GeneratorUrl $ConfigGeneratorUrl
    if ([string]::IsNullOrWhiteSpace($plainPhrase)) {
        Write-Host "Could not fetch one automatically - paste it instead." -ForegroundColor Yellow
        Write-Host "Get a passphrase from the generator and paste it below."
        $securePw = Read-Host "Paste the new passphrase" -AsSecureString
        if ($securePw.Length -eq 0) {
            Write-Host "No passphrase entered - stopping."
            exit 1
        }
        $newPassword = $securePw
    }
    else {
        Write-Host "Passphrase fetched from the generator."
        Write-Host "Temp passphrase (read this to the user - it is NOT logged): $plainPhrase" -ForegroundColor Cyan
        $newPassword = ConvertTo-SecureString $plainPhrase -AsPlainText -Force
        $plainPhrase = $null
    }
}

# ---------- Show the plan and confirm ----------
Write-Host ""
if ($DryRun) {
    Write-Host "DRY RUN - here is what WOULD happen:" -ForegroundColor Yellow
}
else {
    Write-Host "About to do this for $($user.DisplayName) ($($user.SamAccountName)):" -ForegroundColor Yellow
}
if ($doUnlock) {
    if ($user.LockedOut) { Write-Host "  - Unlock the account" }
    else                 { Write-Host "  - Unlock: account is NOT locked, so nothing to unlock" }
}
if ($doReset) {
    Write-Host "  - Reset the password (passphrase from the generator)"
    Write-Host "  - Expire the password so they must change it at next login"
}
$confirm = Read-Host "Type YES to continue"
if ($confirm -ne "YES") {
    Write-Host "Cancelled - nothing was changed."
    exit 0
}

# ---------- Do it (or print what would happen) ----------
if ($doUnlock) {
    if ($user.LockedOut) {
        if ($DryRun) {
            Write-Host "[DRY RUN] Would run: Unlock-ADAccount $($user.SamAccountName)" -ForegroundColor Yellow
            Write-ActionLog -EID $EID -SamAccountName $user.SamAccountName -DisplayName $user.DisplayName `
                -Action "Unlock AD" -Result "DRY RUN - would unlock" -DryRun $DryRun
        }
        else {
            try {
                Unlock-ADAccount -Identity $user -Server $Domain -ErrorAction Stop
                Write-Host "Account unlocked." -ForegroundColor Green
                Write-ActionLog -EID $EID -SamAccountName $user.SamAccountName -DisplayName $user.DisplayName `
                    -Action "Unlock AD" -Result "Success" -DryRun $DryRun
            }
            catch {
                $errMsg = $_.Exception.Message
                Write-Host "ERROR unlocking: $errMsg" -ForegroundColor Red
                if ($errMsg -match "Access is denied") {
                    Write-Host "This is a PERMISSIONS problem. Your account does not have Unlock rights for this user."
                    Write-Host "Try the unlock in the AD Tool. If it fails there too, ask your lead / IT about unlock rights for this user or OU."
                }
                Write-ActionLog -EID $EID -SamAccountName $user.SamAccountName -DisplayName $user.DisplayName `
                    -Action "Unlock AD" -Result "FAILED - $errMsg" -DryRun $DryRun
            }
        }
    }
    else {
        Write-Host "Account was not locked - no unlock needed."
    }
}

if ($doReset) {
    if ($DryRun) {
        Write-Host "[DRY RUN] Would run: Set-ADAccountPassword + expire (force change at next login)" -ForegroundColor Yellow
        Write-ActionLog -EID $EID -SamAccountName $user.SamAccountName -DisplayName $user.DisplayName `
            -Action "Reset AD" -Result "DRY RUN - would reset + expire" -DryRun $DryRun
    }
    else {
        try {
            Set-ADAccountPassword -Identity $user -Server $Domain -Reset -NewPassword $newPassword -ErrorAction Stop
            Set-ADUser -Identity $user -Server $Domain -ChangePasswordAtLogon $true -ErrorAction Stop
            Write-Host "Password reset. It is set to expire - the user must create their own new password at next login." -ForegroundColor Green
            Write-Host "Tell them the passphrase verbally - it was shown once above and was not logged."
            Write-ActionLog -EID $EID -SamAccountName $user.SamAccountName -DisplayName $user.DisplayName `
                -Action "Reset AD" -Result "Success" -DryRun $DryRun
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Host "ERROR resetting password: $errMsg" -ForegroundColor Red
            if ($errMsg -match "Access is denied") {
                Write-Host "This is a PERMISSIONS problem, not the passphrase. Your account does not have Reset Password rights for this user."
                Write-Host "Try the reset in the AD Tool. If it fails there too, ask your lead / IT about reset rights for this user or OU."
            }
            elseif ($errMsg -match "password.*policy|complexity|does not meet") {
                Write-Host "The passphrase may not meet the domain rules - generate a new one and try again."
            }
            Write-ActionLog -EID $EID -SamAccountName $user.SamAccountName -DisplayName $user.DisplayName `
                -Action "Reset AD" -Result "FAILED - $errMsg" -DryRun $DryRun
        }
    }
}

# Clear the passphrase from memory
$newPassword = $null

Write-Host ""
Write-Host "Done. Log written to: $LogFile"
if ($DryRun) {
    Write-Host "Remember: this was a DRY RUN. Nothing changed in AD." -ForegroundColor Yellow
}
