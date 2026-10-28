# Installe le reset matinal de Claude Code sur Windows.
# Sur macOS ou Linux, utilise install.sh.
#
# En une commande (defauts : 07:30, du lundi au vendredi, avec reveil) :
#   irm https://raw.githubusercontent.com/T0MMMMM/claude-reset-setup/main/install.ps1 | iex
# Avec des options :
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/T0MMMMM/claude-reset-setup/main/install.ps1))) -Time 08:00 -Days daily
# Depuis le depot :
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# Fichier volontairement en ASCII : il doit se lire correctement via irm | iex
# comme depuis un fichier, quel que soit l'encodage.
param(
    [string]$Time,
    [string]$Days,
    [switch]$NoWake,
    [string]$Message = 'Bonjour, reponds juste OK.',
    [int]$WarnDays = 7,
    [string]$Accounts,
    [switch]$Interactive,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RawUrl = if ($env:CMR_RAW_URL) { $env:CMR_RAW_URL } else { 'https://raw.githubusercontent.com/T0MMMMM/claude-reset-setup/main' }
# Via irm | iex il n'y a pas de depot local : on telecharge ce qu'il faut et on ne pose pas de questions.
$Standalone = -not $PSScriptRoot -or -not (Test-Path (Join-Path $PSScriptRoot 'bin\claude-reset.ps1'))
$RepoDir = if ($Standalone) { (Get-Location).Path } else { $PSScriptRoot }
$Ask = $Interactive -or -not $Standalone
$InstallDir = Join-Path $env:USERPROFILE '.claude-morning-reset'
$TaskRun = 'ClaudeMorningReset'
$TaskCheck = 'ClaudeMorningReset-Check'

function Info($t) { Write-Host "> $t" -ForegroundColor Cyan }
function Ok($t) { Write-Host "[ok] $t" -ForegroundColor Green }
function Warn($t) { Write-Host "[!] $t" -ForegroundColor Yellow }
# throw plutot que exit : exit fermerait la fenetre PowerShell lancee via iex.
function Die($t) { Write-Host "[x] $t" -ForegroundColor Red; throw $t }

function Read-Answer([string]$Prompt, [string]$Default) {
    if (-not $Ask) { return $Default }
    $a = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a
}

# ---------- Systeme ----------

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Die 'Sur macOS ou Linux, utilise install.sh.'
}
Info 'Systeme detecte : windows'

$claude = Get-Command claude -ErrorAction SilentlyContinue
$ClaudeBin = if ($claude) { $claude.Source } else { Join-Path $env:USERPROFILE '.local\bin\claude.exe' }
if (-not (Test-Path $ClaudeBin)) { Die "Commande claude introuvable. Installe Claude Code d'abord : https://claude.com/claude-code" }
Info "Claude Code : $ClaudeBin"

# ---------- Reglages ----------

if (-not $Time) { $Time = Read-Answer 'Heure du reset (HH:MM)' '07:30' }
if ($Time -notmatch '^([01]?\d|2[0-3]):([0-5]\d)$') { Die "Heure invalide : $Time" }
$Hour = [int]$Matches[1]; $Minute = [int]$Matches[2]
$Time = '{0:D2}:{1:D2}' -f $Hour, $Minute

if (-not $Days) {
    if ($Ask) { Write-Host 'Recurrence : 1) du lundi au vendredi  2) tous les jours  3) week-end  4) jours au choix' }
    switch (Read-Answer 'Choix' '1') {
        '1' { $Days = 'weekdays' }
        '2' { $Days = 'daily' }
        '3' { $Days = 'weekend' }
        '4' { $Days = Read-Answer 'Jours separes par des virgules (ex. lun,mer,ven)' 'lun,mar,mer,jeu,ven' }
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
    $Wake = (Read-Answer 'Sortir le PC de veille automatiquement pour le reset ? (o/n)' 'o') -match '^(o|y)'
}

# Comptes : on garde ceux deja configures, sauf si -Accounts ou une reponse les remplace.
$AccountsFile = Join-Path $InstallDir 'accounts.conf'
$Existing = if (Test-Path $AccountsFile) { (Get-Content $AccountsFile | Where-Object { $_ -match '\|' -and $_ -notmatch '^#' } | ForEach-Object { $_.Split('|')[0] }) -join ',' } else { '' }
if (-not $Accounts) {
    $Accounts = Read-Answer 'Comptes Claude a resetter, separes par des virgules (principal = ton compte actuel)' $(if ($Existing) { $Existing } else { 'principal' })
}
$AccountList = @($Accounts.Replace(' ', '').Split(',') | Where-Object { $_ })
foreach ($n in $AccountList) { if ($n -notmatch '^[a-zA-Z0-9_-]+$') { Die "Nom de compte invalide : $n (lettres, chiffres, - et _)" } }

if (-not $Ask) {
    Info "Reglages : reset a $Time ($DaysLabel), reveil $(if ($Wake) { 'active' } else { 'desactive' }), comptes : $($AccountList -join ',')."
    Info 'Pour les changer, voir les options dans le README (-Time, -Days, -NoWake, -Accounts, -Interactive).'
}

if ($DryRun) {
    $Preview = Join-Path $RepoDir '.dry-run'
    Remove-Item $Preview -Recurse -Force -ErrorAction SilentlyContinue
    $InstallDir = Join-Path $Preview 'install'
    Warn "Mode dry-run : fichiers generes dans $Preview, rien n'est installe."
}

# ---------- Fichiers ----------

New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'logs'), (Join-Path $InstallDir 'state') | Out-Null
$Runner = Join-Path $InstallDir 'claude-reset.ps1'
if ($Standalone) {
    # Telechargement en octets pour garder l'encodage d'origine (UTF-8 avec BOM).
    $bytes = (Invoke-WebRequest "$RawUrl/bin/claude-reset.ps1" -UseBasicParsing).Content
    if ($bytes -is [string]) {
        $bytes = [Text.Encoding]::UTF8.GetPreamble() + [Text.Encoding]::UTF8.GetBytes($bytes.TrimStart([char]0xFEFF))
    }
    [IO.File]::WriteAllBytes($Runner, $bytes)
}
else {
    Copy-Item (Join-Path $RepoDir 'bin\claude-reset.ps1') $Runner -Force
}
[ordered]@{
    ClaudeBin      = $ClaudeBin
    Message        = $Message
    Time           = $Time
    DaysLabel      = $DaysLabel
    WarnDays       = $WarnDays
    AlertRepeatMin = 120
    CheckExpiry    = $true
} | ConvertTo-Json | Set-Content (Join-Path $InstallDir 'config.json') -Encoding UTF8
Ok "Script installe dans $InstallDir"

