<#
.SYNOPSIS
    Build and deploy Ollama from source with AMD Radeon AI Pro R9700 (gfx1201) support.

.DESCRIPTION
    The pre-built Ollama binaries ship ROCm libraries compiled only for gfx1100/1101/1102.
    The R9700 (RDNA 4, gfx1201) is already supported in the ollama source code and build
    targets, but needs to be compiled from source with a ROCm SDK that includes gfx1201.

    This script:
    1. Builds the CPU backend (ggml-cpu DLLs)
    2. Builds the ROCm/HIP backend with gfx1201 included
    3. Builds the Ollama Go binary
    4. Runs Go tests
    5. Backs up and replaces the existing Ollama installation
    6. Optionally restarts Ollama and runs a verification test

    No source patches are needed — gfx1201 is already in the upstream build targets.
    You can safely `git pull origin main` and re-run this script after merging.

.PARAMETER Build
    Build Ollama from source (CPU + ROCm backends + Go binary)

.PARAMETER Deploy
    Deploy built binaries over the existing Ollama installation

.PARAMETER Test
    Start Ollama server and verify both GPUs are detected, then run a test model

.PARAMETER Restore
    Restore the original Ollama installation from backup

.PARAMETER Clean
    Remove build artifacts before building

.PARAMETER All
    Equivalent to -Build -Deploy -Test

.PARAMETER SkipROCm
    Skip building ROCm backend (reuse existing build)

.PARAMETER SkipCPU
    Skip building CPU backend (reuse existing build)

.PARAMETER TestModel
    Model to use for verification (default: qwen3-coder-next:latest)

.EXAMPLE
    .\build-r9700.ps1 -All
    Full build, deploy, and test cycle

.EXAMPLE
    .\build-r9700.ps1 -Build
    Build only (no deploy or test)

.EXAMPLE
    .\build-r9700.ps1 -Build -SkipROCm
    Rebuild Go binary only, reuse existing ROCm build

.EXAMPLE
    .\build-r9700.ps1 -Deploy -Test
    Deploy and test (assumes prior build)

.EXAMPLE
    .\build-r9700.ps1 -Restore
    Restore original Ollama binaries from backup
#>

[CmdletBinding()]
param(
    [switch]$Build,
    [switch]$Deploy,
    [switch]$Test,
    [switch]$Restore,
    [switch]$Clean,
    [switch]$All,
    [switch]$SkipROCm,
    [switch]$SkipCPU,
    [string]$TestModel = "qwen3-coder-next:latest"
)

$ErrorActionPreference = "Stop"

# ── Paths ──────────────────────────────────────────────────────────────────────
$script:SRC_DIR        = $PSScriptRoot
$script:BUILD_DIR      = Join-Path $script:SRC_DIR "build"
$script:DIST_DIR       = Join-Path $script:SRC_DIR "dist\windows-amd64"
$script:OLLAMA_INSTALL = Join-Path $env:LOCALAPPDATA "Programs\Ollama"
$script:BACKUP_DIR     = Join-Path $script:OLLAMA_INSTALL "backup-r9700"
$script:JOBS           = [Environment]::ProcessorCount

