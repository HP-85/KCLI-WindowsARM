#Requires -Version 5.1
<#
.SYNOPSIS
    Replaces x64 binaries in Kiro-CLI with native ARM64 equivalents.

.DESCRIPTION
    Detects and replaces node.exe, bun.exe, and rg.exe (ripgrep) inside
    C:\Users\<you>\AppData\Local\Kiro-Cli with their ARM64 Windows builds.
    Reads the version of each installed binary so the correct matching
    ARM64 release is always downloaded — safe to re-run after any Kiro update.

    Binaries handled:
      - node.exe    -> nodejs.org official ARM64 zip
      - bun.exe     -> github.com/oven-sh/bun ARM64 zip
      - rg.exe      -> github.com/BurntSushi/ripgrep ARM64 zip (in kas\<ver>\node_modules)

    Replaces each binary in-place with no backup — Kiro will restore the
    original x64 version if it runs an update.

.PARAMETER KiroDir
    Override the Kiro-Cli installation directory (default: auto-detected).

.PARAMETER SkipNode
    Skip replacing node.exe.

.PARAMETER SkipBun
    Skip replacing bun.exe.

.PARAMETER SkipRg
    Skip replacing rg.exe.

.PARAMETER Remove
    Delete the ARM64 binaries so Kiro-CLI will re-download its original x64
    versions on next launch. Useful for reverting or troubleshooting.

.PARAMETER Force
    Replace even if the binary is already ARM64.

.PARAMETER WhatIf
    Show what would be replaced without making any changes.

.EXAMPLE
    .\armify-kiro.ps1

.EXAMPLE
    .\armify-kiro.ps1 -WhatIf

.EXAMPLE
    .\armify-kiro.ps1 -Force -SkipRg

.EXAMPLE
    .\armify-kiro.ps1 -Remove
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $KiroDir   = "",
    [switch] $SkipNode,
    [switch] $SkipBun,
    [switch] $SkipRg,
    [switch] $Force,
    [switch] $Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference    = 'SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Step  { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Skip  { param($msg) Write-Host "    [--] $msg" -ForegroundColor DarkGray }
function Write-Warn  { param($msg) Write-Host "    [!!] $msg" -ForegroundColor Yellow }
function Write-Fail  { param($msg) Write-Host "    [XX] $msg" -ForegroundColor Red }

function Get-PEArch {
    param([string]$Path)
    # Read only the first 512 bytes -- enough for the PE header
    $fs   = [System.IO.File]::OpenRead($Path)
    $buf  = New-Object byte[] 512
    $read = $fs.Read($buf, 0, 512)
    $fs.Close()
    if ($read -lt 0x40 -or $buf[0] -ne 0x4D -or $buf[1] -ne 0x5A) { return "Not a PE" }
    $peOffset    = [BitConverter]::ToInt32($buf, 0x3C)
    if ($peOffset + 6 -gt $read) { return "PE header out of range" }
    $machineType = [BitConverter]::ToUInt16($buf, $peOffset + 4)
    if     ($machineType -eq 0x8664) { return "x64" }
    elseif ($machineType -eq 0xAA64) { return "ARM64" }
    elseif ($machineType -eq 0x14C)  { return "x86" }
    else                             { return "Unknown(0x{0:X4})" -f $machineType }
}

function Download-File {
    param([string]$Url, [string]$Dest)
    if ($WhatIfPreference) {
        Write-Host "    What if: Would download $(Split-Path $Url -Leaf)"
        return
    }
    New-Item -ItemType Directory -Path (Split-Path $Dest) -Force | Out-Null
    Write-Host "    Downloading $(Split-Path $Url -Leaf) ..." -NoNewline
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
    Write-Host " done ($( '{0:N1}' -f ((Get-Item $Dest).Length / 1MB) ) MB)"
}

function Replace-Binary {
    param([string]$Source, [string]$Dest, [string]$Label)
    if ($PSCmdlet.ShouldProcess($Dest, "Replace with ARM64 $Label")) {
        Copy-Item $Source $Dest -Force
        Write-Ok "Replaced $Label -> ARM64  ($( '{0:N1}' -f ((Get-Item $Dest).Length / 1MB) ) MB)"
    }
}

# ── Locate Kiro-Cli ───────────────────────────────────────────────────────────

Write-Step "Locating Kiro-Cli directory"

if (-not $KiroDir) {
    $KiroDir = Join-Path $env:LOCALAPPDATA "Kiro-Cli"
}

if (-not (Test-Path $KiroDir)) {
    Write-Fail "Kiro-Cli directory not found: $KiroDir"
    exit 1
}
Write-Ok "Found: $KiroDir"

