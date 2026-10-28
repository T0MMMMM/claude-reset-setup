# Installe le reset matinal de Claude Code sur Windows.
# Sur macOS ou Linux, utilise install.sh.
#
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Time 07:30 -Days weekdays
param(
    [string]$Time,
    [string]$Days,
    [switch]$NoWake,
    [string]$Message = 'Bonjour, réponds juste OK.',
    [int]$WarnDays = 7,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RepoDir = $PSScriptRoot
$InstallDir = Join-Path $env:USERPROFILE '.claude-morning-reset'
$TaskRun = 'ClaudeMorningReset'
$TaskCheck = 'ClaudeMorningReset-Check'

function Info($t) { Write-Host "› $t" -ForegroundColor Cyan }
function Ok($t) { Write-Host "✓ $t" -ForegroundColor Green }
function Warn($t) { Write-Host "! $t" -ForegroundColor Yellow }
function Die($t) { Write-Host "✗ $t" -ForegroundColor Red; exit 1 }

function Ask([string]$Prompt, [string]$Default) {
    $a = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a
}

# ---------- Système ----------

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Die 'Sur macOS ou Linux, lance ./install.sh.'
}
Info 'Système détecté : windows'

$claude = Get-Command claude -ErrorAction SilentlyContinue
$ClaudeBin = if ($claude) { $claude.Source } else { Join-Path $env:USERPROFILE '.local\bin\claude.exe' }
if (-not (Test-Path $ClaudeBin)) { Die "Commande claude introuvable. Installe Claude Code d'abord : https://claude.com/claude-code" }
Info "Claude Code : $ClaudeBin"

# ---------- Questions ----------

if (-not $Time) { $Time = Ask 'Heure du reset (HH:MM)' '07:30' }
if ($Time -notmatch '^([01]?\d|2[0-3]):([0-5]\d)$') { Die "Heure invalide : $Time" }
$Hour = [int]$Matches[1]; $Minute = [int]$Matches[2]
$Time = '{0:D2}:{1:D2}' -f $Hour, $Minute

if (-not $Days) {
    Write-Host 'Récurrence : 1) du lundi au vendredi  2) tous les jours  3) week-end  4) jours au choix'
    switch (Ask 'Choix' '1') {
        '1' { $Days = 'weekdays' }
        '2' { $Days = 'daily' }
        '3' { $Days = 'weekend' }
        '4' { $Days = Ask 'Jours séparés par des virgules (ex. lun,mer,ven)' 'lun,mar,mer,jeu,ven' }
        default { Die 'Choix invalide.' }
    }
}

$DayNames = 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
$DayLabels = 'lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim'
function Get-DayNumber([string]$t) {
    switch -Regex ($t) {
        '^(1|lun|mon)' { return 1 } '^(2|mar|tue)' { return 2 } '^(3|mer|wed)' { return 3 }
        '^(4|jeu|thu)' { return 4 } '^(5|ven|fri)' { return 5 } '^(6|sam|sat)' { return 6 }
        '^(7|0|dim|sun)' { return 7 }
    }
    Die "Jour inconnu : $t"
}
$DayList = switch ($Days.ToLower().Replace(' ', '')) {
    { $_ -in 'daily', 'tous', 'tlj', 'quotidien', 'everyday' } { 1..7; break }
    { $_ -in 'weekdays', 'semaine', 'lun-ven', 'mon-fri' } { 1..5; break }
    { $_ -in 'weekend', 'we' } { 6, 7; break }
    default { $_.Split(',') | Where-Object { $_ } | ForEach-Object { Get-DayNumber $_ } }
}
$DayList = @($DayList | Sort-Object -Unique)
if ($DayList.Count -eq 0) { Die 'Aucun jour choisi.' }
$DaysLabel = ($DayList | ForEach-Object { $DayLabels[$_ - 1] }) -join ','

$Wake = -not $NoWake
if (-not $PSBoundParameters.ContainsKey('NoWake')) {
    $Wake = (Ask "Sortir le PC de veille automatiquement pour le reset ? (o/n)" 'o') -match '^(o|y)'
}

