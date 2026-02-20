param(
    [string]$OutPath = ("out\hw_profile_windows_{0}.txt" -f $env:COMPUTERNAME)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Section {
    param([string]$Title)
    Add-Content -Path $OutPath -Value ("== {0} ==" -f $Title)
}

function Add-CommandOutput {
    param(
        [string]$Title,
        [scriptblock]$Command
    )

    Write-Section $Title
    try {
        & $Command | Out-String | Add-Content -Path $OutPath
    } catch {
        Add-Content -Path $OutPath -Value ("N/A ({0})" -f $_.Exception.Message)
    }
    Add-Content -Path $OutPath -Value ""
}

function Get-SecureBootState {
    try {
        $enabled = Confirm-SecureBootUEFI
        if ($enabled) { return "SecureBoot enabled" }
        return "SecureBoot disabled"
    } catch {
        return "SecureBoot state unavailable: $($_.Exception.Message)"
    }
}

function Get-FirmwareType {
    try {
        $control = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -ErrorAction Stop
        if ($null -ne $control.PEFirmwareType) {
            if ($control.PEFirmwareType -eq 2) { return "UEFI" }
            if ($control.PEFirmwareType -eq 1) { return "Legacy BIOS" }
        }
    } catch {
        # Fall through to firmware variable environment probe.
    }

    try {
        $fw = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" -Name FIRMWARE_TYPE -ErrorAction Stop).FIRMWARE_TYPE
        if ($fw) {
            return [string]$fw
        }
    } catch {
        # Fallback below.
    }

    return "Unknown"
}

$outDir = Split-Path -Parent $OutPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

"MEGOS Hardware Probe (Windows)" | Set-Content -Path $OutPath
"Timestamp: $(Get-Date -Format o)" | Add-Content -Path $OutPath
"" | Add-Content -Path $OutPath

Add-CommandOutput -Title "OS" -Command {
    Get-ComputerInfo |
        Select-Object WindowsProductName, WindowsVersion, WindowsBuildLabEx, OsName, OsVersion, OsArchitecture, CsName
}

Add-CommandOutput -Title "CPU" -Command {
    Get-CimInstance Win32_Processor |
        Select-Object Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed
}

Add-CommandOutput -Title "Memory" -Command {
    Get-CimInstance Win32_PhysicalMemory |
        Select-Object Manufacturer, PartNumber, Capacity, Speed
}

Add-CommandOutput -Title "Firmware / BIOS / Board" -Command {
    $bios = Get-CimInstance Win32_BIOS | Select-Object Manufacturer, SMBIOSBIOSVersion, ReleaseDate
    $board = Get-CimInstance Win32_BaseBoard | Select-Object Manufacturer, Product, Version, SerialNumber
    $cs = Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model

    [pscustomobject]@{
        Manufacturer = $cs.Manufacturer
        Model = $cs.Model
        BIOSVendor = $bios.Manufacturer
        BIOSVersion = $bios.SMBIOSBIOSVersion
        BIOSReleaseDate = $bios.ReleaseDate
        BaseBoardVendor = $board.Manufacturer
        BaseBoardProduct = $board.Product
        FirmwareType = Get-FirmwareType
        SecureBoot = Get-SecureBootState
    }
}

Add-CommandOutput -Title "Disks" -Command {
    Get-Disk | Select-Object Number, FriendlyName, BusType, PartitionStyle, Size
}

Add-CommandOutput -Title "Volumes" -Command {
    Get-Volume | Select-Object DriveLetter, FileSystem, Size, SizeRemaining, HealthStatus
}

Add-CommandOutput -Title "PCI / Display / USB / Input PnP Snapshot" -Command {
    Get-PnpDevice |
        Where-Object {
            $_.Present -eq $true -and (
                $_.Class -match "Display|USB|HIDClass|Keyboard|Mouse|System|Net|Media" -or
                $_.FriendlyName -match "xHCI|I2C|SMBus|LPC|ISA|ACPI|NVMe|SATA|Keyboard|Mouse"
            )
        } |
        Select-Object Class, FriendlyName, InstanceId, Status
}

Add-CommandOutput -Title "Keyboard / Mouse devices" -Command {
    Get-PnpDevice -Class Keyboard,Mouse,HIDClass |
        Select-Object Class, FriendlyName, InstanceId, Status
}

Add-CommandOutput -Title "Interrupt Assignment (PnP allocated resources)" -Command {
    Get-CimInstance Win32_PnPAllocatedResource |
        Where-Object { $_.Dependent -match "IRQ" } |
        Select-Object Antecedent, Dependent
}

Write-Host "Wrote hardware profile: $OutPath"
