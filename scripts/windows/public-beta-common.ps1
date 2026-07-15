Set-StrictMode -Version Latest

function Get-PublicBetaHostFacts {
    $savedWhatIfPreference = $script:WhatIfPreference
    $script:WhatIfPreference = $false
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $computer = Get-CimInstance Win32_ComputerSystem
    } finally { $script:WhatIfPreference = $savedWhatIfPreference }
    $manufacturer = [string]$computer.Manufacturer
    $model = [string]$computer.Model
    [ordered]@{
        windowsCaption=[string]$os.Caption
        windowsVersion=[string]$os.Version
        windowsBuild=[string]$os.BuildNumber
        architecture=Get-NativeProcessorArchitecture
        isVirtualMachine=($manufacturer -match 'Microsoft Corporation|VMware|innotek|QEMU|Xen|Parallels' -or $model -match 'Virtual|VMware|VirtualBox|KVM')
        virtualMachineVendor=$(if ($manufacturer -or $model) { "$manufacturer $model".Trim() } else { $null })
    }
}

function Get-PublicBetaArtifactFacts {
    param([AllowNull()][string]$InstallerPath)
    if ([string]::IsNullOrWhiteSpace($InstallerPath) -or -not [System.IO.File]::Exists($InstallerPath)) {
        return [ordered]@{ installerFile=$null; installerSha256=$null; signatureStatus=$null; sizeBytes=$null }
    }
    $savedWhatIfPreference = $script:WhatIfPreference
    $script:WhatIfPreference = $false
    try {
        $item = Get-Item -LiteralPath $InstallerPath
        $hash = Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256
        $signature = Get-AuthenticodeSignature -FilePath $item.FullName
    } finally { $script:WhatIfPreference = $savedWhatIfPreference }
    [ordered]@{
        installerFile=$item.Name
        installerSha256=$hash.Hash
        signatureStatus=[string]$signature.Status
        sizeBytes=$item.Length
    }
}

function New-PublicBetaEnvironmentResult {
    param(
        [Parameter(Mandatory)][string]$EnvironmentId,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][ValidateSet('passed','failed','blocked','not_executed')][string]$Status,
        [Parameter(Mandatory)][string]$GitCommit,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][object]$HostFacts,
        [Parameter(Mandatory)][object]$ArtifactFacts,
        [AllowEmptyCollection()][object[]]$Checks = @(),
        [AllowEmptyCollection()][string[]]$Notes = @()
    )
    [ordered]@{
        schemaVersion=1
        environmentId=$EnvironmentId
        mode=$Mode
        status=$Status
        testEnvironment=$EnvironmentId
        windows=$HostFacts
        testedAtUtc=[DateTime]::UtcNow.ToString('o')
        gitCommit=$GitCommit
        artifact=$ArtifactFacts
        command=$Command
        checks=@($Checks)
        notes=@($Notes)
    }
}

function Write-PublicBetaEnvironmentResult {
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][string]$Directory
    )
    [System.IO.Directory]::CreateDirectory($Directory) | Out-Null
    $path = [System.IO.Path]::Combine($Directory, 'environment-result.json')
    $Result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}