if ($DryRun) {
    $Preview = Join-Path $RepoDir '.dry-run'
    Remove-Item $Preview -Recurse -Force -ErrorAction SilentlyContinue
    $InstallDir = Join-Path $Preview 'install'
    Warn "Mode dry-run : fichiers générés dans $Preview, rien n'est installé."
}

# ---------- Fichiers ----------

New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'logs'), (Join-Path $InstallDir 'state') | Out-Null
Copy-Item (Join-Path $RepoDir 'bin\claude-reset.ps1') $InstallDir -Force
[ordered]@{
    ClaudeBin      = $ClaudeBin
    Message        = $Message
    Time           = $Time
    DaysLabel      = $DaysLabel
    WarnDays       = $WarnDays
    AlertRepeatMin = 120
    CheckExpiry    = $true
} | ConvertTo-Json | Set-Content (Join-Path $InstallDir 'config.json') -Encoding UTF8
Ok "Script installé dans $InstallDir"

$Runner = Join-Path $InstallDir 'claude-reset.ps1'
$User = "$env:USERDOMAIN\$env:USERNAME"
$Start = (Get-Date -Format 'yyyy-MM-dd') + "T$Time`:00"
$DaysXml = ($DayList | ForEach-Object { "<$($DayNames[$_ - 1]) />" }) -join ''
function Get-TaskArgs([string]$Mode) { "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;$Runner&quot; $Mode" }

function Get-TaskXml([string]$Triggers, [string]$Mode, [bool]$WakeToRun) {
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Claude Code - reset matinal ($Mode)</Description></RegistrationInfo>
  <Triggers>$Triggers</Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$User</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <WakeToRun>$($WakeToRun.ToString().ToLower())</WakeToRun>
    <ExecutionTimeLimit>PT12H</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$(Get-TaskArgs $Mode)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

$RunTriggers = @"
<CalendarTrigger>
      <StartBoundary>$Start</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByWeek><DaysOfWeek>$DaysXml</DaysOfWeek><WeeksInterval>1</WeeksInterval></ScheduleByWeek>
    </CalendarTrigger>
"@
# À l'ouverture de session et au déverrouillage = quand on « ouvre l'ordi ».
$CheckTriggers = @"
<LogonTrigger><Enabled>true</Enabled><UserId>$User</UserId></LogonTrigger>
    <SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>SessionUnlock</StateChange><UserId>$User</UserId></SessionStateChangeTrigger>
"@

$RunXml = Get-TaskXml $RunTriggers 'reset' $Wake
$CheckXml = Get-TaskXml $CheckTriggers 'check' $false

if ($DryRun) {
    $RunXml | Set-Content (Join-Path $Preview "$TaskRun.xml")
    $CheckXml | Set-Content (Join-Path $Preview "$TaskCheck.xml")
    Ok "Tâches écrites dans $Preview (non enregistrées)."
    exit 0
}

Register-ScheduledTask -TaskName $TaskRun -Xml $RunXml -Force | Out-Null
Register-ScheduledTask -TaskName $TaskCheck -Xml $CheckXml -Force | Out-Null
Ok "Reset programmé à $Time ($DaysLabel), vérification à l'ouverture de session et au déverrouillage."

if ($Wake) {
    Warn 'Pour que le PC sorte de veille, les « minuteurs de réveil » doivent être autorisés :'
    Warn '  Panneau de configuration > Options d''alimentation > Modifier les paramètres du mode'
    Warn '  > Paramètres avancés > Veille > Autoriser les minuteurs de réveil = Activé.'
    Warn 'Certains portables (veille moderne) ignorent ces minuteurs.'
}

Write-Host ''
Ok 'Installation terminée.'
Write-Host "   État        : powershell -File `"$Runner`" status"
Write-Host "   Tester      : powershell -File `"$Runner`" reset"
Write-Host "   Logs        : $InstallDir\logs\claude-reset.log"
Write-Host "   Désinstaller: $RepoDir\uninstall.ps1"
Write-Host ''
& $Runner status
if ((Ask "Envoyer le message à Claude maintenant pour tester ? (o/n)" 'n') -match '^(o|y)') {
    & $Runner reset
    & $Runner status
}