# "principal" = config par defaut (~\.claude) ; les autres ont leur propre dossier.
$AccountsRoot = if ($DryRun) { Join-Path $Preview 'claude-accounts' } else { Join-Path $env:USERPROFILE '.claude-accounts' }
$lines = @('# Comptes resettes : nom|dossier de config (vide = ~\.claude). Gerer avec : claude-reset account')
foreach ($n in $AccountList) {
    if ($n -eq 'principal') { $lines += 'principal|' }
    else {
        $d = Join-Path $AccountsRoot $n
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $lines += "$n|$d"
    }
}
$lines | Set-Content (Join-Path $InstallDir 'accounts.conf') -Encoding UTF8
Ok "Comptes : $($AccountList -join ',')"

# Commande claude-reset, a cote de claude (deja dans le PATH).
$LinkDir = if ($DryRun) { Join-Path $Preview 'bin' } else { Join-Path $env:USERPROFILE '.local\bin' }
New-Item -ItemType Directory -Force -Path $LinkDir | Out-Null
"@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'claude-reset.ps1')`" %*" |
    Set-Content (Join-Path $LinkDir 'claude-reset.cmd') -Encoding ASCII
Ok 'Commande installee : claude-reset'

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
# A l'ouverture de session et au deverrouillage = quand on "ouvre l'ordi".
$CheckTriggers = @"
<LogonTrigger><Enabled>true</Enabled><UserId>$User</UserId></LogonTrigger>
    <SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>SessionUnlock</StateChange><UserId>$User</UserId></SessionStateChangeTrigger>
"@

$RunXml = Get-TaskXml $RunTriggers 'reset' $Wake
$CheckXml = Get-TaskXml $CheckTriggers 'check' $false

if ($DryRun) {
    $RunXml | Set-Content (Join-Path $Preview "$TaskRun.xml")
    $CheckXml | Set-Content (Join-Path $Preview "$TaskCheck.xml")
    Ok "Taches ecrites dans $Preview (non enregistrees)."
    return
}

Register-ScheduledTask -TaskName $TaskRun -Xml $RunXml -Force | Out-Null
Register-ScheduledTask -TaskName $TaskCheck -Xml $CheckXml -Force | Out-Null
Ok "Reset programme a $Time ($DaysLabel), verification a l'ouverture de session et au deverrouillage."

if ($Wake) {
    Warn 'Pour que le PC sorte de veille, les "minuteurs de reveil" doivent etre autorises :'
    Warn '  Panneau de configuration > Options d''alimentation > Modifier les parametres du mode'
    Warn '  > Parametres avances > Veille > Autoriser les minuteurs de reveil = Active.'
    Warn 'Certains portables (veille moderne) ignorent ces minuteurs.'
}

Write-Host ''
Ok 'Installation terminee.'
Write-Host '   Etat        : claude-reset status'
Write-Host '   Tester      : claude-reset reset'
Write-Host '   Comptes     : claude-reset account list | add NOM | remove NOM'
Write-Host '   Connexion   : claude-reset login NOM'
Write-Host "   Logs        : $InstallDir\logs\claude-reset.log"
if ($Standalone) {
    Write-Host "   Desinstaller: irm $RawUrl/uninstall.ps1 | iex"
}
else {
    Write-Host "   Desinstaller: $RepoDir\uninstall.ps1"
}
Write-Host ''
& $Runner status
# Propose de connecter les comptes qui ne le sont pas encore.
foreach ($n in $AccountList) {
    $d = if ($n -eq 'principal') { '' } else { Join-Path $AccountsRoot $n }
    if ($d) { $env:CLAUDE_CONFIG_DIR = $d } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
    $logged = (& $ClaudeBin auth status 2>$null | Out-String) -match '"loggedIn":\s*true'
    Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    if ($logged) { continue }
    if ($Ask -and (Read-Answer "Le compte '$n' n'est pas connecte. Le connecter maintenant ? (o/n)" 'o') -match '^(o|y)') {
        & $Runner login $n
    }
    else { Warn "Pense a connecter '$n' : claude-reset login $n" }
}
if ((Read-Answer 'Envoyer le message a Claude maintenant pour tester ? (o/n)' 'n') -match '^(o|y)') {
    & $Runner reset
    & $Runner status
}
