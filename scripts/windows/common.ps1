Set-StrictMode -Version Latest

$script:ProductName = 'Desk Pet Framework'
$script:ProcessName = 'desk-pet-framework'
$script:AppIdentifier = 'dev.deskpet.framework'

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
