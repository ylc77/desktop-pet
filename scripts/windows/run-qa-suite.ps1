[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Safe','CurrentMachine','CleanEnvironment')][string]$Mode = 'Safe',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\qa-results'),
    [switch]$SkipBuild,
    [switch]$SkipInstall,
    [switch]$SkipPerformance
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if ($WhatIfPreference) {
    Write-Host "QA suite preview: Mode=$Mode; OutputDirectory=$output; SkipBuild=$SkipBuild; SkipInstall=$SkipInstall; SkipPerformance=$SkipPerformance"
    Write-Host 'Safe checks would run first. CurrentMachine/CleanEnvironment would additionally request confirmation before install, launch, normal-exit wait, autostart inspection, uninstall, and leftover checks.'
    exit 0
}
$directories = @($output, (Join-Path $output 'screenshots'), (Join-Path $output 'performance'), (Join-Path $output 'install'), (Join-Path $output 'uninstall'))
$directories | ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
$commandLog = Join-Path $output 'command-log.txt'
$results = @()
$env:Path = [Environment]::GetEnvironmentVariable('Path','User') + ';' + [Environment]::GetEnvironmentVariable('Path','Machine')

function Add-Result([string]$Name, [string]$Category, [string]$Status, [string]$Command, [string]$Details) {
    $script:results += [pscustomobject]@{ name=$Name; category=$Category; status=$Status; command=$Command; details=$Details }
}
function Invoke-QACommand([string]$Name, [string]$Command, [string]$Category = 'automatic') {
    Add-Content -Encoding UTF8 -LiteralPath $commandLog -Value "`r`n[$([DateTime]::UtcNow.ToString('o'))] $Command"
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $text = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Set-Location -LiteralPath '$($repo.Replace("'", "''"))'; $Command" 2>&1 | Out-String).Trim()
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    Add-Content -Encoding UTF8 -LiteralPath $commandLog -Value "$text`r`nExitCode=$code"
    Add-Result $Name $Category $(if($code -eq 0){'passed'}else{'failed'}) $Command $text
    return $code -eq 0
}

$environment = [ordered]@{
    capturedAtUtc=[DateTime]::UtcNow.ToString('o'); mode=$Mode; computerName=$env:COMPUTERNAME
    os=(Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture)
    powershell=$PSVersionTable.PSVersion.ToString(); processArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    webView2=$null; testEnvironments=$null
}
$webView = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue
$environment.webView2 = @{ installed=[bool]$webView; version=$(if($webView){[string]$webView.pv}else{$null}); scenario='installed on current host; missing scenarios not modified on host' }
$environment.testEnvironments = (& (Join-Path $PSScriptRoot 'detect-test-environments.ps1') | ConvertFrom-Json)
$environment | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $output 'environment.json')

