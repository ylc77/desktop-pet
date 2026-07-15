Set-StrictMode -Version Latest

$script:ProductName = 'Desk Pet Framework'
$script:ProcessName = 'desk-pet-framework'
$script:AppIdentifier = 'dev.deskpet.framework'

function ConvertTo-NormalizedProcessorArchitecture {
    param([AllowNull()][string]$Architecture)
    if ([string]::IsNullOrWhiteSpace($Architecture)) { return $null }
    switch ($Architecture.ToUpperInvariant()) {
        'AMD64' { return 'x64' }
        'X86' { return 'x86' }
        'ARM64' { return 'arm64' }
        default { return $Architecture.ToLowerInvariant() }
    }
}

function Get-NativeProcessorArchitecture {
    param(
        [AllowNull()][string]$ArchitectureW6432 = $env:PROCESSOR_ARCHITEW6432,
        [AllowNull()][string]$Architecture = $env:PROCESSOR_ARCHITECTURE,
        [Nullable[bool]]$Is64BitOperatingSystem = $null
    )
    $native = $ArchitectureW6432
    if ([string]::IsNullOrWhiteSpace($native)) { $native = $Architecture }
    if ([string]::IsNullOrWhiteSpace($native)) {
        $osIs64Bit = if ($null -eq $Is64BitOperatingSystem) { [System.Environment]::Is64BitOperatingSystem } else { [bool]$Is64BitOperatingSystem }
        $native = if ($osIs64Bit) { 'AMD64' } else { 'x86' }
    }
    ConvertTo-NormalizedProcessorArchitecture $native
}

function Get-CurrentProcessArchitecture {
    param(
        [AllowNull()][string]$Architecture = $env:PROCESSOR_ARCHITECTURE,
        [Nullable[bool]]$Is64BitProcess = $null
    )
    if (-not [string]::IsNullOrWhiteSpace($Architecture)) {
        return ConvertTo-NormalizedProcessorArchitecture $Architecture
    }
    $processIs64Bit = if ($null -eq $Is64BitProcess) { [System.Environment]::Is64BitProcess } else { [bool]$Is64BitProcess }
    if ($processIs64Bit) { return Get-NativeProcessorArchitecture }
    return 'x86'
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Join-NativeFileSystemPath {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$BasePath,
        [Parameter(Mandatory)][string]$ChildPath
    )
    $expanded = [Environment]::ExpandEnvironmentVariables($BasePath).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($expanded)) { throw 'InstallLocation is empty.' }
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        throw "InstallLocation is not an absolute path: $expanded"
    }
    try {
        return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($expanded, $ChildPath))
    } catch {
        throw "InstallLocation is not a valid native path: $expanded"
    }
}

function ConvertTo-RedactedNativePath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '<empty>' }
    $redacted = [Environment]::ExpandEnvironmentVariables($Path).Trim().Trim('"')
    $locations = @(
        @{ Value=$env:LOCALAPPDATA; Token='%LOCALAPPDATA%' },
        @{ Value=$env:APPDATA; Token='%APPDATA%' },
        @{ Value=$env:USERPROFILE; Token='%USERPROFILE%' },
        @{ Value=$env:ProgramFiles; Token='%ProgramFiles%' },
        @{ Value=${env:ProgramFiles(x86)}; Token='%ProgramFiles(x86)%' }
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Value) } |
        Sort-Object { ([string]$_.Value).Length } -Descending
    foreach ($location in $locations) {
        $prefix = ([string]$location.Value).TrimEnd('\')
        if ($redacted.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return [string]$location.Token + $redacted.Substring($prefix.Length)
        }
    }
    if ($redacted -match '^[A-Za-z]:\\Users\\[^\\]+(?<rest>\\.*)?$') {
        return '%USERPROFILE%' + [string]$Matches['rest']
    }
    return $redacted
}

function Get-DeskPetReleaseVersion {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $configPath = [System.IO.Path]::Combine($RepositoryRoot, 'src-tauri', 'tauri.conf.json')
    if (-not [System.IO.File]::Exists($configPath)) { throw "Tauri configuration not found: $configPath" }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return [string](Get-ObjectPropertyValue -InputObject $config -Name 'version')
}