$tmpRoot = Join-Path $env:TEMP "armify-kiro"
if (-not $WhatIfPreference) {
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
}

# ── Remove mode ───────────────────────────────────────────────────────────────

if ($Remove) {
    Write-Step "Removing ARM64 binaries (Kiro-CLI will re-download x64 on next launch)"

    $toRemove = @()
    if (-not $SkipNode) { $toRemove += Join-Path $KiroDir "node.exe" }
    if (-not $SkipBun)  { $toRemove += Join-Path $KiroDir "bun.exe" }
    if (-not $SkipRg) {
        $rgInstances = Get-ChildItem (Join-Path $KiroDir "kas") -Recurse -Filter "rg.exe" -ErrorAction SilentlyContinue
        if ($rgInstances) { $toRemove += $rgInstances.FullName }
    }

    foreach ($f in $toRemove) {
        if (Test-Path $f) {
            if ($PSCmdlet.ShouldProcess($f, "Delete")) {
                Remove-Item $f -Force
                Write-Ok "Deleted $f"
            }
        } else {
            Write-Skip "Not found, skipping: $f"
        }
    }

    Write-Host ""
    Write-Host "Done. Launch Kiro-CLI to restore the original x64 binaries." -ForegroundColor Green
    Write-Host ""
    exit 0
}

# ── node.exe ──────────────────────────────────────────────────────────────────

if (-not $SkipNode) {
    Write-Step "node.exe"
    $nodePath = Join-Path $KiroDir "node.exe"

    if (-not (Test-Path $nodePath)) {
        Write-Warn "node.exe not found at $nodePath"
        Write-Warn "Run Kiro-CLI once first, then re-run this script"
    } else {
        $currentArch = Get-PEArch $nodePath
        Write-Host "    Current arch : $currentArch"

        if ($currentArch -eq "ARM64" -and -not $Force) {
            Write-Skip "Already ARM64, nothing to do  (use -Force to replace anyway)"
        } else {
            # Detect installed version
            $nodeVer = (& $nodePath --version 2>&1).Trim()   # e.g. "v22.23.4"
            Write-Host "    Version      : $nodeVer"

            $url      = "https://nodejs.org/dist/$nodeVer/node-$nodeVer-win-arm64.zip"
            $zipPath  = Join-Path $tmpRoot "node-$nodeVer-win-arm64.zip"
            $exDir    = Join-Path $tmpRoot "node-arm64"

            if ($WhatIfPreference) {
                Write-Host "    What if: Would download node $nodeVer ARM64 and replace $nodePath"
            } else {
                Download-File $url $zipPath

                if (Test-Path $exDir) { Remove-Item $exDir -Recurse -Force }
                Write-Host "    Expanding $(Split-Path $zipPath -Leaf) ..." -NoNewline
                [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $exDir)
                Write-Host " done"

                $arm64Exe = Get-ChildItem $exDir -Recurse -Filter "node.exe" |
                            Select-Object -First 1

                if (-not $arm64Exe) {
                    Write-Fail "node.exe not found inside downloaded zip — aborting node replacement"
                } else {
                    $extractedArch = Get-PEArch $arm64Exe.FullName
                    if ($extractedArch -ne "ARM64") {
                        Write-Fail "Downloaded node.exe is $extractedArch, not ARM64 — aborting"
                    } else {
                        Replace-Binary -Source $arm64Exe.FullName -Dest $nodePath -Label "node.exe"
                        $newArch = Get-PEArch $nodePath
                        $newVer  = (& $nodePath --version 2>&1).Trim()
                        Write-Ok "Verified: $newVer  arch=$newArch"
                    }
                }
            }
        }
    }
}

# ── bun.exe ───────────────────────────────────────────────────────────────────

