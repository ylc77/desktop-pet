[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [switch]$ReportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. ([System.IO.Path]::Combine($PSScriptRoot, 'common.ps1'))

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = $script:UpdaterRepositoryRoot }
$root = Resolve-UpdaterPath -Path $RepositoryRoot -BaseDirectory ((Get-Location).ProviderPath)
if (-not [System.IO.Directory]::Exists([System.IO.Path]::Combine($root, '.git'))) { throw 'RepositoryRoot is not a Git worktree.' }

$candidates = @{}
function Add-ScanCandidate([string]$Path, [string]$Scope) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $absolute = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $Path)) }
    if (-not [System.IO.File]::Exists($absolute)) { return }
    $key = $absolute.ToLowerInvariant()
    if (-not $candidates.ContainsKey($key)) { $candidates[$key] = [pscustomobject]@{ Path=$absolute; Scopes=@($Scope) } }
    elseif (-not ($candidates[$key].Scopes -contains $Scope)) { $candidates[$key].Scopes += $Scope }
}

$savedErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $tracked = @(& git -C $root -c core.quotepath=false ls-files 2>$null)
    $trackedExitCode = $LASTEXITCODE
    $staged = @(& git -C $root -c core.quotepath=false diff --cached --name-only --diff-filter=ACMR 2>$null)
    $stagedExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $savedErrorActionPreference
}
if ($trackedExitCode -ne 0) { throw 'git ls-files failed.' }
foreach ($path in $tracked) { Add-ScanCandidate -Path ([string]$path) -Scope 'tracked' }
if ($stagedExitCode -ne 0) { throw 'git staged-file discovery failed.' }
foreach ($path in $staged) { Add-ScanCandidate -Path ([string]$path) -Scope 'staged' }

foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'release' -or $_.Name -like 'qa-results*' })) {
    foreach ($file in @(Get-ChildItem -LiteralPath $directory.FullName -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        Add-ScanCandidate -Path $file.FullName -Scope $directory.Name
    }
}
foreach ($log in @(Get-ChildItem -LiteralPath $root -File -Recurse -Filter '*.log' -Force -ErrorAction SilentlyContinue | Where-Object {
    $_.FullName -notmatch '[\\/](?:node_modules|target|\.git)[\\/]'
})) { Add-ScanCandidate -Path $log.FullName -Scope 'log' }
foreach ($keyPattern in @('*.key', '*.pem', '*.p12', '*.pfx')) {
    foreach ($keyFile in @(Get-ChildItem -LiteralPath $root -File -Recurse -Filter $keyPattern -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.FullName -notmatch '[\\/](?:node_modules|target|\.git)[\\/]'
    })) { Add-ScanCandidate -Path $keyFile.FullName -Scope 'private-key-file' }
}

$findings = @()
$rootPrefix = $root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
foreach ($candidate in $candidates.Values) {
    $relative = if ($candidate.Path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { $candidate.Path.Substring($rootPrefix.Length) } else { ConvertTo-UpdaterRedactedPath $candidate.Path }
    $candidateExtension = [System.IO.Path]::GetExtension($candidate.Path).ToLowerInvariant()
    if ($candidateExtension -in @('.key', '.pem', '.p12', '.pfx')) {
        $findings += [pscustomobject]@{ Scope=($candidate.Scopes -join ','); File=$relative; Line=0; Category='private-key-file' }
    }
    foreach ($finding in @(Find-UpdaterSecretIndicators -LiteralPath $candidate.Path)) {
        $findings += [pscustomobject]@{ Scope=($candidate.Scopes -join ','); File=$relative; Line=$finding.Line; Category=$finding.Category }
    }
}
$findings = @($findings | Sort-Object File, Line, Category -Unique)
if ($findings.Count -eq 0) {
    Write-Host "Updater secret scan PASS ($($candidates.Count) files checked)."
} else {
    $findings | Format-Table -AutoSize
    Write-Warning "Updater secret scan found $($findings.Count) indicator(s). Secret values were intentionally not printed."
}
[pscustomobject]@{ Passed=($findings.Count -eq 0); FilesChecked=$candidates.Count; FindingCount=$findings.Count; Findings=$findings }
if ($findings.Count -gt 0 -and -not $ReportOnly) { exit 1 }
