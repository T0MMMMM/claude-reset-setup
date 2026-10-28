# Envoie le message de reset à Claude Code pour chaque compte et alerte si une session a expiré (Windows).
# Usage :
#   claude-reset reset | check | status
#   claude-reset login [NOM]
#   claude-reset account list | add NOM | remove NOM
param([string]$Mode = 'check', [string]$Arg1 = '', [string]$Arg2 = '')

$ErrorActionPreference = 'Continue'
$Dir = $PSScriptRoot
$Config = Get-Content (Join-Path $Dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$StateDir = Join-Path $Dir 'state'
$LogFile = Join-Path $Dir 'logs\claude-reset.log'
$AccountsFile = Join-Path $Dir 'accounts.conf'
$AccountsDir = if ($env:CMR_ACCOUNTS_DIR) { $env:CMR_ACCOUNTS_DIR } else { Join-Path $env:USERPROFILE '.claude-accounts' }
$AuthPattern = 'authenticat|oauth|not logged in|please log ?in|/login|invalid api key'

New-Item -ItemType Directory -Force -Path $StateDir, (Split-Path $LogFile) | Out-Null
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Move-Item $LogFile "$LogFile.1" -Force }

function Write-Log([string]$Text) {
    Add-Content -Path $LogFile -Encoding UTF8 -Value ("{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Mode, $Text)
}

# ---------- Comptes ----------
# accounts.conf : une ligne « nom|dossier de config » ; dossier vide = config par défaut (~\.claude).

function Get-Accounts {
    $lines = if (Test-Path $AccountsFile) { Get-Content $AccountsFile -Encoding UTF8 | Where-Object { $_ -match '\|' -and $_ -notmatch '^#' } } else { @('principal|') }
    foreach ($l in $lines) { $p = $l.Split('|', 2); [pscustomobject]@{ Name = $p[0]; Dir = $p[1] } }
}

function Get-Account([string]$Name) { Get-Accounts | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }

function Set-ClaudeEnv([string]$ConfigDir) {
    if ($ConfigDir) { $env:CLAUDE_CONFIG_DIR = $ConfigDir } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
}

function Invoke-ClaudeAs([string]$ConfigDir, [string[]]$ClaudeArgs) {
    Set-ClaudeEnv $ConfigDir
    try { return (& $Config.ClaudeBin @ClaudeArgs 2>&1 | Out-String) }
    finally { Set-ClaudeEnv '' }
}

function Get-LoginHint([string]$Name) { "Lance : claude-reset login $Name" }

# ---------- État et alertes (par compte) ----------

function Save-Result([string]$Name, [string]$Status, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Join-Path $StateDir $Name) | Out-Null
    Set-Content -Path (Join-Path $StateDir "$Name\last_result") -Encoding UTF8 -Value ("{0}|{1}|{2}" -f $Status, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)
}

function Get-LastResult([string]$Name) {
    $f = Join-Path $StateDir "$Name\last_result"
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim().Split('|') }
    return $null
}

# Une alerte donnée ne se répète pas plus d'une fois toutes les N minutes (0 = toujours).
function Test-ShouldAlert([string]$Name, [string]$Key, [int]$EveryMin) {
    New-Item -ItemType Directory -Force -Path (Join-Path $StateDir $Name) | Out-Null
    $f = Join-Path $StateDir "$Name\alert_$Key"
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $last = if (Test-Path $f) { [int64](Get-Content $f -Raw) } else { 0 }
    if (($now - $last) -lt ($EveryMin * 60)) { return $false }
    Set-Content -Path $f -Value $now
    return $true
}

function Show-Alert([string]$Name, [string]$Key, [int]$EveryMin, [string]$Level, [string]$Title, [string]$Text) {
    if (-not (Test-ShouldAlert $Name $Key $EveryMin)) { return }
    $Title = "$Title ($Name)"
    Write-Log "ALERTE ($Name/$Key) : $Text"
    if ($env:CMR_DRY_ALERT -eq '1') { Write-Host "[alerte $Level] $Title - $Text"; return }
    $icon = if ($Level -eq 'critical') { 16 } else { 48 }
    # 4 = boutons Oui/Non ; 6 = Oui. La fenêtre reste ouverte jusqu'au clic.
    $answer = (New-Object -ComObject WScript.Shell).Popup("$Text`n`nSe reconnecter maintenant ?", 0, $Title, 4 + $icon)
    if ($answer -eq 6) {
        Start-Process powershell.exe -ArgumentList '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", 'login', $Name
    }
}

