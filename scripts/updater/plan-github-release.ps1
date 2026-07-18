[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$CurrentVersion,
    [Parameter(Mandatory)][string]$ArtifactPath,
    [Parameter(Mandatory)][string]$SignaturePath,
    [Parameter(Mandatory)][string]$PublicKeyPath,
    [Parameter(Mandatory)][string]$LatestJsonPath,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$ChecksumPath,
    [string]$HostingConfigurationPath,
    [switch]$ConfirmPlan
)

$InvocationDirectory = (Get-Location).ProviderPath
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. ([System.IO.Path]::Combine($PSScriptRoot, 'common.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'github-release-common.ps1'))

if ([string]::IsNullOrWhiteSpace($HostingConfigurationPath)) {
    $HostingConfigurationPath = [System.IO.Path]::Combine($script:UpdaterRepositoryRoot, 'config', 'updater.github-releases.json')
}
$configurationPath = Resolve-UpdaterPath -Path $HostingConfigurationPath -BaseDirectory $InvocationDirectory
$artifact = Resolve-UpdaterPath -Path $ArtifactPath -BaseDirectory $InvocationDirectory
$signature = Resolve-UpdaterPath -Path $SignaturePath -BaseDirectory $InvocationDirectory
$publicKey = Resolve-UpdaterPath -Path $PublicKeyPath -BaseDirectory $InvocationDirectory
$latest = Resolve-UpdaterPath -Path $LatestJsonPath -BaseDirectory $InvocationDirectory
$manifest = Resolve-UpdaterPath -Path $ManifestPath -BaseDirectory $InvocationDirectory
$checksum = Resolve-UpdaterPath -Path $ChecksumPath -BaseDirectory $InvocationDirectory
$configuration = Read-GitHubUpdaterHostingConfiguration -LiteralPath $configurationPath
$repository = [string](Get-GitHubHostingPropertyValue $configuration 'repository')
$gitState = Get-GitHubUpdaterLocalGitState -RepositoryRoot $script:UpdaterRepositoryRoot -ExpectedRepository $repository
$tag = Get-GitHubUpdaterReleaseTag -Configuration $configuration -Version $Version
$plannedAssetNames = @(
    [System.IO.Path]::GetFileName($artifact), [System.IO.Path]::GetFileName($signature),
    [System.IO.Path]::GetFileName($latest), [System.IO.Path]::GetFileName($manifest), [System.IO.Path]::GetFileName($checksum)
)
$githubState = Get-GitHubUpdaterRepositoryState -Repository $repository -HeadCommit $gitState.Commit -Tag $tag `
    -AssetNames $plannedAssetNames -GloballyUniqueAssetNames @($plannedAssetNames[0],$plannedAssetNames[1]) -ReleaseExpectation Absent `
    -ExpectedPrerelease (Get-GitHubHostingRequiredBoolean -InputObject (Get-GitHubHostingPropertyValue $configuration 'release') -Name 'prerelease')
$plan = New-GitHubUpdaterReleasePlan -Configuration $configuration -Version $Version -CurrentVersion $CurrentVersion `
    -ArtifactPath $artifact -SignaturePath $signature -PublicKeyPath $publicKey -LatestJsonPath $latest `
    -ManifestPath $manifest -ChecksumPath $checksum -GitState $gitState -GitHubState $githubState

if (-not $ConfirmPlan -or $WhatIfPreference) {
    Write-Host 'Preview only. No release was created, no asset was uploaded, and no metadata endpoint was changed.'
    return $plan
}
if (-not $plan.GateSatisfied) {
    $failed = @($plan.Checks | Where-Object { -not $_.Passed } | ForEach-Object { $_.Name }) -join ', '
    throw "GitHub updater release preflight gate is not satisfied: $failed"
}
if (-not $PSCmdlet.ShouldProcess("$($plan.Repository) $($plan.Tag)", 'Confirm local GitHub Release publication plan')) {
    return $plan
}

# This command intentionally stops at a validated local plan. Remote mutations remain a
# separately authorized operator step after the plan has been reviewed.
$plan.Mode = 'ValidatedLocalPlan'
return $plan
