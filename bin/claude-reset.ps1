# Envoie le message de reset à Claude Code et alerte si la session a expiré (Windows).
# Usage : claude-reset.ps1 reset|check|status
param([ValidateSet('reset', 'check', 'status')][string]$Mode = 'check')

$ErrorActionPreference = 'Continue'
$Dir = $PSScriptRoot
$Config = Get-Content (Join-Path $Dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$StateDir = Join-Path $Dir 'state'
$LogFile = Join-Path $Dir 'logs\claude-reset.log'
$AuthPattern = 'authenticat|oauth|not logged in|please log ?in|/login|invalid api key'
$LoginHint = 'Ouvre un terminal et lance : claude auth login'

New-Item -ItemType Directory -Force -Path $StateDir, (Split-Path $LogFile) | Out-Null
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Move-Item $LogFile "$LogFile.1" -Force }

function Write-Log([string]$Text) {
    Add-Content -Path $LogFile -Encoding UTF8 -Value ("{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Mode, $Text)
}

function Save-Result([string]$Status, [string]$Text) {
    Set-Content -Path (Join-Path $StateDir 'last_result') -Encoding UTF8 -Value ("{0}|{1}|{2}" -f $Status, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)
}

function Get-LastResult {
    $f = Join-Path $StateDir 'last_result'
    if (Test-Path $f) { return (Get-Content $f -Raw).Split('|')[0] }
    return ''
}

# Une alerte donnée ne se répète pas plus d'une fois toutes les N minutes (0 = toujours).
function Test-ShouldAlert([string]$Key, [int]$EveryMin) {
    $f = Join-Path $StateDir "alert_$Key"
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $last = if (Test-Path $f) { [int64](Get-Content $f -Raw) } else { 0 }
    if (($now - $last) -lt ($EveryMin * 60)) { return $false }
    Set-Content -Path $f -Value $now
    return $true
}

function Show-Alert([string]$Key, [int]$EveryMin, [string]$Level, [string]$Title, [string]$Text) {
    if (-not (Test-ShouldAlert $Key $EveryMin)) { return }
    Write-Log "ALERTE ($Key) : $Text"
    if ($env:CMR_DRY_ALERT -eq '1') { Write-Host "[alerte $Level] $Title - $Text"; return }
    $icon = if ($Level -eq 'critical') { 16 } else { 48 }
    # 4 = boutons Oui/Non ; 6 = Oui. La fenêtre reste ouverte jusqu'au clic.
    $answer = (New-Object -ComObject WScript.Shell).Popup("$Text`n`nSe reconnecter maintenant ?", 0, $Title, 4 + $icon)
    if ($answer -eq 6) {
        Start-Process powershell.exe -ArgumentList '-NoExit', '-Command', "& '$($Config.ClaudeBin)' auth login"
    }
}

# 0 = connecté, 1 = déconnecté, 2 = inconnu
function Get-LoginState {
    $out = (& $Config.ClaudeBin auth status 2>$null | Out-String)
    if ($out -match '"loggedIn":\s*true') { return 0 }
    if ($out -match '"loggedIn":\s*false') { return 1 }
    return 2
}

# Date de fin du jeton de renouvellement. Champ interne à Claude Code :
# s'il disparaît ou change de nom, la vérification est simplement ignorée.
function Get-RefreshExpiry {
    if (-not $Config.CheckExpiry) { return $null }
    $file = Join-Path $env:USERPROFILE '.claude\.credentials.json'
    if (-not (Test-Path $file)) { return $null }
    $m = [regex]::Match((Get-Content $file -Raw), '"refreshTokenExpiresAt"\s*:\s*(\d+)')
    if (-not $m.Success -or [int64]$m.Groups[1].Value -le 0) { return $null }
    return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$m.Groups[1].Value).LocalDateTime
}

