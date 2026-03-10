# ============================================================
#  Hyper-V  –  Create cloudServer VM for OpenStack AIO
#  Run in PowerShell as Administrator on the Hyper-V host
# ============================================================

param(
    [string]$VMName          = "cloudServer",
    [string]$ISOPath         = "",   # auto-detected below if left empty
    [string]$VMStoragePath   = "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks",
    [int]   $MemoryMB        = 20480,
    [int]   $CPUCount        = 2,
    [int]   $DiskGB          = 300,
    [int]   $SSDDiskGB       = 50,
    [string]$SwitchName      = "Default Switch"
)

$ErrorActionPreference = "Stop"

function Write-Step  { param($msg) Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "[OK]  $msg" -ForegroundColor Green }
function Write-Fail  { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }

# ── Auto-detect ISO in Desktop "cloud computing" folder ──────
Write-Step "Locating Ubuntu ISO"
if (-not $ISOPath) {
    # Search every user's Desktop for a folder matching "cloud*computing*"
    $DesktopRoots = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { "$($_.FullName)\Desktop" } |
                    Where-Object { Test-Path $_ }

    foreach ($desk in $DesktopRoots) {
        $folder = Get-ChildItem $desk -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match "cloud" -and $_.Name -match "computing" } |
                  Select-Object -First 1
        if ($folder) {
            $iso = Get-ChildItem $folder.FullName -Filter "ubuntu*.iso" -Recurse -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($iso) { $ISOPath = $iso.FullName; break }
        }
    }
}

if (-not $ISOPath -or -not (Test-Path $ISOPath)) {
    Write-Host ""
    Write-Host "  Could not auto-detect the Ubuntu ISO." -ForegroundColor Yellow
    Write-Host "  Please enter the full path to the ISO file:" -ForegroundColor Yellow
    $ISOPath = Read-Host "  ISO path"
}

if (-not (Test-Path $ISOPath)) {
    Write-Fail "ISO not found at: $ISOPath"
}
Write-Ok "ISO found: $ISOPath"

# ── Remove existing VM if present ───────────────────────────
Write-Step "Checking for existing VM"
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Host "VM '$VMName' already exists – removing …" -ForegroundColor Yellow
    Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue
    Remove-VM -Name $VMName -Force
}

# ── Create VM ───────────────────────────────────────────────
Write-Step "Creating VM: $VMName"
$VHDPath  = "$VMStoragePath\$VMName\${VMName}_OS.vhdx"
$SSDPath  = "$VMStoragePath\$VMName\${VMName}_SSD.vhdx"

New-Item -ItemType Directory -Path "$VMStoragePath\$VMName" -Force | Out-Null

New-VM -Name $VMName `
       -MemoryStartupBytes ($MemoryMB * 1MB) `
       -Generation 2 `
       -Path $VMStoragePath `
       -NoVHD
Write-Ok "VM created"

# ── Memory (static, no dynamic to keep OpenStack stable) ────
Set-VM -Name $VMName -StaticMemory -MemoryStartupBytes ($MemoryMB * 1MB)
Write-Ok "Memory set: ${MemoryMB} MB (static)"

# ── CPU ─────────────────────────────────────────────────────
Set-VMProcessor -VMName $VMName -Count $CPUCount
Write-Ok "CPU count: $CPUCount"

# ── Enable nested virtualisation ────────────────────────────
Write-Step "Enabling nested virtualisation"
Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true
Write-Ok "Nested virtualisation enabled"

# ── OS disk (300 GB) ────────────────────────────────────────
Write-Step "Creating OS VHD  (${DiskGB} GB)"
New-VHD -Path $VHDPath -SizeBytes ($DiskGB * 1GB) -Dynamic | Out-Null
Add-VMHardDiskDrive -VMName $VMName -Path $VHDPath -ControllerType SCSI
Write-Ok "OS disk created: $VHDPath"

# ── SSD disk (50 GB) for Cinder ─────────────────────────────
Write-Step "Creating SSD VHD  (${SSDDiskGB} GB)"
New-VHD -Path $SSDPath -SizeBytes ($SSDDiskGB * 1GB) -Dynamic | Out-Null
Add-VMHardDiskDrive -VMName $VMName -Path $SSDPath -ControllerType SCSI
Write-Ok "SSD disk created: $SSDPath"

# ── DVD / ISO ────────────────────────────────────────────────
Write-Step "Attaching Ubuntu ISO"
Add-VMDvdDrive -VMName $VMName -Path $ISOPath
Write-Ok "ISO attached"

# ── Network adapters ────────────────────────────────────────
Write-Step "Configuring network adapters"
# Remove default NIC
Get-VMNetworkAdapter -VMName $VMName | Remove-VMNetworkAdapter

# eth0  – management
Add-VMNetworkAdapter -VMName $VMName -Name "eth0" -SwitchName $SwitchName
Write-Ok "eth0 added → $SwitchName"

# eth1  – Neutron external (also on Default Switch – change if you have a separate switch)
Add-VMNetworkAdapter -VMName $VMName -Name "eth1" -SwitchName $SwitchName
Write-Ok "eth1 added → $SwitchName"

# ── Secure Boot: disable (Ubuntu installer needs this off for Gen2) ──
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
Write-Ok "Secure Boot disabled"

# ── Boot order: DVD first ────────────────────────────────────
$DVD  = Get-VMDvdDrive  -VMName $VMName
$Disk = Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1
Set-VMFirmware -VMName $VMName -BootOrder $DVD,$Disk
Write-Ok "Boot order: DVD → HDD"

# ── Summary ─────────────────────────────────────────────────
Write-Step "VM Summary"
Get-VM -Name $VMName | Format-List Name, State, MemoryStartup, ProcessorCount
Get-VMHardDiskDrive -VMName $VMName | Format-Table Path, ControllerType
Get-VMNetworkAdapter -VMName $VMName | Format-Table Name, SwitchName

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  VM '$VMName' ready!                              ║" -ForegroundColor Green
Write-Host "║                                                          ║" -ForegroundColor Green
Write-Host "║  Next steps:                                             ║" -ForegroundColor Green
Write-Host "║  1. Start-VM -Name '$VMName'                      ║" -ForegroundColor Green
Write-Host "║  2. Connect-VMConsole / vmconnect.exe                    ║" -ForegroundColor Green
Write-Host "║  3. Install Ubuntu 24.04 (user: openstack / pw: root)    ║" -ForegroundColor Green
Write-Host "║     Language: English | Keyboard: French AZERTY          ║" -ForegroundColor Green
Write-Host "║     ✔ Install OpenSSH Server                             ║" -ForegroundColor Green
Write-Host "║  4. SCP deploy_openstack.sh to the VM and run it         ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