# 0 = connecté, 1 = déconnecté, 2 = inconnu
function Get-LoginState([string]$ConfigDir) {
    $out = Invoke-ClaudeAs $ConfigDir @('auth', 'status')
    if ($out -match '"loggedIn":\s*true') { return 0 }
    if ($out -match '"loggedIn":\s*false') { return 1 }
    return 2
}

# Date de fin du jeton de renouvellement. Champ interne à Claude Code :
# s'il disparaît ou change de nom, la vérification est simplement ignorée.
function Get-RefreshExpiry([string]$ConfigDir) {
    if (-not $Config.CheckExpiry) { return $null }
    $base = if ($ConfigDir) { $ConfigDir } else { Join-Path $env:USERPROFILE '.claude' }
    $file = Join-Path $base '.credentials.json'
    if (-not (Test-Path $file)) { return $null }
    $m = [regex]::Match((Get-Content $file -Raw), '"refreshTokenExpiresAt"\s*:\s*(\d+)')
    if (-not $m.Success -or [int64]$m.Groups[1].Value -le 0) { return $null }
    return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$m.Groups[1].Value).LocalDateTime
}

function Test-Expiry($Account) {
    $exp = Get-RefreshExpiry $Account.Dir
    if ($null -eq $exp) { return }
    $date = $exp.ToString('dd/MM/yyyy HH:mm')
    $days = [math]::Floor(($exp - (Get-Date)).TotalDays)
    $hint = Get-LoginHint $Account.Name
    if ($exp -le (Get-Date)) {
        Show-Alert $Account.Name 'refresh_expired' 1440 'critical' 'Connexion Claude expirée' "La connexion ne peut plus se renouveler depuis le $date. $hint"
    }
    elseif ($days -lt $Config.WarnDays) {
        Show-Alert $Account.Name 'refresh_soon' 1440 'warning' 'Connexion Claude bientôt expirée' "La connexion expire le $date (dans $days j). Reconnecte-toi avant. $hint"
    }
}

function Wait-Network {
    for ($i = 0; $i -lt 24; $i++) {
        try { [System.Net.Dns]::GetHostAddresses('api.anthropic.com') | Out-Null; return $true } catch { Start-Sleep 5 }
    }
    return $false
}

# ---------- Commandes ----------

function Invoke-ResetAccount($Account) {
    $name = $Account.Name
    Write-Log "[$name] Envoi du message à Claude…"
    $last = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Push-Location $env:USERPROFILE
        $out = Invoke-ClaudeAs $Account.Dir @('-p', $Config.Message)
        $code = $LASTEXITCODE
        Pop-Location
        $last = ($out.Trim() -split "`n")[-1].Trim()

        if ($code -eq 0 -and $out -notmatch 'failed to authenticate') {
            Write-Log "[$name] OK : $last"
            Save-Result $name 'ok' $last
            Test-Expiry $Account
            return $true
        }
        if ($out -match $AuthPattern) {
            Write-Log "[$name] Session expirée : $last"
            Save-Result $name 'auth_expired' $last
            Show-Alert $name 'auth_expired' 0 'critical' 'Session Claude expirée' "Le reset de $(Get-Date -Format 'HH:mm') a échoué : ce compte n'est plus connecté. $(Get-LoginHint $name)"
            return $false
        }
        Write-Log "[$name] Échec (tentative $attempt/3, code $code) : $last"
        if ($attempt -lt 3) { Start-Sleep 60 }
    }
    Save-Result $name 'error' $last
    Show-Alert $name 'run_error' 0 'warning' 'Reset Claude échoué' "Le reset de $(Get-Date -Format 'HH:mm') a échoué (voir $LogFile)."
    return $false
}

function Invoke-CheckAccount($Account) {
    $name = $Account.Name
    $state = Get-LoginState $Account.Dir
    if ($state -eq 1) {
        Show-Alert $name 'not_logged_in' $Config.AlertRepeatMin 'critical' 'Session Claude expirée' "Ce compte n'est plus connecté : le prochain reset va échouer. $(Get-LoginHint $name)"
        return
    }
    $last = Get-LastResult $name
    if ($last) {
        switch ($last[0]) {
            # Claude Code se marque déconnecté après un échec : connecté maintenant = reconnecté.
            'auth_expired' { if ($state -eq 0) { Save-Result $name 'relogged' 'Reconnecté après échec' } }
            'error' { Show-Alert $name 'run_error_check' 1440 'warning' 'Reset Claude échoué' "Le dernier reset a échoué (voir $LogFile)." }
        }
    }
    Test-Expiry $Account
}

