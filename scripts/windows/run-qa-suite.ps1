[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Safe','CurrentMachine','CleanEnvironment')][string]$Mode = 'Safe',
    [string]$OutputDirectory,
    [string]$InstallerPath,
    [string]$ExpectedVersion,
    [switch]$UseExistingInstallation,
    [switch]$SkipBuild,
    [switch]$SkipInstall,
    [switch]$SkipPerformance,
    [ValidateSet('Beginning','Uninstallation')][string]$ResumeFromPhase = 'Beginning'
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = [System.IO.Path]::Combine($repo, 'qa-results') }
$output = Resolve-CallerPath -Path $OutputDirectory -BaseDirectory $InvocationDirectory
if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) { $InstallerPath = Resolve-CallerPath -Path $InstallerPath -BaseDirectory $InvocationDirectory }
$releaseDirectory = [System.IO.Path]::Combine($repo, 'release')
$versionContext = Resolve-DeskPetVersionContext -RepositoryRoot $repo -ReleaseDirectory $releaseDirectory -InstallerPath $InstallerPath -ExplicitExpectedVersion $ExpectedVersion
$ExpectedVersion = $versionContext.ExpectedVersion
if ($ResumeFromPhase -ne 'Beginning' -and $Mode -ne 'CurrentMachine') { throw '-ResumeFromPhase Uninstallation requires -Mode CurrentMachine.' }
if ($UseExistingInstallation -and ($Mode -ne 'CurrentMachine' -or $ResumeFromPhase -ne 'Beginning')) { throw '-UseExistingInstallation requires -Mode CurrentMachine and -ResumeFromPhase Beginning.' }
if ($WhatIfPreference -and $ResumeFromPhase -eq 'Beginning' -and -not $UseExistingInstallation) {
    Assert-DeskPetVersionContext -VersionContext $versionContext
    Write-Host "QA suite preview: Mode=$Mode; ExpectedVersion=$ExpectedVersion; OutputDirectory=$output; InstallerPath=$(if($InstallerPath){$InstallerPath}else{'auto'}); SkipBuild=$SkipBuild; SkipInstall=$SkipInstall; SkipPerformance=$SkipPerformance; ResumeFromPhase=$ResumeFromPhase"
    Write-Host 'Safe checks would run first. CurrentMachine/CleanEnvironment would additionally request confirmation before install, launch, normal-exit wait, autostart inspection, uninstall, and leftover checks.'
    exit 0
}

$existingInstallSelection = $null
$existingUninstallSelection = $null
if ($UseExistingInstallation -and $WhatIfPreference) {
    $existingRecords = @(Get-DeskPetInstallRecords)
    Assert-DeskPetVersionContext -VersionContext $versionContext -RegistryVersions @($existingRecords | ForEach-Object { [string](Get-ObjectPropertyValue $_ 'DisplayVersion') })
    $existingInstallSelection = Select-DeskPetInstallRecord -Records $existingRecords -ExpectedVersion $ExpectedVersion
    $existingUninstallSelection = Select-DeskPetUninstallRecord -Records $existingRecords -ExpectedVersion $ExpectedVersion
    if (-not $existingInstallSelection.SelectedRecord) { throw 'No usable existing installation record was found.' }
    if (-not $existingUninstallSelection.SelectedRecord) { throw (Get-NoAvailableUninstallCommandMessage) }
    if ($WhatIfPreference) {
        Write-Host 'Existing-installation QA preview (the installer will not run):'
        Write-Host "  DisplayName: $([string](Get-ObjectPropertyValue $existingInstallSelection.SelectedRecord 'DisplayName'))"
        Write-Host "  DisplayVersion: $([string](Get-ObjectPropertyValue $existingInstallSelection.SelectedRecord 'DisplayVersion'))"
        Write-Host "  InstallLocation: $($existingInstallSelection.Evaluation.RedactedInstallLocation)"
        Write-Host "  MainExecutable: $(ConvertTo-RedactedNativePath $existingInstallSelection.ExecutablePath)"
        Write-Host "  Uninstaller: $($existingUninstallSelection.Command.RedactedFilePath)"
        Write-Host "  InstallerPath (validation only): $(if($InstallerPath){$InstallerPath}else{'<not provided>'})"
        Write-Host "  OutputDirectory: $output"
        Write-Host "  ExpectedVersion: $ExpectedVersion"
        Write-Host "  PhasePlan: $((Get-DeskPetCurrentMachinePhasePlan -UseExistingInstallation) -join ', ')"
        exit 0
    }
}
$directories = @($output, (Join-Path $output 'screenshots'), (Join-Path $output 'performance'), (Join-Path $output 'install'), (Join-Path $output 'uninstall'))
$savedWhatIfForOutput = $WhatIfPreference
$WhatIfPreference = $false
try { $directories | ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null } } finally { $WhatIfPreference = $savedWhatIfForOutput }
$commandLog = Join-Path $output 'command-log.txt'
if (-not [System.IO.File]::Exists($commandLog)) {
    $savedWhatIfForOutput = $WhatIfPreference
    $WhatIfPreference = $false
    try { Set-Content -Encoding UTF8 -LiteralPath $commandLog -Value '' } finally { $WhatIfPreference = $savedWhatIfForOutput }
}
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

