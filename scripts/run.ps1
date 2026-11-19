param(
  [Parameter(Mandatory = $true)][string]$Msg,
  [string]$Repo   = (Split-Path -Parent $PSScriptRoot),
  [string]$Remote = "",
  [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"

$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) {
  Write-Host "git not found" -ForegroundColor Red
  exit 1
}
$git = $gitCmd.Source

Set-Location $Repo

if (-not $Remote) {
  $origin = (& $git config --get remote.origin.url)
  if ($origin) {
    $Remote = ($origin -replace '\.git$', '') -replace '^https?://github\.com/', '' -replace '^git@github\.com:', ''
  }
}

Write-Host "== git status ==" -ForegroundColor Cyan
& $git status --short

$dirty = (& $git status --porcelain)
if ($dirty) {
  Write-Host "== add + commit ==" -ForegroundColor Cyan
  & $git add -A
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & $git commit -m $Msg
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host "== push ==" -ForegroundColor Cyan
& $git push origin $Branch
$pushExit = $LASTEXITCODE
if ($pushExit -ne 0) {
  exit $pushExit
}

Write-Host "== head commit ==" -ForegroundColor Cyan
& $git log -1 --oneline

Write-Host "== dispatch workflow ==" -ForegroundColor Cyan
$ghOk = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)
if ($ghOk -and $Remote) {
  gh workflow run build.yml -R $Remote --ref $Branch
  Start-Sleep -Seconds 5
  gh run list -R $Remote --limit 3
}

Write-Host "== done ==" -ForegroundColor Green
