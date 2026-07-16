[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$packagingScript = [System.IO.Path]::Combine($repositoryRoot, 'scripts', 'package-character.ps1')
$results = @()

function Add-TestResult([string]$Name, [bool]$Passed, [string]$Details) {
    $script:results += [pscustomobject]@{ Name=$Name; Passed=$Passed; Details=$Details }
}

function Test-Equal([string]$Name, [object]$Expected, [object]$Actual) {
    Add-TestResult $Name ($Expected -eq $Actual) "expected=$Expected; actual=$Actual"
}

$unicodeRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), (-join @([char]0x89D2, [char]0x8272, ' package test ')) + [Guid]::NewGuid().ToString('N'))
$characterRoot = [System.IO.Path]::Combine($unicodeRoot, (-join @([char]0x4E2D, [char]0x6587, ' characters')))
$outputDirectory = [System.IO.Path]::Combine($unicodeRoot, (-join @([char]0x8F93, [char]0x51FA, ' packages')))
[void][System.IO.Directory]::CreateDirectory($characterRoot)

try {
    Copy-Item -LiteralPath ([System.IO.Path]::Combine($repositoryRoot, 'public', 'characters', '_placeholder')) -Destination $characterRoot -Recurse
    $package = & $packagingScript -CharacterId '_placeholder' -CharacterRoot $characterRoot -OutputDirectory $outputDirectory

    Test-Equal 'Package script supports Chinese paths with spaces' $true ([System.IO.File]::Exists([string]$package.Path))
    Test-Equal 'Package uses qipet extension' '.qipet' ([System.IO.Path]::GetExtension([string]$package.Path))
    Test-Equal 'Package metadata reports the character version' '0.1.0' ([string]$package.Version)
    Test-Equal 'Validation generated frames.json before packaging' $true ([System.IO.File]::Exists([System.IO.Path]::Combine($characterRoot, '_placeholder', 'frames.json')))

    $expectedHash = (Get-FileHash -LiteralPath ([string]$package.Path) -Algorithm SHA256).Hash.ToUpperInvariant()
    Test-Equal 'Reported SHA-256 matches package bytes' $expectedHash ([string]$package.SHA256)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead([string]$package.Path)
    try {
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName })
        Test-Equal 'manifest.json is at the package root' $true ($entryNames -contains 'manifest.json')
        Test-Equal 'frames.json is at the package root' $true ($entryNames -contains 'frames.json')
        Test-Equal 'Character parent directory is not stored in the package' 0 (@($entryNames | Where-Object { $_ -like '_placeholder/*' }).Count)
        Test-Equal 'Animation entries use ZIP-compatible separators' $true (@($entryNames | Where-Object { $_ -like 'animations/*/*.png' }).Count -gt 0)
    } finally {
        $archive.Dispose()
    }

    $beforeHash = (Get-FileHash -LiteralPath ([string]$package.Path) -Algorithm SHA256).Hash
    $overwriteRejected = $false
    try {
        & $packagingScript -CharacterId '_placeholder' -CharacterRoot $characterRoot -OutputDirectory $outputDirectory | Out-Null
    } catch {
        $overwriteRejected = $_.Exception.Message -match 'will not be overwritten'
    }
    $afterHash = (Get-FileHash -LiteralPath ([string]$package.Path) -Algorithm SHA256).Hash
    Test-Equal 'Existing package is rejected instead of overwritten' $true $overwriteRejected
    Test-Equal 'Rejected overwrite leaves existing bytes unchanged' $beforeHash $afterHash

    $index = Get-Content -LiteralPath ([System.IO.Path]::Combine($characterRoot, 'index.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    $entry = $index.characters[0]
    Test-Equal 'Generated index includes version metadata' '0.1.0' ([string]$entry.version)
    Test-Equal 'Generated index includes author metadata' $true (-not [string]::IsNullOrWhiteSpace([string]$entry.author))
    Test-Equal 'Generated index includes license metadata' $true (-not [string]::IsNullOrWhiteSpace([string]$entry.license))
    Test-Equal 'Generated index includes preview URL' '/characters/_placeholder/preview.png' ([string]$entry.preview)
    Test-Equal 'Generated index includes icon URL' '/characters/_placeholder/icon.png' ([string]$entry.icon)

    Add-Type -AssemblyName System.Drawing
    $previewPath = [System.IO.Path]::Combine($characterRoot, '_placeholder', 'preview.png')
    $tinyPreview = New-Object System.Drawing.Bitmap(1, 1, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $tinyPreview.Save($previewPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $tinyPreview.Dispose()
    }
    $node = Get-Command node -CommandType Application -ErrorAction Stop
    $validatorPath = [System.IO.Path]::Combine($repositoryRoot, 'scripts', 'validate-character-pack.mjs')
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $validationOutput = & $node.Source $validatorPath --root $characterRoot 2>&1
        $validationExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    Test-Equal 'Preview outside the documented PNG dimensions is rejected' $true ($validationExitCode -ne 0)
    Test-Equal 'Preview dimension failure identifies the asset and size' $true ([bool](([string]($validationOutput -join "`n")) -match 'preview.*1x1'))

    $gitignore = Get-Content -LiteralPath ([System.IO.Path]::Combine($repositoryRoot, '.gitignore')) -Raw -Encoding UTF8
    Test-Equal 'Default package output is ignored by Git' $true ([bool]($gitignore -match '(?m)^character-packages/$'))
} finally {
    if ([System.IO.Directory]::Exists($unicodeRoot)) { [System.IO.Directory]::Delete($unicodeRoot, $true) }
}

$results | Format-Table -AutoSize
$hostIsPowerShell51 = $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
[pscustomobject]@{ Name='Windows PowerShell 5.1 host'; Passed=$hostIsPowerShell51; Details=$PSVersionTable.PSVersion.ToString() } | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -or -not $hostIsPowerShell51) { exit 1 }