if (-not $SkipBun) {
    Write-Step "bun.exe"
    $bunPath = Join-Path $KiroDir "bun.exe"

    if (-not (Test-Path $bunPath)) {
        Write-Warn "bun.exe not found at $bunPath"
        Write-Warn "Run Kiro-CLI once first, then re-run this script"
    } else {
        $currentArch = Get-PEArch $bunPath
        Write-Host "    Current arch : $currentArch"

        if ($currentArch -eq "ARM64" -and -not $Force) {
            Write-Skip "Already ARM64, nothing to do  (use -Force to replace anyway)"
        } else {
            # Detect installed version
            $bunVer = (& $bunPath --version 2>&1).Trim()   # e.g. "1.4.4"
            Write-Host "    Version      : $bunVer"

            $url     = "https://github.com/oven-sh/bun/releases/download/bun-v$bunVer/bun-windows-aarch64.zip"
            $zipPath = Join-Path $tmpRoot "bun-$bunVer-windows-aarch64.zip"
            $exDir   = Join-Path $tmpRoot "bun-arm64"

            if ($WhatIfPreference) {
                Write-Host "    What if: Would download bun $bunVer ARM64 and replace $bunPath"
            } else {
                Download-File $url $zipPath

                if (Test-Path $exDir) { Remove-Item $exDir -Recurse -Force }
                Write-Host "    Expanding $(Split-Path $zipPath -Leaf) ..." -NoNewline
                [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $exDir)
                Write-Host " done"

                $arm64Exe = Get-ChildItem $exDir -Recurse -Filter "bun.exe" |
                            Select-Object -First 1

                if (-not $arm64Exe) {
                    Write-Fail "bun.exe not found inside downloaded zip — aborting bun replacement"
                } else {
                    $extractedArch = Get-PEArch $arm64Exe.FullName
                    if ($extractedArch -ne "ARM64") {
                        Write-Fail "Downloaded bun.exe is $extractedArch, not ARM64 — aborting"
                    } else {
                        Replace-Binary -Source $arm64Exe.FullName -Dest $bunPath -Label "bun.exe"
                        $newArch = Get-PEArch $bunPath
                        $newVer  = (& $bunPath --version 2>&1).Trim()
                        Write-Ok "Verified: $newVer  arch=$newArch"
                    }
                }
            }
        }
    }
}

# ── rg.exe (ripgrep) ──────────────────────────────────────────────────────────

if (-not $SkipRg) {
    Write-Step "rg.exe (ripgrep)"

    # rg.exe lives inside a versioned kas directory — find all copies
    $rgInstances = Get-ChildItem (Join-Path $KiroDir "kas") -Recurse -Filter "rg.exe" -ErrorAction SilentlyContinue

    if (-not $rgInstances) {
        Write-Warn "rg.exe not found under $KiroDir\kas"
        Write-Warn "Run Kiro-CLI once first, then re-run this script"
    } else {
        foreach ($rg in $rgInstances) {
            $rgPath      = $rg.FullName
            $currentArch = Get-PEArch $rgPath
            Write-Host "    Found : $rgPath"
            Write-Host "    Arch  : $currentArch"

            if ($currentArch -eq "ARM64" -and -not $Force) {
                Write-Skip "Already ARM64, nothing to do  (use -Force to replace anyway)"
                continue
            }

            # Parse version from --version output
            $rgVerLine = (& $rgPath --version 2>&1) | Select-Object -First 1
            # Output looks like: "ripgrep 15.0.0 (rev ...)"
            if ($rgVerLine -match 'ripgrep\s+([\d.]+)') {
                $rgVer = $Matches[1]
            } else {
                Write-Fail "Could not parse ripgrep version from: $rgVerLine"
                continue
            }
            Write-Host "    Version : $rgVer"

            $zipName = "ripgrep-$rgVer-aarch64-pc-windows-msvc.zip"
            $url     = "https://github.com/BurntSushi/ripgrep/releases/download/$rgVer/$zipName"
            $zipPath = Join-Path $tmpRoot $zipName
            $exDir   = Join-Path $tmpRoot "rg-arm64"

            if ($WhatIfPreference) {
                Write-Host "    What if: Would download ripgrep $rgVer ARM64 and replace $rgPath"
                continue
            }

            Download-File $url $zipPath

            if (Test-Path $exDir) { Remove-Item $exDir -Recurse -Force }
            Write-Host "    Expanding $(Split-Path $zipPath -Leaf) ..." -NoNewline
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $exDir)
            Write-Host " done"

            $arm64Exe = Get-ChildItem $exDir -Recurse -Filter "rg.exe" |
                        Select-Object -First 1

            if (-not $arm64Exe) {
                Write-Fail "rg.exe not found inside downloaded zip — skipping"
                continue
            }

            $extractedArch = Get-PEArch $arm64Exe.FullName
            if ($extractedArch -ne "ARM64") {
                Write-Fail "Downloaded rg.exe is $extractedArch, not ARM64 — skipping"
                continue
            }

            Replace-Binary -Source $arm64Exe.FullName -Dest $rgPath -Label "rg.exe"
            $newArch    = Get-PEArch $rgPath
            $newVerLine = (& $rgPath --version 2>&1) | Select-Object -First 1
            Write-Ok "Verified: $newVerLine  arch=$newArch"
        }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Step "Cleanup"
if (Test-Path $tmpRoot) {
    Remove-Item $tmpRoot -Recurse -Force
    Write-Ok "Removed temp dir: $tmpRoot"
}

Write-Host ""
Write-Host "All done! Re-run this script any time after a Kiro-Cli update." -ForegroundColor Green
Write-Host ""
