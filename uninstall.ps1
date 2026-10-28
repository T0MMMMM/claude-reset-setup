# Désinstalle le reset matinal de Claude Code (Windows).
$InstallDir = Join-Path $env:USERPROFILE '.claude-morning-reset'

foreach ($task in 'ClaudeMorningReset', 'ClaudeMorningReset-Check') {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
}
Write-Host '✓ Tâches planifiées supprimées.' -ForegroundColor Green

if ((Test-Path $InstallDir) -and ((Read-Host "Supprimer $InstallDir (script, config et logs) ? (o/n) [o]") -notmatch '^n')) {
    Remove-Item $InstallDir -Recurse -Force
    Write-Host '✓ Dossier supprimé.' -ForegroundColor Green
}
Write-Host '✓ Désinstallation terminée.' -ForegroundColor Green
