# Desinstalle le reset matinal de Claude Code (Windows).
#   irm https://raw.githubusercontent.com/T0MMMMM/claude-reset-setup/main/uninstall.ps1 | iex
# Fichier volontairement en ASCII, comme install.ps1.
$InstallDir = Join-Path $env:USERPROFILE '.claude-morning-reset'

foreach ($task in 'ClaudeMorningReset', 'ClaudeMorningReset-Check') {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
}
Write-Host '[ok] Taches planifiees supprimees.' -ForegroundColor Green
Remove-Item (Join-Path $env:USERPROFILE '.local\bin\claude-reset.cmd') -Force -ErrorAction SilentlyContinue
Write-Host '[ok] Commande claude-reset supprimee.' -ForegroundColor Green

if ((Test-Path $InstallDir) -and ((Read-Host "Supprimer $InstallDir (script, config et logs) ? (o/n) [o]") -notmatch '^n')) {
    Remove-Item $InstallDir -Recurse -Force
    Write-Host '[ok] Dossier supprime.' -ForegroundColor Green
}
# Les comptes supplementaires peuvent servir en dehors du reset : on ne les supprime que sur demande.
$Extra = Join-Path $env:USERPROFILE '.claude-accounts'
if ((Test-Path $Extra) -and ((Read-Host "Supprimer aussi les comptes supplementaires ($Extra) ? Il faudra les reconnecter. (o/n) [n]") -match '^(o|y)')) {
    Remove-Item $Extra -Recurse -Force
    Write-Host '[ok] Comptes supplementaires supprimes.' -ForegroundColor Green
}
Write-Host '[ok] Desinstallation terminee.' -ForegroundColor Green
