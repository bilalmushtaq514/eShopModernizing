<#
.SYNOPSIS
  Deploys (or rolls back) the legacy site on ONE IIS server. Called by the
  Azure Pipelines agent running on that server (rolling strategy, 1 at a time).

.DESCRIPTION
  Release layout (created by the platform bootstrap):
      C:\inetpub\eshop\releases\<BuildId>\     one immutable folder per release
  The IIS site's physicalPath points at exactly one release. Deploying =
  unpack new release -> stop pool+site -> repoint -> start -> health check.

  -Action Deploy   : unpack PackageZip as release <ReleaseId>, switch to it.
  -Action Rollback : switch to an existing release folder (default: the one
                     that was live before the current one). No artifact needed.

  If the post-switch health check fails, the server is switched back to the
  release that was live before, and the script exits 1 -> the pipeline stops
  before touching the next server (B-4, B-5, B-7).
#>
[CmdletBinding()]
param(
  [ValidateSet('Deploy', 'Rollback')] [string]$Action = 'Deploy',
  [string]$PackageZip,
  [string]$ReleaseId,
  [string]$RollbackTo = 'previous',
  [string]$ExpectedBuild,
  [string]$SiteName = 'eShopLegacy',
  [string]$AppPoolName = 'eShopLegacy',
  [string]$SiteRoot = 'C:\inetpub\eshop',
  [int]$KeepReleases = 5,
  [string]$HealthUrl = 'http://localhost/health'
)

$ErrorActionPreference = 'Stop'
Import-Module WebAdministration
$releases = Join-Path $SiteRoot 'releases'
$stateFile = Join-Path $SiteRoot 'release-history.txt'   # one line per switch: newest last

function Log($m) { Write-Host ("[{0:HH:mm:ss}] [{1}] {2}" -f (Get-Date), $env:COMPUTERNAME, $m) }

function Get-LivePath { (Get-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath) }

function Wait-PoolState($state) {
  for ($i = 0; $i -lt 30; $i++) {
    if ((Get-WebAppPoolState -Name $AppPoolName).Value -eq $state) { return }
    Start-Sleep -Seconds 1
  }
  throw "App pool $AppPoolName did not reach state $state"
}

function Switch-Release([string]$target) {
  Log "Stopping site + app pool"
  Stop-Website -Name $SiteName
  if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped') { Stop-WebAppPool -Name $AppPoolName }
  Wait-PoolState 'Stopped'

  Log "physicalPath -> $target"
  Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -Value $target
  Add-Content -Path $stateFile -Value $target

  Log "Starting app pool + site"
  Start-WebAppPool -Name $AppPoolName
  Wait-PoolState 'Started'
  Start-Website -Name $SiteName
}

function Test-Health([string]$expected) {
  # First request after a pool start compiles views (cold start) -> generous retries.
  for ($i = 1; $i -le 12; $i++) {
    try {
      $r = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 20
      $body = $r.Content
      Log "health attempt ${i}: HTTP $($r.StatusCode) $body"
      if ($r.StatusCode -eq 200 -and (-not $expected -or $body -match [regex]::Escape("""Build"":""$expected"""))) { return $true }
    } catch {
      $code = $_.Exception.Response.StatusCode.value__
      Log "health attempt ${i}: failed (HTTP $code) $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 5
  }
  return $false
}

$previous = Get-LivePath
Log "Live release before change: $previous"
if (-not (Test-Path $stateFile)) { Set-Content -Path $stateFile -Value $previous }  # first deploy: remember bootstrap release

switch ($Action) {
  'Deploy' {
    if (-not $PackageZip -or -not (Test-Path $PackageZip)) { throw "PackageZip not found: $PackageZip" }
    $target = Join-Path $releases $ReleaseId
    if (Test-Path $target) { Remove-Item $target -Recurse -Force }   # re-run of same build = fresh copy
    Log "Unpacking $PackageZip -> $target"
    Expand-Archive -Path $PackageZip -DestinationPath $target -Force
  }
  'Rollback' {
    if ($RollbackTo -eq 'previous') {
      $history = @(Get-Content $stateFile -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -ne $previous })
      if ($history.Count -eq 0) { throw 'No previous release recorded on this server' }
      $target = $history[-1]
    } else {
      $target = Join-Path $releases $RollbackTo
    }
    if (-not (Test-Path $target)) { throw "Rollback target does not exist: $target" }
    $ExpectedBuild = $null   # the old release carries its own build stamp
  }
}

Switch-Release $target

if (Test-Health $ExpectedBuild) {
  Log "HEALTHY on $target"
} else {
  Log "UNHEALTHY - restoring previous release $previous"
  Switch-Release $previous
  if (Test-Health $null) { Log 'Previous release restored and healthy' } else { Log 'WARNING: previous release also unhealthy' }
  Write-Host "##vso[task.logissue type=error]$($env:COMPUTERNAME): new release failed health check and was rolled back on this server"
  exit 1
}

# Housekeeping: keep the newest N releases (never the live one or the bootstrap placeholder).
Get-ChildItem $releases -Directory |
  Where-Object { $_.FullName -ne $target -and $_.Name -ne '0-bootstrap' } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -Skip ($KeepReleases - 1) |
  ForEach-Object { Log "Pruning old release $($_.Name)"; Remove-Item $_.FullName -Recurse -Force }
