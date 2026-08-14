<#
.SYNOPSIS
    CarmelOS ISO build script (Windows PowerShell wrapper)
.DESCRIPTION
    Builds the CarmelOS live ISO image by orchestrating the Linux
    build toolchain through Windows Subsystem for Linux (WSL).
    The actual heavy lifting (debootstrap, chroot, mksquashfs, xorriso)
    runs inside WSL; this script handles Windows-side orchestration,
    path translation, progress display and ISO delivery.
.PARAMETER OutputDir
    Directory on Windows where the finished CarmelOS.iso will be placed.
    Defaults to the current directory.
.PARAMETER WslDistro
    WSL distribution to use. Defaults to the default distro.
.PARAMETER KeepWorkDir
    Keep the WSL working directory after build (useful for rebuilds).
.EXAMPLE
    .\Build-CarmelOS.exe
    .\Build-CarmelOS.exe -OutputDir "D:\ISOs"
#>
[CmdletBinding()]
param(
    [string]$OutputDir = ".",
    [string]$WslDistro = "",
    [switch]$KeepWorkDir,
    [switch]$Help
)

# ── Configuration ──────────────────────────────────────────────
$script:ErrorActionPreference = "Stop"
$script:CarmelOSVersion       = "1.0"
$script:IsoName               = "CarmelOS.iso"
$script:WslWorkDir            = "/workspace/carmelos-build"
$script:RequiredLinuxPackages = @(
    "debootstrap", "squashfs-tools", "xorriso", "isolinux",
    "syslinux-common", "grub-pc-bin", "grub-efi-amd64-bin",
    "mtools", "proot", "debian-archive-keyring", "live-build"
)

# Orange / white theme colours for console output
$script:ColorOrange = "DarkYellow"
$script:ColorWhite  = "White"
$script:ColorErr    = "Red"
$script:ColorOk     = "Green"

# ── Helper functions ───────────────────────────────────────────

function Write-Banner {
    param([string]$Text)
    $bar = "=" * 60
    Write-Host ""
    Write-Host $bar -ForegroundColor $ColorOrange
    Write-Host "  $Text" -ForegroundColor $ColorWhite
    Write-Host $bar -ForegroundColor $ColorOrange
}

function Write-Step {
    param([string]$Text)
    Write-Host "[CarmelOS] $Text" -ForegroundColor $ColorOrange
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[OK] $Text" -ForegroundColor $ColorOk
}

function Write-Err {
    param([string]$Text)
    Write-Host "[ERROR] $Text" -ForegroundColor $ColorErr
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Wsl {
    param(
        [string]$Command,
        [switch]$NoErrorCheck
    )
    $wslArgs = @()
    if ($WslDistro) { $wslArgs += @("-d", $WslDistro) }
    $wslArgs += @("--", "bash", "-lc", $Command)

    if ($NoErrorCheck) {
        & wsl @wslArgs 2>&1 | ForEach-Object { Write-Host $_ }
    } else {
        $output = & wsl @wslArgs 2>&1
        $output | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "WSL command failed (exit $LASTEXITCODE): $Command"
        }
    }
}

function ConvertTo-WslPath {
    param([string]$WindowsPath)
    # Convert e.g. C:\Users\foo  ->  /mnt/c/Users/foo
    if ($WindowsPath -match '^([A-Za-z]):\\(.*)$') {
        $drive = $matches[1].ToLower()
        $rest  = $matches[2] -replace '\\', '/'
        return "/mnt/$drive/$rest"
    }
    return $WindowsPath -replace '\\', '/'
}

# ── Pre-flight checks ──────────────────────────────────────────

function Test-Prerequisites {
    Write-Step "Checking prerequisites..."

    # WSL
    if (-not (Test-Command "wsl")) {
        Write-Err "WSL is not installed or not on PATH."
        Write-Host "  Install it with:  wsl --install" -ForegroundColor $ColorWhite
        Write-Host "  Then reboot and rerun this script." -ForegroundColor $ColorWhite
        exit 1
    }
    Write-Ok "WSL is available."

    # Check that a distro is installed
    $distros = & wsl --list --quiet 2>&1 | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if (-not $distros) {
        Write-Err "No WSL distribution is installed."
        Write-Host "  Install one with:  wsl --install -d Debian" -ForegroundColor $ColorWhite
        exit 1
    }
    Write-Ok "WSL distro(s): $($distros -join ', ')"

    # Output directory
    $resolvedOut = (Resolve-Path -Path $OutputDir -ErrorAction SilentlyContinue).Path
    if (-not $resolvedOut) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
        $resolvedOut = (Resolve-Path -Path $OutputDir).Path
    }
    $script:OutputDir = $resolvedOut
    Write-Ok "Output directory: $resolvedOut"
}

# ── Ensure Linux build dependencies ────────────────────────────