function Test-Expiry {
    $exp = Get-RefreshExpiry
    if ($null -eq $exp) { return }
    $date = $exp.ToString('dd/MM/yyyy HH:mm')
    $days = [math]::Floor(($exp - (Get-Date)).TotalDays)
    if ($exp -le (Get-Date)) {
        Show-Alert 'refresh_expired' 1440 'critical' 'Connexion Claude expirée' "Ta connexion Claude Code ne peut plus se renouveler depuis le $date. $LoginHint"
    }
    elseif ($days -lt $Config.WarnDays) {
        Show-Alert 'refresh_soon' 1440 'warning' 'Connexion Claude bientôt expirée' "Ta connexion Claude Code expire le $date (dans $days j). $LoginHint"
    }
}

function Wait-Network {
    for ($i = 0; $i -lt 24; $i++) {
        try { [System.Net.Dns]::GetHostAddresses('api.anthropic.com') | Out-Null; return $true } catch { Start-Sleep 5 }
    }
    return $false
}

function Invoke-Reset {
    # Empêche la mise en veille pendant l'envoi.
    Add-Type -Namespace Cmr -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
    [Cmr.Power]::SetThreadExecutionState([uint32]'0x80000001') | Out-Null

    Write-Log 'Envoi du message à Claude…'
    if (-not (Wait-Network)) { Write-Log 'Réseau indisponible après 2 min, on tente quand même.' }
    $last = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Push-Location $env:USERPROFILE
        $out = (& $Config.ClaudeBin -p $Config.Message 2>&1 | Out-String)
        $code = $LASTEXITCODE
        Pop-Location
        $last = ($out.Trim() -split "`n")[-1].Trim()

        if ($code -eq 0 -and $out -notmatch 'failed to authenticate') {
            Write-Log "OK : $last"
            Save-Result 'ok' $last
            Test-Expiry
            return
        }
        if ($out -match $AuthPattern) {
            Write-Log "Session expirée : $last"
            Save-Result 'auth_expired' $last
            Show-Alert 'auth_expired' 0 'critical' 'Session Claude expirée' "Le reset de $(Get-Date -Format 'HH:mm') a échoué : Claude Code n'est plus connecté. $LoginHint"
            return
        }
        Write-Log "Échec (tentative $attempt/3, code $code) : $last"
        if ($attempt -lt 3) { Start-Sleep 60 }
    }
    Save-Result 'error' $last
    Show-Alert 'run_error' 0 'warning' 'Reset Claude échoué' "Le reset de $(Get-Date -Format 'HH:mm') a échoué (voir $LogFile)."
}

function Invoke-Check {
    $state = Get-LoginState
    if ($state -eq 1) {
        Show-Alert 'not_logged_in' $Config.AlertRepeatMin 'critical' 'Session Claude expirée' "Claude Code n'est plus connecté : le prochain reset va échouer. $LoginHint"
        return
    }
    switch (Get-LastResult) {
        # Claude Code se marque déconnecté après un échec : connecté maintenant = reconnecté.
        'auth_expired' { if ($state -eq 0) { Save-Result 'relogged' 'Reconnecté après échec' } }
        'error' { Show-Alert 'run_error_check' 1440 'warning' 'Reset Claude échoué' "Le dernier reset a échoué (voir $LogFile)." }
    }
    Test-Expiry
}

function Show-Status {
    Write-Host "Heure du reset : $($Config.Time) (jours : $($Config.DaysLabel))"
    Write-Host "Claude         : $($Config.ClaudeBin)"
    $label = @{ 0 = 'connecté'; 1 = 'DÉCONNECTÉ'; 2 = 'inconnue' }[(Get-LoginState)]
    Write-Host "Connexion      : $label"
    $exp = Get-RefreshExpiry
    if ($null -ne $exp) { Write-Host "Expire le      : $($exp.ToString('dd/MM/yyyy HH:mm'))" }
    $f = Join-Path $StateDir 'last_result'
    if (Test-Path $f) {
        $parts = (Get-Content $f -Raw).Trim().Split('|')
        Write-Host "Dernier reset  : $($parts[0]) le $($parts[1]) ($($parts[2]))"
    }
    else { Write-Host 'Dernier reset  : jamais' }
    Write-Host "Log            : $LogFile"
}

switch ($Mode) {
    'reset' { Invoke-Reset }
    'check' { Invoke-Check }
    'status' { Show-Status }
}
