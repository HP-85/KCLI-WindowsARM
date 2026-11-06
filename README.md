# armify-kiro

A PowerShell script that replaces the bundled x64 tooling inside **Kiro-CLI** with native **ARM64** equivalents.

> **Note:** Kiro-CLI itself remains an x64 binary and still runs under emulation. This script targets the tools it bundles and invokes — `node.exe`, `bun.exe`, and `rg.exe` — replacing those with ARM64 builds for native performance where it counts.

Works on any Windows on ARM system — Snapdragon, NVIDIA, and Apple Silicon running Windows in a VM.

## What it does

Kiro-CLI bundles three x64 tools that run under emulation on ARM hardware. This script detects the version of each one already installed and downloads the matching ARM64 build:

| Binary | Source |
|--------|--------|
| `node.exe` | [nodejs.org](https://nodejs.org) official ARM64 zip |
| `bun.exe` | [oven-sh/bun](https://github.com/oven-sh/bun) releases |
| `rg.exe` (ripgrep) | [BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep) releases |

Each binary is replaced in-place. No backup is kept — Kiro will restore the original x64 version if it runs a self-update, so just re-run this script after any Kiro update.

## Requirements

- Windows on ARM (ARM64)
- PowerShell 7+ (`pwsh`)
- Internet access (to download ARM64 builds)

## Usage

```powershell
# Basic — replace all three binaries
.\armify-kiro.ps1

# Preview what would happen without making changes
.\armify-kiro.ps1 -WhatIf

# Force-replace even if already ARM64
.\armify-kiro.ps1 -Force

# Skip specific binaries
.\armify-kiro.ps1 -SkipRg
.\armify-kiro.ps1 -SkipNode -SkipBun

# Point to a custom Kiro-CLI directory
.\armify-kiro.ps1 -KiroDir "D:\Tools\Kiro-Cli"
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `-KiroDir` | Override the Kiro-CLI install path (default: `%LOCALAPPDATA%\Kiro-Cli`) |
| `-SkipNode` | Skip replacing `node.exe` |
| `-SkipBun` | Skip replacing `bun.exe` |
| `-SkipRg` | Skip replacing `rg.exe` |
| `-Force` | Replace binaries even if they are already ARM64 |
| `-WhatIf` | Dry run — show what would be replaced without doing it |

## How it works

1. Locates the Kiro-CLI directory.
2. For each binary, reads the PE header to check the current architecture.
3. Runs the binary with `--version` to detect the exact installed version.
4. Downloads the matching ARM64 release zip from the official source.
5. Verifies the downloaded binary is actually ARM64 before replacing.
6. Replaces the binary in-place and verifies the result.
7. Cleans up all temporary files.

## Re-running after a Kiro update

Kiro's auto-updater will overwrite the ARM64 binaries with x64 ones. Just re-run the script:

```powershell
.\armify-kiro.ps1
```

The script always reads the currently installed version, so it will download the correct matching ARM64 build automatically.

## License

MIT