function Select-DeskPetInstallRecord {
    param(
        [AllowEmptyCollection()][object[]]$Records = @(),
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [string]$ExecutableName = 'desk-pet-framework.exe',
        [scriptblock]$DirectoryExists = { param($Path) [System.IO.Directory]::Exists($Path) },
        [scriptblock]$FileExists = { param($Path) [System.IO.File]::Exists($Path) }
    )
    $evaluations = @()
    foreach ($record in @($Records)) {
        $displayName = [string](Get-ObjectPropertyValue $record 'DisplayName')
        $displayVersion = [string](Get-ObjectPropertyValue $record 'DisplayVersion')
        $installLocation = [string](Get-ObjectPropertyValue $record 'InstallLocation')
        $psPath = [string](Get-ObjectPropertyValue $record 'PSPath')
        $reasons = @()
        $executablePath = $null
        $normalizedDirectory = $null
        if ($displayName -ne $script:ProductName) { $reasons += 'DisplayName is not an exact match.' }
        if ($displayVersion -ne $ExpectedVersion) { $reasons += "DisplayVersion does not match $ExpectedVersion." }
        try {
            $executablePath = Join-NativeFileSystemPath -BasePath $installLocation -ChildPath $ExecutableName
            $normalizedDirectory = [System.IO.Path]::GetDirectoryName($executablePath)
            if (-not (& $DirectoryExists $normalizedDirectory)) { $reasons += 'InstallLocation directory does not exist or is unavailable.' }
            if (-not (& $FileExists $executablePath)) { $reasons += 'Main executable does not exist.' }
        } catch {
            $reasons += $_.Exception.Message
        }
        $evaluations += [pscustomobject]@{
            Record=$record
            DisplayName=$displayName
            DisplayVersion=$displayVersion
            RedactedInstallLocation=ConvertTo-RedactedNativePath $installLocation
            InstallDirectory=$normalizedDirectory
            ExecutablePath=$executablePath
            CurrentUser=($psPath -match 'HKEY_CURRENT_USER|HKCU:')
            Usable=($reasons.Count -eq 0)
            Reasons=@($reasons)
        }
    }
    $selected = @($evaluations | Where-Object { $_.Usable } | Sort-Object @{Expression='CurrentUser';Descending=$true}) | Select-Object -First 1
    [pscustomobject]@{
        SelectedRecord=$(if ($selected) { $selected.Record } else { $null })
        ExecutablePath=$(if ($selected) { $selected.ExecutablePath } else { $null })
        Evaluation=$(if ($selected) { $selected } else { $null })
        Evaluations=@($evaluations)
    }
}

function Get-NoAvailableUninstallCommandMessage {
    return -join @([char]0x6CA1,[char]0x6709,[char]0x53EF,[char]0x7528,[char]0x5378,[char]0x8F7D,[char]0x547D,[char]0x4EE4)
}

function ConvertFrom-NativeCommandLine {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { throw (Get-NoAvailableUninstallCommandMessage) }
    $expanded = [Environment]::ExpandEnvironmentVariables($CommandLine).Trim()
    $filePath = $null
    $argumentText = $null
    if ($expanded -match '^"(?<file>[^"]+)"(?:\s+(?<arguments>.*))?$') {
        $filePath = [string]$Matches['file']
        $argumentText = [string]$Matches['arguments']
    } elseif ($expanded -match '^(?<file>.+?\.exe)(?:\s+(?<arguments>.*))?$') {
        $filePath = ([string]$Matches['file']).Trim()
        $argumentText = [string]$Matches['arguments']
    } else {
        throw 'The uninstall command format cannot be parsed safely.'
    }
    if ([string]::IsNullOrWhiteSpace($filePath) -or -not [System.IO.Path]::IsPathRooted($filePath)) {
        throw 'The uninstaller path is not a valid absolute path.'
    }
    try { $filePath = [System.IO.Path]::GetFullPath($filePath) } catch { throw 'The uninstaller path format is invalid.' }
    if ([string]::IsNullOrWhiteSpace($argumentText)) { $argumentList = [string[]]@() }
    else { $argumentList = [string[]]@($argumentText.Trim()) }
    [pscustomobject]@{ FilePath=$filePath; ArgumentList=$argumentList }
}

function Resolve-DeskPetUninstallCommand {
    param(
        [Parameter(Mandatory)][object]$Record,
        [scriptblock]$FileExists = { param($Path) [System.IO.File]::Exists($Path) }
    )
    $candidates = @(
        [pscustomobject]@{ Source='QuietUninstallString'; Value=[string](Get-ObjectPropertyValue $Record 'QuietUninstallString') },
        [pscustomobject]@{ Source='UninstallString'; Value=[string](Get-ObjectPropertyValue $Record 'UninstallString') }
    )
    $errors = @()
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.Value)) { continue }
        try {
            $parsed = ConvertFrom-NativeCommandLine -CommandLine $candidate.Value
            if (-not (& $FileExists $parsed.FilePath)) {
                $errors += "$($candidate.Source) points to a missing or unavailable executable."
                continue
            }
            return [pscustomobject]@{
                Source=$candidate.Source
                FilePath=$parsed.FilePath
                ArgumentList=$parsed.ArgumentList
                RedactedFilePath=ConvertTo-RedactedNativePath $parsed.FilePath
            }
        } catch {
            $errors += "$($candidate.Source): $($_.Exception.Message)"
        }
    }
    if ($errors.Count) { throw ((Get-NoAvailableUninstallCommandMessage) + ': ' + ($errors -join ' ')) }
    throw (Get-NoAvailableUninstallCommandMessage)
}