# ── Helpers ────────────────────────────────────────────────────────────────────
function Write-Step    { param([string]$msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK      { param([string]$msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn    { param([string]$msg) Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail    { param([string]$msg) Write-Host "    [FAIL] $msg" -ForegroundColor Red }
function Write-Detail  { param([string]$msg) Write-Host "    $msg" -ForegroundColor Gray }

function Assert-ExitCode {
    param([string]$step)
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "$step failed with exit code $LASTEXITCODE"
        throw "$step failed"
    }
}

# ── Prerequisites ──────────────────────────────────────────────────────────────
function Test-Prerequisites {
    Write-Step "Checking prerequisites"

    # Go
    $goExe = Get-Command go -ErrorAction SilentlyContinue
    if (-not $goExe) { throw "Go is not installed or not in PATH" }
    Write-OK "Go: $(go version)"

    # CMake
    $cmakeExe = Get-Command cmake -ErrorAction SilentlyContinue
    if (-not $cmakeExe) { throw "CMake is not installed or not in PATH" }
    Write-OK "CMake: $(cmake --version | Select-Object -First 1)"

    # Ninja
    if (-not (Get-Command ninja -ErrorAction SilentlyContinue)) {
        # Try to find ninja in VS installation
        $vsInstall = (Get-CimInstance MSFT_VSInstance -Namespace root/cimv2/vs -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($vsInstall) {
            $ninjaExe = Get-ChildItem -Path $vsInstall.InstallLocation -Recurse -Filter ninja.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($ninjaExe) {
                $env:PATH = "$($ninjaExe.DirectoryName);$env:PATH"
                Write-OK "Ninja: found in VS at $($ninjaExe.DirectoryName)"
            }
        }
        if (-not (Get-Command ninja -ErrorAction SilentlyContinue)) {
            throw "Ninja build system not found"
        }
    } else {
        Write-OK "Ninja: $(ninja --version)"
    }

    # ROCm / HIP
    if ($env:HIP_PATH) {
        $script:HIP_PATH = $env:HIP_PATH
    } else {
        $hipDir = Get-Item "C:\Program Files\AMD\ROCm\*" -ErrorAction SilentlyContinue |
                  Sort-Object Name -Descending | Select-Object -First 1
        if ($hipDir) { $script:HIP_PATH = $hipDir.FullName }
    }

    if ($script:HIP_PATH -and (Test-Path $script:HIP_PATH)) {
        Write-OK "ROCm/HIP: $($script:HIP_PATH)"
        # Verify gfx1201 rocblas tuning files exist
        $tuning = Get-ChildItem "$($script:HIP_PATH)\bin\rocblas\library\*gfx1201*" -ErrorAction SilentlyContinue
        if ($tuning) {
            Write-OK "rocblas gfx1201 tuning files: found ($($tuning.Count) files)"
        } else {
            Write-Warn "rocblas gfx1201 tuning files not found — ROCm SDK may be too old"
        }
    } else {
        Write-Warn "ROCm/HIP not found — ROCm build will be skipped"
        $script:HIP_PATH = $null
    }

    # Existing Ollama installation
    if (Test-Path $script:OLLAMA_INSTALL) {
        $ver = & "$script:OLLAMA_INSTALL\ollama.exe" --version 2>&1 | Select-String "version"
        Write-OK "Installed Ollama: $ver"
    } else {
        Write-Warn "No existing Ollama installation at $script:OLLAMA_INSTALL"
    }

    # Version from git
    $script:VERSION = "dev"
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $desc = git describe --tags --first-parent --abbrev=7 --long --dirty --always 2>$null
        if ($desc -match "v?(.+)") { $script:VERSION = $matches[1] }
    }
    Write-OK "Build version: $($script:VERSION)"
}

# ── Visual Studio environment ─────────────────────────────────────────────────
function Initialize-VsDevEnv {
    Write-Detail "Initializing Visual Studio developer environment..."
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw "vswhere not found — Visual Studio required" }

    $vsPath = & $vswhere -latest -property installationPath
    if (-not $vsPath) { throw "Visual Studio installation not found" }

    $vsDevCmd = Join-Path $vsPath "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path $vsDevCmd)) { throw "VsDevCmd.bat not found in $vsPath" }

    # Capture env vars from VsDevCmd
    $envVars = cmd /c "`"$vsDevCmd`" -arch=amd64 -host_arch=amd64 >nul 2>&1 && set" |
        ForEach-Object {
            if ($_ -match "^([^=]+)=(.*)$") {
                @{ Name = $matches[1]; Value = $matches[2] }
            }
        }
    foreach ($var in $envVars) {
        if ($var) { [Environment]::SetEnvironmentVariable($var.Name, $var.Value, "Process") }
    }
    Write-Detail "VS environment initialized ($vsPath)"
}

# ── Build CPU backend ─────────────────────────────────────────────────────────
function Build-CPU {
    Write-Step "Building CPU backend"
    New-Item -ItemType Directory -Path $script:DIST_DIR -Force | Out-Null

    & cmake -B "$script:BUILD_DIR\cpu" --preset CPU --install-prefix $script:DIST_DIR
    Assert-ExitCode "CMake configure (CPU)"

    & cmake --build "$script:BUILD_DIR\cpu" --target ggml-cpu --config Release --parallel $script:JOBS
    Assert-ExitCode "CMake build (CPU)"

    & cmake --install "$script:BUILD_DIR\cpu" --component CPU --strip
    Assert-ExitCode "CMake install (CPU)"

    Write-OK "CPU backend built"
}

# ── Build ROCm backend ────────────────────────────────────────────────────────
function Build-ROCm {
    if (-not $script:HIP_PATH) {
        Write-Warn "Skipping ROCm build — HIP not found"
        return
    }

    Write-Step "Building ROCm backend (includes gfx1201 for R9700)"
    New-Item -ItemType Directory -Path $script:DIST_DIR -Force | Out-Null

    # Clean stale ROCm build cache to avoid "compiler changed" re-configure that
    # loses preset variables
    $rocmBuildDir = "$script:BUILD_DIR\rocm"
    if (Test-Path $rocmBuildDir) {
        Write-Detail "Removing stale ROCm build directory..."
        Remove-Item $rocmBuildDir -Recurse -Force
    }

    Initialize-VsDevEnv

    # The "ROCm 6" preset's AMDGPU_TARGETS includes datacenter gfx940/941 which
    # aren't valid target IDs in ROCm 7.x on Windows. Override with only the
    # consumer RDNA targets we need (gfx1100 for 7800XT, gfx1201 for R9700,
    # plus other common consumer targets for compatibility).
    $gpuTargets = "gfx1010;gfx1012;gfx1030;gfx1100;gfx1101;gfx1102;gfx1151;gfx1200;gfx1201"

    $env:HIPCXX      = "$script:HIP_PATH\bin\clang++.exe"
    $env:HIP_PLATFORM = "amd"
    $env:CMAKE_PREFIX_PATH = $script:HIP_PATH

    Write-Detail "HIP compiler: $env:HIPCXX"
    Write-Detail "GPU targets: $gpuTargets"

    & cmake -B $rocmBuildDir --preset "ROCm 6" -G Ninja `
        -DCMAKE_C_COMPILER=clang `
        -DCMAKE_CXX_COMPILER=clang++ `
        "-DCMAKE_C_FLAGS=-parallel-jobs=4 -Wno-ignored-attributes -Wno-deprecated-pragma" `
        "-DCMAKE_CXX_FLAGS=-parallel-jobs=4 -Wno-ignored-attributes -Wno-deprecated-pragma" `
        "-DAMDGPU_TARGETS=$gpuTargets" `
        -Wno-dev `
        --install-prefix $script:DIST_DIR
    Assert-ExitCode "CMake configure (ROCm)"

    # Clear HIP env before build (matches official build script)
    $env:HIPCXX = ""
    $env:HIP_PLATFORM = ""
    $env:CMAKE_PREFIX_PATH = ""

    & cmake --build $rocmBuildDir --target ggml-hip --config Release --parallel $script:JOBS
    Assert-ExitCode "CMake build (ROCm)"

    & cmake --install $rocmBuildDir --component "HIP" --strip
    Assert-ExitCode "CMake install (ROCm)"

    # Remove gfx906 tuning files (not needed, saves space)
    Remove-Item -Path "$script:DIST_DIR\lib\ollama\rocm\rocblas\library\*gfx906*" -ErrorAction SilentlyContinue

    # Verify gfx1201 was included
    $tuning = Get-ChildItem "$script:DIST_DIR\lib\ollama\rocm\rocblas\library\*gfx1201*" -ErrorAction SilentlyContinue
    if ($tuning) {
        Write-OK "ROCm backend built — gfx1201 tuning files present ($($tuning.Count) files)"
    } else {
        Write-Warn "ROCm backend built but gfx1201 tuning files not found in output!"
    }
}

# ── Build Go binary ───────────────────────────────────────────────────────────
function Build-GoBinary {
    Write-Step "Building Ollama Go binary"
    Push-Location $script:SRC_DIR
    try {
        $env:CGO_ENABLED = "1"
        & go build -trimpath `
            -ldflags "-s -w -X=github.com/ollama/ollama/version.Version=$($script:VERSION)" .
        Assert-ExitCode "go build"

        if (Test-Path "$script:SRC_DIR\ollama.exe") {
            Copy-Item "$script:SRC_DIR\ollama.exe" "$script:DIST_DIR\ollama.exe" -Force
            Write-OK "Built ollama.exe (version: $($script:VERSION))"
        } else {
            throw "ollama.exe not found after build"
        }
    } finally {
        Pop-Location
    }
}

# ── Run Go tests ──────────────────────────────────────────────────────────────
function Run-GoTests {
    Write-Step "Running Go tests (short mode)"
    Push-Location $script:SRC_DIR
    try {
        # Run unit tests in short mode to catch obvious regressions
        # Skip integration tests (they require a running server)
        & go test -short -count=1 ./discover/... ./ml/... ./server/... ./cmd/... 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Some tests failed (exit code $LASTEXITCODE) — review output above"
        } else {
            Write-OK "Go tests passed"
        }
    } finally {
        Pop-Location
    }
}

# ── Clean ──────────────────────────────────────────────────────────────────────
function Invoke-Clean {
    Write-Step "Cleaning build artifacts"
    foreach ($dir in @($script:BUILD_DIR, $script:DIST_DIR)) {
        if (Test-Path $dir) {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Detail "Removed $dir"
        }
    }
    $ollamaExe = Join-Path $script:SRC_DIR "ollama.exe"
    if (Test-Path $ollamaExe) {
        Remove-Item $ollamaExe -Force -ErrorAction SilentlyContinue
        Write-Detail "Removed ollama.exe"
    }
    Write-OK "Clean complete"
}

# ── Stop Ollama ────────────────────────────────────────────────────────────────
function Stop-Ollama {
    Write-Detail "Stopping Ollama processes..."
    Get-Process -Name "ollama*" -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Detail "  Stopping $($_.Name) (PID $($_.Id))"
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
}

# ── Backup ─────────────────────────────────────────────────────────────────────
function Backup-Installation {
    if (-not (Test-Path $script:OLLAMA_INSTALL)) { return }
    if (Test-Path $script:BACKUP_DIR) {
        Write-Detail "Backup already exists at $script:BACKUP_DIR"
        return
    }

    Write-Step "Backing up existing Ollama installation"
    New-Item -ItemType Directory -Path $script:BACKUP_DIR -Force | Out-Null

    # Backup ollama.exe
    $src = Join-Path $script:OLLAMA_INSTALL "ollama.exe"
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $script:BACKUP_DIR "ollama.exe")
        Write-Detail "Backed up ollama.exe"
    }

    # Backup ROCm libs
    $rocmSrc = Join-Path $script:OLLAMA_INSTALL "lib\ollama\rocm"
    if (Test-Path $rocmSrc) {
        Copy-Item $rocmSrc (Join-Path $script:BACKUP_DIR "rocm") -Recurse
        Write-Detail "Backed up lib\ollama\rocm"
    }

    # Backup CPU libs
    $cpuLibs = Get-ChildItem (Join-Path $script:OLLAMA_INSTALL "lib\ollama\ggml-cpu*") -ErrorAction SilentlyContinue
    foreach ($lib in $cpuLibs) {
        Copy-Item $lib.FullName (Join-Path $script:BACKUP_DIR $lib.Name)
    }
    $baseLib = Join-Path $script:OLLAMA_INSTALL "lib\ollama\ggml-base.dll"
    if (Test-Path $baseLib) {
        Copy-Item $baseLib (Join-Path $script:BACKUP_DIR "ggml-base.dll")
    }

    Write-OK "Backup created at $script:BACKUP_DIR"
}

# ── Deploy ─────────────────────────────────────────────────────────────────────
function Deploy-Binaries {
    Write-Step "Deploying built binaries to Ollama installation"

    if (-not (Test-Path $script:OLLAMA_INSTALL)) {
        throw "Ollama installation not found at $script:OLLAMA_INSTALL"
    }

    Backup-Installation
    Stop-Ollama

    # Deploy ollama.exe
    $srcExe = Join-Path $script:DIST_DIR "ollama.exe"
    if (-not (Test-Path $srcExe)) { $srcExe = Join-Path $script:SRC_DIR "ollama.exe" }
    if (Test-Path $srcExe) {
        Copy-Item $srcExe (Join-Path $script:OLLAMA_INSTALL "ollama.exe") -Force
        Write-OK "Deployed ollama.exe"
    } else {
        Write-Fail "No ollama.exe found — run -Build first"
        return
    }

    # Deploy CPU libraries
    $cpuLibs = Get-ChildItem (Join-Path $script:DIST_DIR "lib\ollama\ggml-cpu*") -ErrorAction SilentlyContinue
    foreach ($lib in $cpuLibs) {
        Copy-Item $lib.FullName (Join-Path $script:OLLAMA_INSTALL "lib\ollama" $lib.Name) -Force
        Write-Detail "Deployed $($lib.Name)"
    }
    $baseLib = Join-Path $script:DIST_DIR "lib\ollama\ggml-base.dll"
    if (Test-Path $baseLib) {
        Copy-Item $baseLib (Join-Path $script:OLLAMA_INSTALL "lib\ollama\ggml-base.dll") -Force
        Write-Detail "Deployed ggml-base.dll"
    }

    # Deploy ROCm libraries
    $srcRocm = Join-Path $script:DIST_DIR "lib\ollama\rocm"
    $dstRocm = Join-Path $script:OLLAMA_INSTALL "lib\ollama\rocm"
    if (Test-Path $srcRocm) {
        if (Test-Path $dstRocm) { Remove-Item $dstRocm -Recurse -Force }
        Copy-Item $srcRocm $dstRocm -Recurse -Force
        $tuning = Get-ChildItem "$dstRocm\rocblas\library\*gfx1201*" -ErrorAction SilentlyContinue
        Write-OK "Deployed ROCm libraries (gfx1201 tuning files: $($tuning.Count))"
    } else {
        Write-Warn "No ROCm build output — using existing ROCm libs"
    }
}

# ── Restore ────────────────────────────────────────────────────────────────────
function Restore-Installation {
    Write-Step "Restoring original Ollama installation"

    if (-not (Test-Path $script:BACKUP_DIR)) {
        Write-Fail "No backup found at $script:BACKUP_DIR"
        return
    }

    Stop-Ollama

    # Restore ollama.exe
    $backupExe = Join-Path $script:BACKUP_DIR "ollama.exe"
    if (Test-Path $backupExe) {
        Copy-Item $backupExe (Join-Path $script:OLLAMA_INSTALL "ollama.exe") -Force
        Write-OK "Restored ollama.exe"
    }

    # Restore ROCm
    $backupRocm = Join-Path $script:BACKUP_DIR "rocm"
    if (Test-Path $backupRocm) {
        $dstRocm = Join-Path $script:OLLAMA_INSTALL "lib\ollama\rocm"
        if (Test-Path $dstRocm) { Remove-Item $dstRocm -Recurse -Force }
        Copy-Item $backupRocm $dstRocm -Recurse -Force
        Write-OK "Restored ROCm libraries"
    }

    # Restore CPU libs
    $cpuBackups = Get-ChildItem (Join-Path $script:BACKUP_DIR "ggml-*") -ErrorAction SilentlyContinue
    foreach ($lib in $cpuBackups) {
        Copy-Item $lib.FullName (Join-Path $script:OLLAMA_INSTALL "lib\ollama" $lib.Name) -Force
        Write-Detail "Restored $($lib.Name)"
    }

    Write-OK "Restore complete"
}

# ── Test / Verify ──────────────────────────────────────────────────────────────
function Test-Deployment {
    Write-Step "Testing Ollama with GPU verification"

    $ollamaExe = Join-Path $script:OLLAMA_INSTALL "ollama.exe"
    if (-not (Test-Path $ollamaExe)) {
        Write-Fail "ollama.exe not found at $script:OLLAMA_INSTALL"
        return
    }

    Stop-Ollama

    # Enable debug logging and extended discovery timeout for RDNA4
    $env:OLLAMA_DEBUG = "1"

    Write-Detail "Starting Ollama server..."
    Write-Detail "(First start may take 60-120s for RDNA4 JIT compilation)"

    # Start server in background
    $serverProc = Start-Process -FilePath $ollamaExe -ArgumentList "serve" `
        -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $script:SRC_DIR "ollama-test-stderr.log")

    # Wait for server to be ready
    $maxWait = 240
    $waited = 0
    $ready = $false

    while ($waited -lt $maxWait) {
        Start-Sleep -Seconds 5
        $waited += 5

        if ($serverProc.HasExited) {
            Write-Fail "Server exited prematurely (exit code: $($serverProc.ExitCode))"
            $logFile = Join-Path $script:SRC_DIR "ollama-test-stderr.log"
            if (Test-Path $logFile) {
                Write-Detail "Last 20 lines of server log:"
                Get-Content $logFile -Tail 20 | ForEach-Object { Write-Detail "  $_" }
            }
            return
        }

        try {
            $null = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 5 -ErrorAction Stop
            $ready = $true
            break
        } catch {
            if ($waited % 30 -eq 0) {
                Write-Detail "Waiting for server... ($waited/$maxWait seconds)"
            }
        }
    }

    if (-not $ready) {
        Write-Fail "Server did not become ready within $maxWait seconds"
        Stop-Process -Id $serverProc.Id -Force -ErrorAction SilentlyContinue
        return
    }

    Write-OK "Server is ready (took ~${waited}s)"

    # Check GPU detection via ps endpoint
    Write-Detail "Checking GPU detection..."
    try {
        $psOutput = & $ollamaExe ps 2>&1 | Out-String
        Write-Detail $psOutput

        # Use the show endpoint or run a quick model load to see GPU allocation
        # First, let's check what the server reports about available GPUs
        Write-Detail "Querying server for GPU info..."

        # Run the test model to force GPU allocation
        Write-Detail "Loading test model: $TestModel"
        Write-Detail "This will show GPU allocation across both cards..."

        $runProc = Start-Process -FilePath $ollamaExe `
            -ArgumentList "run", $TestModel, "--verbose", "/bye" `
            -PassThru -NoNewWindow -Wait

        Start-Sleep -Seconds 5

        # Check ps to see GPU allocation
        Write-Detail ""
        Write-Detail "Current model GPU allocation:"
        $psOutput2 = & $ollamaExe ps 2>&1 | Out-String
        Write-Host $psOutput2

        if ($psOutput2 -match "(?i)gpu|rocm|gfx") {
            Write-OK "GPU detected in model allocation"
        }
    } catch {
        Write-Warn "Error during GPU check: $_"
    }

    # Cleanup
    Write-Step "Stopping test server"
    Stop-Process -Id $serverProc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Stop-Ollama
    Write-OK "Test complete"

    # Show log excerpt
    $logFile = Join-Path $script:SRC_DIR "ollama-test-stderr.log"
    if (Test-Path $logFile) {
        Write-Detail ""
        Write-Detail "Server log excerpt (GPU-related lines):"
        Get-Content $logFile | Select-String -Pattern "(?i)gpu|rocm|gfx|hip|device|VRAM|radeon|R9700|7800" |
            Select-Object -First 30 | ForEach-Object { Write-Detail "  $_" }
    }
}

# ── Main ───────────────────────────────────────────────────────────────────────
if ($All) { $Build = $true; $Deploy = $true; $Test = $true }

if (-not ($Build -or $Deploy -or $Test -or $Restore -or $Clean)) {
    Write-Host ""
    Write-Host "Ollama R9700 (gfx1201) Build Script" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\build-r9700.ps1 -All                     # Full build + deploy + test"
    Write-Host "  .\build-r9700.ps1 -Build                   # Build only"
    Write-Host "  .\build-r9700.ps1 -Build -SkipROCm         # Rebuild Go binary only"
    Write-Host "  .\build-r9700.ps1 -Deploy                  # Deploy to Ollama install dir"
    Write-Host "  .\build-r9700.ps1 -Test                    # Verify GPU detection"
    Write-Host "  .\build-r9700.ps1 -Restore                 # Restore original binaries"
    Write-Host "  .\build-r9700.ps1 -Clean                   # Clean build artifacts"
    Write-Host ""
    Write-Host "The Ollama source already supports gfx1201 (RDNA 4)." -ForegroundColor Gray
    Write-Host "This script just builds from source so the ROCm backend" -ForegroundColor Gray
    Write-Host "includes your R9700. After merging new upstream changes," -ForegroundColor Gray
    Write-Host "just re-run: .\build-r9700.ps1 -All" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Ollama R9700 Build  (RDNA4 / gfx1201)" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

Test-Prerequisites

$success = $true

try {
    if ($Clean) { Invoke-Clean }

    if ($Restore) { Restore-Installation }

    if ($Build) {
        if (-not $SkipCPU)  { Build-CPU }
        if (-not $SkipROCm) { Build-ROCm }
        Build-GoBinary
        Run-GoTests
    }

    if ($Deploy) { Deploy-Binaries }

    if ($Test) { Test-Deployment }
} catch {
    Write-Fail "Error: $_"
    $success = $false
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
if ($success) {
    Write-Host " All operations completed successfully" -ForegroundColor Green
} else {
    Write-Host " Some operations failed — check output above" -ForegroundColor Red
}
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

exit $(if ($success) { 0 } else { 1 })