function Install-LinuxDeps {
    Write-Step "Ensuring Linux build dependencies inside WSL..."

    $pkgList = $RequiredLinuxPackages -join " "
    $cmd = @"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkgList
"@
    Invoke-Wsl -Command $cmd -NoErrorCheck
    Write-Ok "Linux dependencies ready."
}

# ── Copy project files into WSL ────────────────────────────────

function Sync-ProjectFiles {
    Write-Step "Syncing project files into WSL..."

    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

    $wslScriptDir = ConvertTo-WslPath $scriptDir

    # Create the working directory in WSL
    Invoke-Wsl -Command "mkdir -p $WslWorkDir" -NoErrorCheck

    # Copy the entire project (config, build script, hooks, includes)
    $cmd = "cp -aT '$wslScriptDir/' '$WslWorkDir/' 2>/dev/null; true"
    Invoke-Wsl -Command $cmd -NoErrorCheck

    Write-Ok "Project files synced to $WslWorkDir"
}

# ── Run the actual build ───────────────────────────────────────

function Invoke-Build {
    Write-Banner "Building CarmelOS $CarmelOSVersion"

    # Make the build script executable and run it
    $cmd = "cd $WslWorkDir && chmod +x build-carmelos.sh && bash build-carmelos.sh"

    Write-Step "Running build script inside WSL (this will take a while)..."
    Write-Host ""

    Invoke-Wsl -Command $cmd -NoErrorCheck

    # Check if the ISO was produced
    $checkCmd = "test -f $WslWorkDir/CarmelOS.iso && echo EXISTS || echo MISSING"
    $result = (& wsl $(if ($WslDistro) { @("-d", $WslDistro) }) -- bash -lc $checkCmd 2>&1).Trim()

    if ($result -ne "EXISTS") {
        Write-Err "Build did not produce CarmelOS.iso"
        Write-Host "  Check the build log above for errors." -ForegroundColor $ColorWhite
        exit 1
    }

    $sizeCmd = "ls -lh $WslWorkDir/CarmelOS.iso | awk '{print `$5}'"
    $isoSize = (& wsl $(if ($WslDistro) { @("-d", $WslDistro) }) -- bash -lc $sizeCmd 2>&1).Trim()
    Write-Ok "ISO built in WSL ($isoSize)"
}

# ── Copy the ISO back to Windows ───────────────────────────────

function Copy-IsoToWindows {
    Write-Step "Copying CarmelOS.iso to Windows..."

    $destPath = Join-Path $OutputDir $IsoName
    $wslDest  = ConvertTo-WslPath $destPath

    # Use cp inside WSL (faster than crossing the 9P boundary)
    $cmd = "cp -f '$WslWorkDir/CarmelOS.iso' '$wslDest'"
    Invoke-Wsl -Command $cmd -NoErrorCheck

    if (Test-Path $destPath) {
        $size = (Get-Item $destPath).Length / 1MB
        Write-Ok "CarmelOS.iso copied to: $destPath ($([math]::Round($size, 1)) MB)"
    } else {
        Write-Err "Failed to copy ISO to $destPath"
        Write-Host "  The ISO is available inside WSL at: $WslWorkDir/CarmelOS.iso" -ForegroundColor $ColorWhite
    }
}

# ── Cleanup ────────────────────────────────────────────────────

function Invoke-Cleanup {
    if ($KeepWorkDir) {
        Write-Step "Keeping WSL working directory ($WslWorkDir) for rebuilds."
        return
    }
    Write-Step "Cleaning up WSL working directory..."
    $cmd = "rm -rf $WslWorkDir/chroot $WslWorkDir/binary $WslWorkDir/build.log"
    Invoke-Wsl -Command $cmd -NoErrorCheck
    Write-Ok "Cleanup done."
}

# ── Main ───────────────────────────────────────────────────────

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit 0
}

Write-Banner "CarmelOS Build Tool v$CarmelOSVersion"
Write-Host "  Orange & White  -  Xfce Live ISO" -ForegroundColor $ColorOrange
Write-Host ""

try {
    Test-Prerequisites
    Install-LinuxDeps
    Sync-ProjectFiles
    Invoke-Build
    Copy-IsoToWindows
    Invoke-Cleanup

    Write-Banner "CarmelOS build complete!"
    Write-Host ""
    Write-Host "  ISO: $(Join-Path $OutputDir $IsoName)" -ForegroundColor $ColorOk
    Write-Host ""
    Write-Host "  Burn to USB with:" -ForegroundColor $ColorWhite
    Write-Host "    Rufus  ->  https://rufus.ie" -ForegroundColor $ColorWhite
    Write-Host "    balenaEtcher  ->  https://etcher.balena.io" -ForegroundColor $ColorWhite
    Write-Host ""

} catch {
    Write-Err $_.Exception.Message
    exit 1
}
