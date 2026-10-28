# Desinstalle le reset matinal de Claude Code (Windows).
#   irm https://raw.githubusercontent.com/T0MMMMM/claude-reset-setup/main/uninstall.ps1 | iex
# Fichier volontairement en ASCII, comme install.ps1.
$InstallDir = Join-Path $env:USERPROFILE '.claude-morning-reset'

foreach ($task in 'ClaudeMorningReset', 'ClaudeMorningReset-Check') {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
}
Write-Host '[ok] Taches planifiees supprimees.' -ForegroundColor Green

if ((Test-Path $InstallDir) -and ((Read-Host "Supprimer $InstallDir (script, config et logs) ? (o/n) [o]") -notmatch '^n')) {
    Remove-Item $InstallDir -Recurse -Force
    Write-Host '[ok] Dossier supprime.' -ForegroundColor Green
}
Write-Host '[ok] Desinstallation terminee.' -ForegroundColor Green
