[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

foreach ($commandName in @('node', 'npm', 'rustc', 'cargo', 'rustup')) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$commandName' is not available on PATH. Install the Windows prerequisites, ensure %USERPROFILE%\.cargo\bin is on the user PATH, and open a new terminal. Run scripts\check-windows-env.ps1 for details."
    }
}

if (-not $env:CARGO_BUILD_JOBS) {
    $memory = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($memory -and ([int64]$memory.FreePhysicalMemory * 1KB) -lt 4GB) {
        $env:CARGO_BUILD_JOBS = '1'
        Write-Warning 'Less than 4 GiB physical memory is available; limiting Cargo to one build job.'
    }
}

Push-Location $repo
try {
    & npm run validate
    if ($LASTEXITCODE -ne 0) { throw "Project validation failed with exit code $LASTEXITCODE." }
    $tauri = Join-Path $repo 'node_modules\.bin\tauri.cmd'
    if (-not (Test-Path -LiteralPath $tauri)) { throw 'Tauri CLI is not installed. Run npm install first.' }
    & $tauri build --bundles nsis
    if ($LASTEXITCODE -ne 0) { throw "Tauri release build failed with exit code $LASTEXITCODE." }
    & (Join-Path $repo 'scripts\create-release-manifest.ps1')
} finally {
    Pop-Location
}