function Select-DeskPetUninstallRecord {
    param(
        [AllowEmptyCollection()][object[]]$Records = @(),
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [scriptblock]$FileExists = { param($Path) [System.IO.File]::Exists($Path) }
    )
    $evaluations = @()
    foreach ($record in @($Records)) {
        $displayName = [string](Get-ObjectPropertyValue $record 'DisplayName')
        $displayVersion = [string](Get-ObjectPropertyValue $record 'DisplayVersion')
        $psPath = [string](Get-ObjectPropertyValue $record 'PSPath')
        $reasons = @()
        $command = $null
        if ($displayName -ne $script:ProductName) { $reasons += 'DisplayName is not an exact match.' }
        if ($displayVersion -ne $ExpectedVersion) { $reasons += "DisplayVersion does not match $ExpectedVersion." }
        try { $command = Resolve-DeskPetUninstallCommand -Record $record -FileExists $FileExists } catch { $reasons += $_.Exception.Message }
        $evaluations += [pscustomobject]@{
            Record=$record; DisplayName=$displayName; DisplayVersion=$displayVersion; Command=$command
            CurrentUser=($psPath -match 'HKEY_CURRENT_USER|HKCU:'); Usable=($reasons.Count -eq 0); Reasons=@($reasons)
        }
    }
    $selected = @($evaluations | Where-Object { $_.Usable } | Sort-Object @{Expression='CurrentUser';Descending=$true}) | Select-Object -First 1
    [pscustomobject]@{
        SelectedRecord=$(if ($selected) { $selected.Record } else { $null })
        Command=$(if ($selected) { $selected.Command } else { $null })
        Evaluation=$(if ($selected) { $selected } else { $null })
        Evaluations=@($evaluations)
    }
}

function Write-QAResultArtifacts {
    param(
        [Parameter(Mandatory)][string]$OutputDirectory,
        [AllowEmptyCollection()][object[]]$Results = @(),
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Phase,
        [AllowNull()][string]$FailureMessage,
        [AllowNull()][object]$Transaction
    )
    $savedWhatIfPreference = $WhatIfPreference
    $WhatIfPreference = $false
    try {
        [System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
        ConvertTo-Json -InputObject @($Results) -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath ([System.IO.Path]::Combine($OutputDirectory, 'qa-results.json'))
        if ($null -ne $Transaction) {
            $Transaction | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath ([System.IO.Path]::Combine($OutputDirectory, 'current-machine-state.json'))
        }
    $passed = @($Results | Where-Object { $_.status -eq 'passed' })
    $failed = @($Results | Where-Object { $_.status -eq 'failed' })
    $blocked = @($Results | Where-Object { $_.status -eq 'blocked' })
    $skipped = @($Results | Where-Object { $_.status -eq 'skipped' })
    $summary = @(
        '# Windows QA summary', '', "- Mode: $Mode", "- Final phase: $Phase",
        "- Generated UTC: $([DateTime]::UtcNow.ToString('o'))", "- Failure: $(if ($FailureMessage) { $FailureMessage } else { 'none' })", '',
        "## Passed ($($passed.Count))", ''
    ) + @($passed | ForEach-Object { "- $($_.name)" }) + @('', "## Failed ($($failed.Count))", '') +
        @($failed | ForEach-Object { "- $($_.name): $($_.details)" }) + @('', "## Blocked ($($blocked.Count))", '') +
        @($blocked | ForEach-Object { "- $($_.name): $($_.details)" }) + @('', '## Manual Windows checks', '',
        '- Real Windows 10/11, multi-monitor and DPI, sleep/wake, SmartScreen, tray interaction, and eight-hour performance testing.', '',
        "## Skipped ($($skipped.Count))", '') + @($skipped | ForEach-Object { "- $($_.name): $($_.details)" })
        ($summary -join [Environment]::NewLine) | Set-Content -Encoding UTF8 -LiteralPath ([System.IO.Path]::Combine($OutputDirectory, 'qa-summary.md'))
    } finally {
        $WhatIfPreference = $savedWhatIfPreference
    }
}

function Get-DeskPetInstallRecords {
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $roots) {
        Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq $script:ProductName }
    }
}

function Get-DeskPetRunEntries {
    $runKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($key in $runKeys) {
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($property in $item.PSObject.Properties) {
            if ($property.Name -like 'PS*') { continue }
            $value = [string]$property.Value
            if ($property.Name -match 'desk.?pet' -or $value -match 'desk-pet-framework|Desk Pet Framework') {
                [pscustomobject]@{ Key = $key; Name = $property.Name; Value = $value }
            }
        }
    }
}

function Write-SmokeResult {
    param([string]$Name, [bool]$Passed, [string]$Details)
    $status = if ($Passed) { 'PASS' } else { 'FAIL' }
    [pscustomobject]@{ Check = $Name; Status = $status; Details = $Details }
}

function Assert-FileExists {
    param([Parameter(Mandatory)][string]$LiteralPath, [string]$Label = 'File')
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "$Label not found: $LiteralPath"
    }
}