[void](Invoke-QACommand 'Windows build environment' '& .\scripts\check-windows-env.ps1')
[void](Invoke-QACommand 'TypeScript typecheck' 'npm run typecheck')
[void](Invoke-QACommand 'Frontend tests' 'npm run test')
[void](Invoke-QACommand 'Character pack validation' 'npm run validate:characters')
[void](Invoke-QACommand 'Frontend production build' 'npm run build')
[void](Invoke-QACommand 'Rust formatting' 'cargo fmt --check --manifest-path src-tauri/Cargo.toml')
[void](Invoke-QACommand 'Rust check' 'cargo check --manifest-path src-tauri/Cargo.toml -j1')
[void](Invoke-QACommand 'Rust release tests' 'cargo test --release --manifest-path src-tauri/Cargo.toml -j1')
[void](Invoke-QACommand 'Isolated character fault tests' "& .\scripts\windows\run-fault-injection-tests.ps1 -OutputPath '$((Join-Path $output 'fault-results.json').Replace("'", "''"))'")
if ($SkipBuild) { Add-Result 'NSIS release build' 'automatic' 'skipped' 'npm run build:release' 'Skipped by -SkipBuild.' }
else { [void](Invoke-QACommand 'NSIS release build' 'npm run build:release') }
[void](Invoke-QACommand 'Release manifest generation' "& .\scripts\create-release-manifest.ps1 -TestSummary @('QA Safe suite')")
[void](Invoke-QACommand 'Signature, hash and manifest verification' '& .\scripts\windows\verify-release-artifacts.ps1')
[void](Invoke-QACommand 'PowerShell syntax' '$e=@(); Get-ChildItem .\scripts -Filter *.ps1 -Recurse | ForEach-Object { try { [void][scriptblock]::Create((Get-Content -Raw -Encoding UTF8 $_.FullName)) } catch { $e += $_.Exception.Message } }; if($e.Count){$e;exit 1}else{exit 0}')
[void](Invoke-QACommand 'Git worktree clean' '$s=& git status --porcelain; if($s){$s;exit 1}else{exit 0}')

if ($Mode -ne 'Safe') {
    $actions = @('Install the current NSIS package for the current user','Launch the installed app twice and inspect single-instance behavior','Wait for normal tray/context-menu exit','Inspect settings, logs, processes and autostart entries','Run the registered uninstaller and inspect leftovers')
    Write-Warning ("This mode can change the current Windows user profile:`r`n - " + ($actions -join "`r`n - "))
    if ($Mode -eq 'CleanEnvironment' -and $env:DESK_PET_QA_CLEAN_ENVIRONMENT -ne '1') {
        Add-Result 'Clean environment authorization marker' 'blocked' 'blocked' '' 'Set DESK_PET_QA_CLEAN_ENVIRONMENT=1 only inside an explicitly designated Sandbox, VM, or disposable test system.'
    } elseif ($SkipInstall) {
        Add-Result 'Install lifecycle' 'manual' 'skipped' '' 'Skipped by -SkipInstall.'
    } elseif ($PSCmdlet.ShouldProcess('Current Windows user profile', ($actions -join '; '))) {
        $installer = (Get-ChildItem (Join-Path $repo 'release') -Filter '*setup.exe' -File | Select-Object -First 1).FullName
        [void](Invoke-QACommand 'Install application' "& .\scripts\windows\install-smoke-test.ps1 -InstallerPath '$($installer.Replace("'", "''"))' -Confirm:`$false" 'current-machine')
        $records = @(& { . (Join-Path $PSScriptRoot 'common.ps1'); Get-DeskPetInstallRecords })
        $exe = if ($records.Count -eq 1) { Join-Path ([string]$records[0].InstallLocation) 'desk-pet-framework.exe' } else { $null }
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            [void](Invoke-QACommand 'Single instance and normal exit' "& .\scripts\windows\process-smoke-test.ps1 -ExecutablePath '$($exe.Replace("'", "''"))' -ManualExitTimeoutSeconds 120 -Confirm:`$false" 'current-machine')
            if (-not $SkipPerformance -and (Get-Process -Name 'desk-pet-framework' -ErrorAction SilentlyContinue)) {
                [void](Invoke-QACommand 'Ten-minute performance capture' "& .\scripts\windows\monitor-process.ps1 -DurationMinutes 10 -IntervalSeconds 10 -OutputPath '$((Join-Path $output 'performance\short.csv').Replace("'", "''"))'" 'current-machine')
            }
        } else { Add-Result 'Installed executable discovery' 'current-machine' 'failed' '' 'A unique installed executable was not found.' }
        [void](Invoke-QACommand 'Autostart inspection' '& .\scripts\windows\check-autostart.ps1' 'current-machine')
        [void](Invoke-QACommand 'Uninstall application' '& .\scripts\windows\uninstall-smoke-test.ps1 -Confirm:$false' 'current-machine')
        [void](Invoke-QACommand 'Post-uninstall leftovers' '& .\scripts\windows\check-leftovers.ps1' 'current-machine')
    } else { Add-Result 'Current-machine lifecycle' 'manual' 'skipped' '' 'Declined or previewed by ShouldProcess/WhatIf.' }
}

$results | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $output 'qa-results.json')
$passed=@($results|Where-Object status -eq 'passed'); $failed=@($results|Where-Object status -eq 'failed'); $blocked=@($results|Where-Object status -eq 'blocked'); $skipped=@($results|Where-Object status -eq 'skipped')
$summary=@('# Windows QA summary','',"- Mode: $Mode","- Generated UTC: $([DateTime]::UtcNow.ToString('o'))",'',"## A. 自动验证通过 ($($passed.Count))",'') + @($passed|ForEach-Object{"- $($_.name)"}) + @('',"## B. 自动验证失败 ($($failed.Count))",'') + @($failed|ForEach-Object{"- $($_.name): $($_.details)"}) + @('',"## C. 被权限或环境阻止 ($($blocked.Count))",'') + @($blocked|ForEach-Object{"- $($_.name): $($_.details)"}) + @('','## D. 必须人工执行','', '- 真实 Windows 10/11、真实多显示器与 DPI、睡眠唤醒、SmartScreen、托盘界面操作、8 小时性能测试。','',"## E. 未执行 ($($skipped.Count))",'') + @($skipped|ForEach-Object{"- $($_.name): $($_.details)"})
($summary -join [Environment]::NewLine) | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $output 'qa-summary.md')
Write-Host "QA report written to: $output"
if ($failed.Count) { exit 2 }