function Invoke-Reset {
    # Empêche la mise en veille pendant l'envoi.
    Add-Type -Namespace Cmr -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
    [Cmr.Power]::SetThreadExecutionState([uint32]'0x80000001') | Out-Null
    if (-not (Wait-Network)) { Write-Log 'Réseau indisponible après 2 min, on tente quand même.' }
    foreach ($a in Get-Accounts) { Invoke-ResetAccount $a | Out-Null }
}

function Show-Status {
    Write-Host "Heure du reset : $($Config.Time) (jours : $($Config.DaysLabel))"
    Write-Host "Log            : $LogFile"
    Write-Host ''
    $rows = foreach ($a in Get-Accounts) {
        $exp = Get-RefreshExpiry $a.Dir
        $last = Get-LastResult $a.Name
        [pscustomobject]@{
            Compte         = $a.Name
            Connecte       = @{ 0 = 'oui'; 1 = 'NON'; 2 = '?' }[(Get-LoginState $a.Dir)]
            'Expire le'    = if ($exp) { $exp.ToString('dd/MM/yyyy HH:mm') } else { '-' }
            'Dernier reset' = if ($last) { "$($last[0]) le $($last[1])" } else { 'jamais' }
        }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host
}

function Invoke-Login([string]$Name) {
    if (-not $Name) { $Name = 'principal' }
    $a = Get-Account $Name
    if (-not $a) { Write-Host "Compte inconnu : $Name (voir : claude-reset account list)"; return }
    Write-Host "Connexion du compte « $Name »…"
    Set-ClaudeEnv $a.Dir
    try { & $Config.ClaudeBin auth login } finally { Set-ClaudeEnv '' }
    if ((Get-LoginState $a.Dir) -eq 0) {
        Save-Result $Name 'relogged' 'Reconnecté'
        Write-Host "[ok] Compte « $Name » connecté." -ForegroundColor Green
    }
}

function Invoke-Account([string]$Action, [string]$Name) {
    switch ($Action) {
        'add' {
            if ($Name -notmatch '^[a-zA-Z0-9_-]+$') { Write-Host 'Nom invalide : utilise lettres, chiffres, - et _ (ex. perso).'; return }
            if (Get-Account $Name) { Write-Host "Le compte « $Name » existe déjà."; return }
            $d = Join-Path $AccountsDir $Name
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            if (-not (Test-Path $AccountsFile)) { Set-Content $AccountsFile -Encoding UTF8 -Value 'principal|' }
            Add-Content $AccountsFile -Encoding UTF8 -Value "$Name|$d"
            Write-Host "[ok] Compte « $Name » ajouté (config : $d)." -ForegroundColor Green
            Write-Host "  Pour l'utiliser au quotidien : `$env:CLAUDE_CONFIG_DIR = '$d'; claude"
            Invoke-Login $Name
        }
        'remove' {
            if (-not (Get-Account $Name)) { Write-Host "Compte inconnu : $Name"; return }
            $rest = @(Get-Accounts | Where-Object { $_.Name -ne $Name })
            if ($rest.Count -eq 0) { Write-Host 'Impossible de retirer le dernier compte.'; return }
            Set-Content $AccountsFile -Encoding UTF8 -Value ($rest | ForEach-Object { "$($_.Name)|$($_.Dir)" })
            Remove-Item (Join-Path $StateDir $Name) -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "[ok] Compte « $Name » retiré du reset." -ForegroundColor Green
        }
        default {
            Get-Accounts | ForEach-Object { '{0,-14} {1}' -f $_.Name, $(if ($_.Dir) { $_.Dir } else { '~\.claude (config par défaut)' }) } | Write-Host
        }
    }
}

switch ($Mode) {
    'reset' { Invoke-Reset }
    'check' { foreach ($a in Get-Accounts) { Invoke-CheckAccount $a } }
    'status' { Show-Status }
    'login' { Invoke-Login $Arg1 }
    'account' { Invoke-Account $Arg1 $Arg2 }
    default { Write-Host 'Usage : claude-reset reset | check | status | login [NOM] | account list|add|remove' }
}