function Assert-QACommand([string]$Name, [string]$Command, [string]$Category = 'current-machine') {
    if (-not (Invoke-QACommand $Name $Command $Category)) { throw "QA command failed: $Name" }
}

function Update-QATransactionState([System.Collections.IDictionary]$State) {
    $finalRecords = @(Get-DeskPetInstallRecords -IncludeLegacy)
    $State['uninstallRecordCount'] = $finalRecords.Count
    $State['installationDetected'] = [bool]$State['installationDetected'] -or $finalRecords.Count -gt 0
    $State['processCount'] = @(Get-DeskPetRunningProcesses -IncludeLegacy).Count
    $State['autostartEntryCount'] = @(Get-DeskPetRunEntries -IncludeLegacy).Count
    $State['startMenuEntryCount'] = @(Get-DeskPetStartMenuEntries -IncludeLegacy).Count
    $State['installRecords'] = @($finalRecords | ForEach-Object {
        $rawLocation = [string](Get-ObjectPropertyValue $_ 'InstallLocation')
        $directoryExists = $false
        try {
            $directory = [System.IO.Path]::GetDirectoryName((Join-NativeFileSystemPath $rawLocation 'placeholder.file'))
            $directoryExists = [System.IO.Directory]::Exists($directory)
        } catch { $directoryExists = $false }
        [ordered]@{
            displayName=[string](Get-ObjectPropertyValue $_ 'DisplayName'); displayVersion=[string](Get-ObjectPropertyValue $_ 'DisplayVersion')
            installLocation=ConvertTo-RedactedNativePath $rawLocation; installDirectoryExists=$directoryExists
            currentUser=([string](Get-ObjectPropertyValue $_ 'PSPath') -match 'HKEY_CURRENT_USER|HKCU:')
        }
    })
}

$currentPhase = 'initialization'
$failureMessage = $null
$exitCode = 0
$transaction = [ordered]@{
    mode=$Mode; phase=$currentPhase; expectedVersion=$ExpectedVersion; useExistingInstallation=[bool]$UseExistingInstallation; installerCommandCompleted=$false; installationDetected=$false
    processCount=0; uninstallRecordCount=0; installRecords=@(); recoveryCommands=@(
        "Get-Process -Name '$script:ProcessName' -ErrorAction SilentlyContinue",
        '.\scripts\windows\uninstall-smoke-test.ps1 -WhatIf'
    )
}

