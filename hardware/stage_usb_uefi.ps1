param(
    [string]$DriveLetter,

    [ValidateSet('x86_64', 'aarch64')]
    [string]$Arch = 'x86_64',

    [string]$SourceRoot = '',

    [switch]$Force,

    [switch]$ListDrives
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) {
        return (Resolve-Path -LiteralPath $SourceRoot).Path
    }

    if ($PSScriptRoot) {
        $candidate = Join-Path $PSScriptRoot '..\..'
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return (Get-Location).Path
}

function Normalize-DriveLetter([string]$InputLetter) {
    $trimmed = $InputLetter.Trim()
    if ($trimmed.EndsWith(':')) {
        $trimmed = $trimmed.Substring(0, $trimmed.Length - 1)
    }
    if ($trimmed.Length -ne 1) {
        throw "DriveLetter must be one character (example: E or E:)"
    }
    return $trimmed.ToUpperInvariant()
}

function Show-Drives {
    Get-Volume |
        Where-Object { $_.DriveLetter } |
        Select-Object DriveLetter, FileSystem, Size, SizeRemaining, HealthStatus, DriveType |
        Format-Table -AutoSize
}

if ($ListDrives) {
    Show-Drives
    exit 0
}

if ([string]::IsNullOrWhiteSpace($DriveLetter)) {
    throw "DriveLetter is required unless -ListDrives is used."
}

$repoRoot = Get-RepoRoot
$normalizedDrive = Normalize-DriveLetter -InputLetter $DriveLetter
$targetRoot = "${normalizedDrive}:\"

$efiName = if ($Arch -eq 'x86_64') { 'BOOTX64.EFI' } else { 'BOOTAA64.EFI' }
$efiSource = Join-Path $repoRoot "out\$Arch\efi\$efiName"
$kernelSource = Join-Path $repoRoot "out\$Arch\megos-kernel.elf"

if (-not (Test-Path -LiteralPath $targetRoot)) {
    throw "Target drive not found: $targetRoot"
}

$vol = Get-Volume -DriveLetter $normalizedDrive -ErrorAction SilentlyContinue
if ($null -eq $vol) {
    throw "Unable to query volume info for drive ${normalizedDrive}:"
}

if ($vol.FileSystem -ne 'FAT32') {
    Write-Warning "Drive ${normalizedDrive}: filesystem is $($vol.FileSystem); UEFI removable media is most reliable with FAT32."
}

if (-not (Test-Path -LiteralPath $efiSource)) {
    throw "Missing EFI artifact: $efiSource"
}

if (-not (Test-Path -LiteralPath $kernelSource)) {
    throw "Missing kernel artifact: $kernelSource"
}

if (-not $Force) {
    Write-Host "About to copy MEGOS artifacts to $targetRoot"
    Write-Host "  EFI : $efiSource"
    Write-Host "  KERN: $kernelSource"
    $answer = Read-Host "Proceed? Type YES to continue"
    if ($answer -ne 'YES') {
        throw 'Aborted by user.'
    }
}

$targetEfiDir = Join-Path $targetRoot 'EFI\BOOT'
$targetEfiPath = Join-Path $targetEfiDir $efiName
$targetKernelPath = Join-Path $targetRoot 'megos-kernel.elf'

New-Item -ItemType Directory -Path $targetEfiDir -Force | Out-Null
Copy-Item -LiteralPath $efiSource -Destination $targetEfiPath -Force
Copy-Item -LiteralPath $kernelSource -Destination $targetKernelPath -Force

$efiSize = (Get-Item -LiteralPath $targetEfiPath).Length
$kernelSize = (Get-Item -LiteralPath $targetKernelPath).Length

Write-Host "Staged MEGOS artifacts to $targetRoot"
Write-Host "  $targetEfiPath ($efiSize bytes)"
Write-Host "  $targetKernelPath ($kernelSize bytes)"
Write-Host ""
Write-Host "Bootable layout:" 
Write-Host "  EFI\\BOOT\\$efiName"
Write-Host "  megos-kernel.elf"