if ($ResumeFromPhase -eq 'Uninstallation') {
    try {
        $currentPhase = 'uninstall-record-selection'
        $records = @(Get-DeskPetInstallRecords)
        Assert-DeskPetVersionContext -VersionContext $versionContext -RegistryVersions @($records | ForEach-Object { [string](Get-ObjectPropertyValue $_ 'DisplayVersion') })
        $selection = Select-DeskPetUninstallRecord -Records $records -ExpectedVersion $ExpectedVersion
        foreach ($evaluation in @($selection.Evaluations | Where-Object { -not $_.Usable })) {
            Add-Result 'Stale or unusable uninstall record' 'current-machine' 'blocked' '' ("display={0}; version={1}; reasons={2}" -f $evaluation.DisplayName, $evaluation.DisplayVersion, ($evaluation.Reasons -join ' '))
        }
        if (-not $selection.SelectedRecord) { throw (Get-NoAvailableUninstallCommandMessage) }
        $selectedName = [string](Get-ObjectPropertyValue $selection.SelectedRecord 'DisplayName')
        $selectedVersion = [string](Get-ObjectPropertyValue $selection.SelectedRecord 'DisplayVersion')
        Write-Host "Selected application: $selectedName $selectedVersion"
        Write-Host "Selected uninstaller: $($selection.Command.RedactedFilePath) (source=$($selection.Command.Source))"
        Add-Result 'Uninstall record selection' 'current-machine' 'passed' '' "display=$selectedName; version=$selectedVersion; uninstaller=$($selection.Command.RedactedFilePath); source=$($selection.Command.Source)"
        if ($PSCmdlet.ShouldProcess("$selectedName $selectedVersion ($($selection.Command.RedactedFilePath))", 'Run uninstall-only QA and leftover checks')) {
            $currentPhase = 'uninstallation'
            Assert-QACommand 'Uninstall application' "& .\scripts\windows\uninstall-smoke-test.ps1 -ExpectedVersion '$($ExpectedVersion.Replace("'", "''"))' -Confirm:`$false"
            $currentPhase = 'post-uninstall-leftovers'
            Assert-QACommand 'Post-uninstall leftovers' '& .\scripts\windows\check-leftovers.ps1'
            $currentPhase = 'completed'
        } else {
            Add-Result 'Uninstall-only lifecycle' 'manual' 'skipped' '' 'Declined or previewed by ShouldProcess/WhatIf.'
            $currentPhase = 'preview-completed'
        }
    } catch {
        $failureMessage = $_.Exception.Message
        $exitCode = 2
        Add-Result 'QA suite exception' 'transaction' 'failed' '' "phase=$currentPhase; $failureMessage"
    } finally {
        $transaction.phase = $currentPhase
        try { Update-QATransactionState $transaction } catch { $transaction['stateInspectionError'] = $_.Exception.Message }
        Write-QAResultArtifacts -OutputDirectory $output -Results $results -Mode $Mode -Phase $currentPhase -FailureMessage $failureMessage -Transaction $transaction
    }
    Write-Host "QA report written to: $output"
    if ($exitCode -ne 0 -or @($results | Where-Object status -eq 'failed').Count) { exit 2 }
    exit 0
}
try {
    Assert-DeskPetVersionContext -VersionContext $versionContext
    $currentPhase = 'environment-capture'
    $environment = [ordered]@{
        capturedAtUtc=[DateTime]::UtcNow.ToString('o'); mode=$Mode; computerName=$env:COMPUTERNAME
        os=Get-QAOperatingSystemFacts
        powershell=$PSVersionTable.PSVersion.ToString(); nativeProcessorArchitecture=Get-NativeProcessorArchitecture
        is64BitOperatingSystem=[System.Environment]::Is64BitOperatingSystem; processArchitecture=Get-CurrentProcessArchitecture
        is64BitProcess=[System.Environment]::Is64BitProcess; webView2=$null; testEnvironments=$null
    }
    $webView = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue
    $environment.webView2 = @{ installed=[bool]$webView; version=$(if($webView){[string]$webView.pv}else{$null}); scenario='installed on current host; missing scenarios not modified on host' }
    $environment.testEnvironments = (& (Join-Path $PSScriptRoot 'detect-test-environments.ps1') | ConvertFrom-Json)
    $environment | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $output 'environment.json')

    $currentPhase = 'automatic-checks'
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
    [void](Invoke-QACommand 'Windows PowerShell regression tests' '$tests=@(Get-ChildItem -LiteralPath ''.\scripts\windows\tests'' -Filter ''*.tests.ps1'' | Sort-Object Name); foreach($test in $tests){ & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $test.FullName; if($LASTEXITCODE -ne 0){exit $LASTEXITCODE} }; exit 0')
    [void](Invoke-QACommand 'Updater secret scan' '& .\scripts\updater\scan-updater-secrets.ps1; exit $LASTEXITCODE')
    [void](Invoke-QACommand 'Git worktree clean' '$s=& git status --porcelain; if($s){$s;exit 1}else{exit 0}')

    if ($Mode -ne 'Safe') {
        $actions = if ($UseExistingInstallation) {
            @('Use the already installed application without running NSIS','Launch the installed app twice and keep the verified instance running','Capture the complete desktop pet and WebView2 process tree','Wait for normal tray/context-menu exit','Inspect settings, logs, processes and autostart entries','Run the registered uninstaller and inspect leftovers')
        } else {
            @('Install the current NSIS package for the current user','Launch the installed app twice and keep the verified instance running','Capture the complete desktop pet and WebView2 process tree','Wait for normal tray/context-menu exit','Inspect settings, logs, processes and autostart entries','Run the registered uninstaller and inspect leftovers')
        }
        Write-Warning ("This mode can change the current Windows user profile:`r`n - " + ($actions -join "`r`n - "))
        if ($Mode -eq 'CleanEnvironment' -and $env:DESK_PET_QA_CLEAN_ENVIRONMENT -ne '1') {
            Add-Result 'Clean environment authorization marker' 'blocked' 'blocked' '' 'Set DESK_PET_QA_CLEAN_ENVIRONMENT=1 only inside an explicitly designated Sandbox, VM, or disposable test system.'
        } elseif ($SkipInstall -and -not $UseExistingInstallation) {
            Add-Result 'Install lifecycle' 'manual' 'skipped' '' 'Skipped by -SkipInstall.'
        } elseif ($PSCmdlet.ShouldProcess('Current Windows user profile', ($actions -join '; '))) {
            if ($UseExistingInstallation) {
                $currentPhase = 'existing-installation-discovery'
                $records = @(Get-DeskPetInstallRecords)
                Assert-DeskPetVersionContext -VersionContext $versionContext -RegistryVersions @($records | ForEach-Object { [string](Get-ObjectPropertyValue $_ 'DisplayVersion') })
                $selection = Select-DeskPetInstallRecord -Records $records -ExpectedVersion $ExpectedVersion
                $uninstallSelection = Select-DeskPetUninstallRecord -Records $records -ExpectedVersion $ExpectedVersion
                if (-not $uninstallSelection.SelectedRecord) { throw (Get-NoAvailableUninstallCommandMessage) }
                $transaction.installationDetected = $records.Count -gt 0
                Add-Result 'Installer execution' 'current-machine' 'skipped' '' 'Skipped by -UseExistingInstallation.'
            } else {
                $currentPhase = 'installer-selection'
                $installer = if ($InstallerPath) { Get-Item -LiteralPath $InstallerPath } else { Get-DeskPetReleaseInstaller -ReleaseDirectory $releaseDirectory }
                if (-not $installer) { throw 'No current NSIS installer was found.' }
                $installerVersionContext = Resolve-DeskPetVersionContext -RepositoryRoot $repo -ReleaseDirectory $releaseDirectory -InstallerPath $installer.FullName -ExplicitExpectedVersion $ExpectedVersion
                Assert-DeskPetVersionContext -VersionContext $installerVersionContext
                $currentPhase = 'installation'
                Assert-QACommand 'Install application' "& .\scripts\windows\install-smoke-test.ps1 -InstallerPath '$($installer.FullName.Replace("'", "''"))' -ExpectedVersion '$($ExpectedVersion.Replace("'", "''"))' -Confirm:`$false"
                $transaction.installerCommandCompleted = $true
                $currentPhase = 'installed-application-discovery'
                $records = @(Get-DeskPetInstallRecords)
                $transaction.installationDetected = $records.Count -gt 0
                Assert-DeskPetVersionContext -VersionContext $installerVersionContext -RegistryVersions @($records | ForEach-Object { [string](Get-ObjectPropertyValue $_ 'DisplayVersion') })
                $selection = Select-DeskPetInstallRecord -Records $records -ExpectedVersion $ExpectedVersion
            }
            $currentPhase = 'installed-application-discovery'
            foreach ($evaluation in @($selection.Evaluations | Where-Object { -not $_.Usable })) {
                Add-Result 'Stale or unusable install record' 'current-machine' 'blocked' '' ("display={0}; version={1}; path={2}; reasons={3}" -f $evaluation.DisplayName, $evaluation.DisplayVersion, $evaluation.RedactedInstallLocation, ($evaluation.Reasons -join ' '))
            }
            if (-not $selection.SelectedRecord) { throw 'No valid installed application record was found for post-install validation.' }
            Add-Result 'Installed executable discovery' 'current-machine' 'passed' '' ("version={0}; path={1}; currentUser={2}" -f $selection.Evaluation.DisplayVersion, $selection.Evaluation.RedactedInstallLocation, $selection.Evaluation.CurrentUser)
            $exe = [string]$selection.ExecutablePath
            $currentPhase = 'single-instance-startup'
            Assert-QACommand 'Single instance startup' "& .\scripts\windows\process-smoke-test.ps1 -ExecutablePath '$($exe.Replace("'", "''"))' -Phase StartAndVerify -Confirm:`$false"
            $performanceFailure = $null
            if (-not $SkipPerformance) {
                try {
                    $currentPhase = 'performance-capture'
                    $performanceCsv = Join-Path $output 'performance\short.csv'
                    $performanceSummary = Join-Path $output 'performance\short-summary.md'
                    $performanceAnalysis = Join-Path $output 'performance\short-analysis.json'
                    Write-Host 'Keep the verified application running during the ten-minute performance capture.'
                    Assert-QACommand 'Ten-minute performance capture' "& .\scripts\windows\monitor-process.ps1 -DurationMinutes 10 -IntervalSeconds 10 -OutputPath '$($performanceCsv.Replace("'", "''"))'"
                    Assert-QACommand 'Performance aggregate analysis' "& .\scripts\windows\analyze-performance.ps1 -InputPath '$($performanceCsv.Replace("'", "''"))' -OutputPath '$($performanceSummary.Replace("'", "''"))' -JsonOutputPath '$($performanceAnalysis.Replace("'", "''"))'"
                } catch {
                    $performanceFailure = $_.Exception.Message
                }
            } else {
                Add-Result 'Performance capture' 'current-machine' 'skipped' '' 'Skipped by -SkipPerformance.'
            }
            $normalExitFailure = $null
            try {
                $currentPhase = 'normal-exit'
                if ($SkipPerformance) { Write-Host 'Startup validation is complete. Exit the application normally from its tray or context menu when prompted.' }
                else { Write-Host 'Performance capture is complete. Exit the application normally from its tray or context menu when prompted.' }
                Assert-QACommand 'Normal tray or context-menu exit' "& .\scripts\windows\process-smoke-test.ps1 -ExecutablePath '$($exe.Replace("'", "''"))' -Phase WaitForNormalExit -ManualExitTimeoutSeconds 120 -Confirm:`$false"
            } catch {
                $normalExitFailure = $_.Exception.Message
            }
            if ($performanceFailure -or $normalExitFailure) {
                throw ("Runtime QA failed: performance={0}; normalExit={1}" -f $(if($performanceFailure){$performanceFailure}else{'passed'}), $(if($normalExitFailure){$normalExitFailure}else{'passed'}))
            }
            $currentPhase = 'settings-and-logs-inspection'
            Assert-QACommand 'Settings and logs inspection' '& .\scripts\windows\check-runtime-data.ps1'
            $currentPhase = 'autostart-inspection'
            Assert-QACommand 'Autostart inspection' "& .\scripts\windows\check-autostart.ps1 -ExpectedExecutable '$($exe.Replace("'", "''"))'"
            $currentPhase = 'uninstallation'
            Assert-QACommand 'Uninstall application' "& .\scripts\windows\uninstall-smoke-test.ps1 -ExpectedVersion '$($ExpectedVersion.Replace("'", "''"))' -Confirm:`$false"
            $currentPhase = 'post-uninstall-leftovers'
            Assert-QACommand 'Post-uninstall leftovers' '& .\scripts\windows\check-leftovers.ps1'
            $currentPhase = 'completed'
        } else { Add-Result 'Current-machine lifecycle' 'manual' 'skipped' '' 'Declined by ShouldProcess.' }
    } else { $currentPhase = 'completed' }
} catch {
    $failureMessage = $_.Exception.Message
    $exitCode = 2
    Add-Result 'QA suite exception' 'transaction' 'failed' '' "phase=$currentPhase; $failureMessage"
} finally {
    $transaction.phase = $currentPhase
    if ($Mode -ne 'Safe') {
        try { Update-QATransactionState $transaction } catch { $transaction['stateInspectionError'] = $_.Exception.Message }
    }
    Write-QAResultArtifacts -OutputDirectory $output -Results $results -Mode $Mode -Phase $currentPhase -FailureMessage $failureMessage -Transaction $transaction
}
Write-Host "QA report written to: $output"
if ($exitCode -ne 0 -or @($results | Where-Object status -eq 'failed').Count) { exit 2 }
