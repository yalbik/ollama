<#
.SYNOPSIS
    Cold-prefill benchmark for Ollama models across context window sizes.
.DESCRIPTION
    Sends large prompts at 4K/16K/32K/64K/128K/256K context windows and measures
    cold prompt-eval throughput. Each run uses a unique prompt to defeat KV cache.
    Prompt size is scaled to ~80% of each context window.
.PARAMETER Model
    Ollama model tag to benchmark (default: qwen3-coder-next:latest).
.PARAMETER OllamaUrl
    Base URL of the Ollama server (default: http://localhost:11434).
.PARAMETER ContextSizes
    Array of context window sizes to test.
.EXAMPLE
    .\test-prefill.ps1
    .\test-prefill.ps1 -Model "llama3:8b" -ContextSizes 4096,32768,131072
#>
param(
    [string]$Model = "qwen3-coder-next:latest",
    [string]$OllamaUrl = "http://localhost:11434",
    [int[]]$ContextSizes = @(4096, 16384, 32768, 65536, 131072, 262144)
)

$ErrorActionPreference = "Stop"

# Enable ANSI/VT escape processing on Windows (needed for PS 5.x terminals)
if ($PSVersionTable.PSVersion.Major -le 5) {
    $vt = Add-Type -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -Name VT -Namespace Win32 -PassThru -ErrorAction SilentlyContinue
    if ($vt) {
        $h = $vt::GetStdHandle(-11)  # STD_OUTPUT_HANDLE
        $mode = 0
        $null = $vt::GetConsoleMode($h, [ref]$mode)
        $null = $vt::SetConsoleMode($h, $mode -bor 4)  # ENABLE_VIRTUAL_TERMINAL_PROCESSING
    }
}

# ── ANSI color codes ────────────────────────────────────────────────────────────

$E  = [char]0x1b  # ESC - works in PS 5.1+
$C  = "$E[36m"   # cyan
$G  = "$E[32m"   # green
$Y  = "$E[33m"   # yellow
$R  = "$E[31m"   # red
$B  = "$E[1m"    # bold
$D  = "$E[2m"    # dim
$X  = "$E[0m"    # reset
$M  = "$E[35m"   # magenta
$W  = "$E[97m"   # white

# ── Formatting helpers ──────────────────────────────────────────────────────────

function Format-Ctx([int]$n) {
    if ($n -ge 1048576) { return "{0}M" -f [math]::Round($n / 1048576, 1) }
    if ($n -ge 1024)    { return "{0}K" -f [math]::Round($n / 1024) }
    return "$n"
}

function Format-Duration([double]$seconds) {
    if ($seconds -ge 60) {
        $m = [math]::Floor($seconds / 60)
        $s = $seconds - ($m * 60)
        return "{0}m {1:F1}s" -f $m, $s
    }
    return "{0:F2}s" -f $seconds
}

function Format-Bytes([double]$bytes) {
    if ($bytes -ge 1GB) { return "{0:F1} GiB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:F0} MiB" -f ($bytes / 1MB) }
    return "{0:F0} KiB" -f ($bytes / 1KB)
}

# ── Display helpers (ASCII-safe box drawing) ────────────────────────────────────

function Write-Banner([string]$text) {
    $bar = "-" * 78
    Write-Host ""
    Write-Host "$C+$bar+$X"
    $pad = 78 - $text.Length
    $left = [math]::Floor($pad / 2)
    $right = $pad - $left
    Write-Host "$C|$X$B$(' ' * $left)$text$(' ' * $right)$X$C|$X"
    Write-Host "$C+$bar+$X"
}

function Write-Section([string]$icon, [string]$text) {
    Write-Host ""
    Write-Host "  $Y$icon$X  $B$text$X"
    Write-Host "  $D$('-' * 72)$X"
}

function Write-Status([string]$icon, [string]$text) {
    Write-Host "     $icon  $text"
}

function Write-Kv([string]$key, [string]$val) {
    $padded = $key.PadRight(18)
    Write-Host "     $D$padded$X $val"
}

# ── Prompt generation ───────────────────────────────────────────────────────────
# Generates a unique prompt scaled to ~80% of the target context window.
# Each code block is ~80 tokens. Preamble is ~100 tokens.

$script:RunCounter = 0

function New-LargePrompt([int]$TargetTokens) {
    $script:RunCounter++
    $stamp = "RUN-{0:D4}-{1:yyyyMMdd-HHmmss-fff}" -f $script:RunCounter, (Get-Date)

    $preamble = @"
[$stamp] You are a senior software architect performing a comprehensive code review.
Analyze every function, class, and module below for correctness, performance,
security vulnerabilities, and adherence to SOLID principles. Consider edge cases,
error handling, concurrency issues, and memory management.
After your analysis, RESPOND WITH ONLY 1 WORD summarizing the overall code quality.
"@

    # Each code block is ~80 tokens according to typical BPE tokenizers.
    $codeBlock = @"

// [$stamp] Module: UserService (revision $($script:RunCounter))
import { EventEmitter } from 'events';
import { createHash, randomBytes } from 'crypto';
import { Pool, PoolClient } from 'pg';

interface User {
  id: string; name: string; email: string; role: 'admin' | 'user' | 'viewer';
  createdAt: Date; passwordHash: string; salt: string; lastLogin: Date | null;
  metadata: Record<string, unknown>; isActive: boolean; tokenVersion: number;
}

class UserService extends EventEmitter {
  private pool: Pool;
  private cache = new Map<string, { user: User; expires: number }>();
  constructor(pool: Pool) { super(); this.pool = pool; }

  async findById(id: string): Promise<User | null> {
    const cached = this.cache.get(id);
    if (cached && cached.expires > Date.now()) return cached.user;
    const client = await this.pool.connect();
    try {
      const { rows } = await client.query('SELECT * FROM users WHERE id = `$1', [id]);
      if (!rows.length) return null;
      this.cache.set(id, { user: rows[0], expires: Date.now() + 30000 });
      return rows[0];
    } finally { client.release(); }
  }

  async authenticate(email: string, password: string): Promise<string | null> {
    const client = await this.pool.connect();
    try {
      const { rows } = await client.query('SELECT * FROM users WHERE email = `$1', [email]);
      if (!rows.length) return null;
      const user = rows[0] as User;
      const hash = createHash('sha256').update(password + user.salt).digest('hex');
      if (hash !== user.passwordHash) { this.emit('auth:failed', email); return null; }
      const token = randomBytes(32).toString('hex');
      await client.query('UPDATE users SET last_login = NOW(), token_version = token_version + 1 WHERE id = `$1', [user.id]);
      this.cache.delete(user.id);
      this.emit('auth:success', user.id);
      return token;
    } finally { client.release(); }
  }

  async bulkUpdate(updates: Partial<User>[]): Promise<number> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      let count = 0;
      for (const u of updates) {
        const result = await client.query(
          'UPDATE users SET name = COALESCE(`$1,name), role = COALESCE(`$2,role) WHERE id = `$3',
          [u.name, u.role, u.id]
        );
        count += result.rowCount ?? 0;
        if (u.id) this.cache.delete(u.id);
      }
      await client.query('COMMIT');
      this.emit('users:bulk-updated', count);
      return count;
    } catch (e) { await client.query('ROLLBACK'); throw e; } finally { client.release(); }
  }
}
"@

    # Estimate tokens from character count (~4 chars per token for code)
    $charsPerToken = 4
    $preambleTokens = [math]::Ceiling($preamble.Length / $charsPerToken)
    $tokensPerBlock = [math]::Max(1, [math]::Ceiling($codeBlock.Length / $charsPerToken))
    $blockCount = [math]::Max(1, [math]::Ceiling(($TargetTokens - $preambleTokens) / $tokensPerBlock))
    $blocks = 1..$blockCount | ForEach-Object { $codeBlock -replace 'revision \d+', "revision $_-$($script:RunCounter)" }
    return $preamble + "`n" + ($blocks -join "`n")
}

# ── Server info helpers ─────────────────────────────────────────────────────────

function Get-ServerInfo {
    try {
        $tags = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 5
        $modelInfo = $tags.models | Where-Object {
            $_.name -eq $Model -or
            $_.name -eq ($Model -replace ':latest$','') -or
            "$($_.name):latest" -eq $Model
        }
        return $modelInfo
    } catch {
        return $null
    }
}

function Get-GpuLayers {
    $logPath = Join-Path $env:LOCALAPPDATA "Ollama\server.log"
    if (-not (Test-Path $logPath)) { return $null }
    $lines = Get-Content $logPath -Tail 200 -ErrorAction SilentlyContinue

    # Parse GPU names from "inference compute" lines: id=0 ... description="AMD Radeon AI PRO R9700"
    $gpuNames = @{}
    foreach ($line in $lines) {
        if ($line -match 'inference compute.*id=(\d+).*description="([^"]+)"') {
            $gpuNames[[int]$Matches[1]] = $Matches[2]
        }
    }

    # Find the most recent Operation:commit (or Operation:alloc) load request line
    # Format: GPULayers:43[ID:0 Layers:29(5..33) ID:1 Layers:14(34..47)]
    $perGpu = @()
    $totalOffloaded = 0
    $totalLayers = 0
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match 'Operation:(commit|alloc).*GPULayers:(\d+)\[([^\]]+)\]') {
            $totalOffloaded = [int]$Matches[2]
            $detail = $Matches[3]
            # Parse each "ID:N Layers:M(start..end)" segment
            $segments = [regex]::Matches($detail, 'ID:(\d+)\s+Layers:(\d+)\((\d+)\.\.(\d+)\)')
            foreach ($seg in $segments) {
                $gpuId = [int]$seg.Groups[1].Value
                $layerCount = [int]$seg.Groups[2].Value
                $rangeStart = [int]$seg.Groups[3].Value
                $rangeEnd = [int]$seg.Groups[4].Value
                $name = if ($gpuNames.ContainsKey($gpuId)) { $gpuNames[$gpuId] } else { "GPU $gpuId" }
                $perGpu += @{
                    Id = $gpuId; Name = $name; Layers = $layerCount
                    RangeStart = $rangeStart; RangeEnd = $rangeEnd
                }
            }
            break
        }
    }

    # Get total model layers from "offloaded N/M layers" line
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match 'offloaded\s+(\d+)/(\d+)\s+layers') {
            $totalOffloaded = [int]$Matches[1]
            $totalLayers = [int]$Matches[2]
            break
        }
    }

    if ($totalLayers -eq 0) { return $null }
    return @{ Offloaded = $totalOffloaded; Total = $totalLayers; PerGpu = $perGpu; GpuNames = $gpuNames }
}

function Get-KvAllocation {
    $logPath = Join-Path $env:LOCALAPPDATA "Ollama\server.log"
    if (-not (Test-Path $logPath)) { return @() }
    $lines = Get-Content $logPath -Tail 30 -ErrorAction SilentlyContinue
    $results = @()
    foreach ($line in $lines) {
        if ($line -match 'kv cache.*device=(\S+)\s+size="([^"]+)"') {
            $results += @{ Device = $Matches[1]; Size = $Matches[2] }
        }
    }
    return $results
}

# ── Core benchmark ──────────────────────────────────────────────────────────────

function Invoke-PrefillTest([int]$ctxSize) {
    $ctxLabel = Format-Ctx $ctxSize

    Write-Section ">" "Testing $B${ctxLabel}$X context window (num_ctx=$ctxSize)"

    # Step 1: Generate unique prompt scaled to ~80% of context window
    $targetTokens = [math]::Floor($ctxSize * 0.80)
    $pctLabel = "80 pct"
    Write-Status ".." "${D}Generating unique prompt targeting ~$($targetTokens.ToString('N0')) tokens ($pctLabel of $ctxLabel)...$X"
    $prompt = New-LargePrompt -TargetTokens $targetTokens
    $promptChars = $prompt.Length
    $estTokens = [math]::Round($promptChars / 4)
    Write-Status "ok" "${G}Prompt ready$X  $C$($promptChars.ToString('N0'))$X chars (~$C$($estTokens.ToString('N0'))$X est. tokens | target $C$($targetTokens.ToString('N0'))$X)"

    # Step 3: Send request
    Write-Status ">>" "${B}Sending prefill request...$X  ${D}num_ctx=$ctxSize  num_predict=1$X"
    $wallSw = [System.Diagnostics.Stopwatch]::StartNew()

    $body = @{
        model   = $Model
        prompt  = $prompt
        stream  = $false
        options = @{
            num_ctx     = $ctxSize
            num_predict = 1
        }
    } | ConvertTo-Json

    try {
        $r = Invoke-RestMethod -Uri "$OllamaUrl/api/generate" -Method Post `
            -Body $body -ContentType "application/json" -TimeoutSec 600
        $wallSw.Stop()
    } catch {
        $wallSw.Stop()
        Write-Status "!!" "${R}Request failed: $($_.Exception.Message)$X"
        return @{
            Context      = $ctxSize
            ContextLabel = $ctxLabel
            Error        = $_.Exception.Message
        }
    }

    # Step 4: Parse results
    $promptTok   = $r.prompt_eval_count
    $promptNs    = $r.prompt_eval_duration
    $prefillSec  = $promptNs / 1e9
    $prefillTokS = if ($prefillSec -gt 0) { $promptTok / $prefillSec } else { 0 }
    $loadSec     = $r.load_duration / 1e9
    $wallSec     = $wallSw.ElapsedMilliseconds / 1000
    $totalSec    = $r.total_duration / 1e9

    # Step 5: Read layer/KV info from server logs
    $layers = Get-GpuLayers
    $kvInfo = Get-KvAllocation

    # Step 6: Display results
    Write-Host ""
    $bar = "=" * 60
    Write-Host "     $G$bar$X"
    Write-Host "     $G${B}  PREFILL: ${W}$("{0:F1}" -f $prefillTokS) tok/s$X  ${D}($promptTok tokens in $(Format-Duration $prefillSec))$X"
    Write-Host "     $G$bar$X"

    Write-Kv "Prompt tokens" "$C$($promptTok.ToString('N0'))$X"
    Write-Kv "Prefill time" (Format-Duration $prefillSec)
    Write-Kv "Model load" (Format-Duration $loadSec)
    Write-Kv "Wall clock" (Format-Duration $wallSec)
    Write-Kv "Total (server)" (Format-Duration $totalSec)

    if ($layers) {
        $lc = if ($layers.Offloaded -eq $layers.Total) { $G } else { $Y }
        $cpuCount = $layers.Total - $layers.Offloaded
        Write-Kv "GPU layers" "$lc$($layers.Offloaded)/$($layers.Total)$X offloaded ${D}($cpuCount on CPU)$X"
        if ($layers.PerGpu -and $layers.PerGpu.Count -gt 0) {
            foreach ($gpu in $layers.PerGpu) {
                $gpuLabel = $gpu.Name
                $range = "layers $($gpu.RangeStart)..$($gpu.RangeEnd)"
                Write-Kv "  GPU $($gpu.Id)" "$C$($gpu.Layers)$X layers  ${D}($range)$X  $M$gpuLabel$X"
            }
            if ($cpuCount -gt 0) {
                Write-Kv "  CPU" "$Y${cpuCount}$X layers  ${D}(not offloaded)$X"
            }
        }
    }

    if ($kvInfo.Count -gt 0) {
        $kvStr = ($kvInfo | ForEach-Object { "$($_.Device)=$($_.Size)" }) -join "  "
        Write-Kv "KV cache" $kvStr
    }

    return @{
        Context      = $ctxSize
        ContextLabel = $ctxLabel
        PromptTokens = $promptTok
        PrefillTokS  = [math]::Round($prefillTokS, 1)
        PrefillSec   = [math]::Round($prefillSec, 2)
        LoadSec      = [math]::Round($loadSec, 2)
        WallSec      = [math]::Round($wallSec, 2)
        GpuLayers    = if ($layers) { "$($layers.Offloaded)/$($layers.Total)" } else { "?" }
        Error        = $null
    }
}

# ============================================================================
#  MAIN
# ============================================================================

$scriptStart = Get-Date

Write-Banner "OLLAMA COLD PREFILL BENCHMARK"

# ── Pre-flight checks ──
Write-Section "#" "Pre-flight checks"

# Server reachable?
Write-Status ".." "${D}Checking Ollama server at $OllamaUrl...$X"
try {
    $ver = Invoke-RestMethod -Uri "$OllamaUrl/api/version" -TimeoutSec 5
    Write-Status "ok" "${G}Server online$X  version $C$($ver.version)$X"
} catch {
    Write-Status "!!" "${R}Cannot reach Ollama at $OllamaUrl$X"
    Write-Host "     Make sure Ollama is running: ${B}ollama serve$X"
    exit 1
}

# Model available?
Write-Status ".." "${D}Looking for model $Model...$X"
$modelInfo = Get-ServerInfo
$maxCtx = 0
if ($modelInfo) {
    Write-Status "ok" "${G}Found$X ${B}$($modelInfo.name)$X"
    Write-Kv "Size" (Format-Bytes $modelInfo.size)
    Write-Kv "Quantization" $modelInfo.details.quantization_level
    Write-Kv "Family" "$($modelInfo.details.family) ($($modelInfo.details.parameter_size))"

    # Get model's max context length from /api/show
    try {
        $showInfo = Invoke-RestMethod -Uri "$OllamaUrl/api/show" -Method Post -Body (@{ model = $Model } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 10
        $ctxProp = $showInfo.model_info.PSObject.Properties | Where-Object { $_.Name -match 'context_length' } | Select-Object -First 1
        if ($ctxProp) { $maxCtx = [int]$ctxProp.Value }
    } catch { }
    if ($maxCtx -gt 0) {
        Write-Kv "Max context" "$C$(Format-Ctx $maxCtx)$X ${D}($($maxCtx.ToString('N0')) tokens)$X"
    }
} else {
    Write-Status "??" "${Y}Model '$Model' not found in tag list - will try anyway$X"
}

# Filter out context sizes that exceed the model's max
if ($maxCtx -gt 0) {
    $originalCount = $ContextSizes.Count
    $ContextSizes = @($ContextSizes | Where-Object { $_ -le $maxCtx })
    $skipped = $originalCount - $ContextSizes.Count
    if ($skipped -gt 0) {
        Write-Status "--" "${Y}Skipping $skipped context size(s) exceeding model max of $(Format-Ctx $maxCtx)$X"
    }
    if ($ContextSizes.Count -eq 0) {
        Write-Status "!!" "${R}No context sizes within model limit of $(Format-Ctx $maxCtx)$X"
        exit 1
    }
}

# Environment
Write-Status ">>" "Environment"
$faVal = if ($env:OLLAMA_FLASH_ATTENTION) { $env:OLLAMA_FLASH_ATTENTION } else { "${D}(not set)$X" }
$kvVal = if ($env:OLLAMA_KV_CACHE_TYPE)   { $env:OLLAMA_KV_CACHE_TYPE }   else { "${D}(not set)$X" }
Write-Kv "Flash Attention" $faVal
Write-Kv "KV Cache Type" $kvVal
Write-Kv "Context sizes" (($ContextSizes | ForEach-Object { Format-Ctx $_ }) -join ", ")
Write-Kv "Timestamp" (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

# ── Run benchmarks ──
Write-Section "!!" "Running cold prefill benchmarks"

$results = @()
$testCount = $ContextSizes.Count
$testNum = 0

foreach ($ctx in $ContextSizes) {
    $testNum++
    $ctxLabel = Format-Ctx $ctx
    Write-Host ""
    Write-Host "  $M[$testNum/$testCount]$X ${B}Context: $ctxLabel$X"

    $result = Invoke-PrefillTest $ctx
    $results += $result

    if ($testNum -lt $testCount) {
        Write-Host ""
    }
}

# ── Summary table ───────────────────────────────────────────────────────────────

Write-Banner "RESULTS SUMMARY"

Write-Host ""
$hdr = "  {0,-10} {1,10} {2,12} {3,12} {4,10} {5,12}" -f "Context", "Tokens", "Prefill", "tok/s", "Layers", "Load"
Write-Host "$B$W$hdr$X"
Write-Host "  $('-' * 72)"

foreach ($r in $results) {
    if ($r.Error) {
        Write-Host ("  {0,-10} ${R}ERROR: {1}$X" -f $r.ContextLabel, $r.Error)
        continue
    }
    $tc = if ($r.PrefillTokS -ge 200) { $G } elseif ($r.PrefillTokS -ge 100) { $C } else { $Y }
    $line = "  {0,-10} {1,10} {2,12} {3,12} {4,10} {5,12}" -f `
        $r.ContextLabel,
        $r.PromptTokens.ToString('N0'),
        (Format-Duration $r.PrefillSec),
        "$tc$($r.PrefillTokS) t/s$X",
        $r.GpuLayers,
        (Format-Duration $r.LoadSec)
    Write-Host $line
}
Write-Host "  $('-' * 72)"

$scriptEnd = Get-Date
$elapsed = $scriptEnd - $scriptStart
Write-Host ""
Write-Host "  ${D}Total benchmark time: $(Format-Duration $elapsed.TotalSeconds)$X"

# ── Find peak ──
$valid = @($results | Where-Object { -not $_.Error })
if ($valid.Count -gt 0) {
    $peak = $valid | Sort-Object { $_.PrefillTokS } -Descending | Select-Object -First 1
    Write-Host "  $G${B}Peak: $($peak.PrefillTokS) tok/s at $($peak.ContextLabel) context$X"
}

# ── Save to file ────────────────────────────────────────────────────────────────

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$safeModel = ($Model -replace '[:/\\]', '-') -replace '-+', '-'
$outFile = "prefill-bench-$safeModel-$timestamp.txt"

$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine("OLLAMA COLD PREFILL BENCHMARK")
$null = $sb.AppendLine("=" * 60)
$null = $sb.AppendLine("Date:             $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$null = $sb.AppendLine("Model:            $Model")
if ($modelInfo) {
    $null = $sb.AppendLine("Size:             $(Format-Bytes $modelInfo.size)")
    $null = $sb.AppendLine("Quantization:     $($modelInfo.details.quantization_level)")
    $null = $sb.AppendLine("Family:           $($modelInfo.details.family) ($($modelInfo.details.parameter_size))")
}
$faFile = if ($env:OLLAMA_FLASH_ATTENTION) { $env:OLLAMA_FLASH_ATTENTION } else { "not set" }
$kvFile = if ($env:OLLAMA_KV_CACHE_TYPE)   { $env:OLLAMA_KV_CACHE_TYPE }   else { "not set" }
$null = $sb.AppendLine("Flash Attention:  $faFile")
$null = $sb.AppendLine("KV Cache Type:    $kvFile")
$null = $sb.AppendLine("Ollama Version:   $($ver.version)")
$null = $sb.AppendLine("")
$null = $sb.AppendLine(("{0,-10} {1,10} {2,12} {3,12} {4,10} {5,12}" -f "Context", "Tokens", "Prefill", "tok/s", "Layers", "Load"))
$null = $sb.AppendLine("-" * 72)
foreach ($r in $results) {
    if ($r.Error) {
        $null = $sb.AppendLine(("{0,-10} ERROR: {1}" -f $r.ContextLabel, $r.Error))
    } else {
        $null = $sb.AppendLine(("{0,-10} {1,10} {2,12} {3,10} t/s {4,10} {5,12}" -f `
            $r.ContextLabel, $r.PromptTokens.ToString('N0'),
            (Format-Duration $r.PrefillSec), $r.PrefillTokS,
            $r.GpuLayers, (Format-Duration $r.LoadSec)))
    }
}
$null = $sb.AppendLine("-" * 72)
$null = $sb.AppendLine("Total time: $(Format-Duration $elapsed.TotalSeconds)")
if ($valid.Count -gt 0) {
    $null = $sb.AppendLine("Peak: $($peak.PrefillTokS) tok/s at $($peak.ContextLabel) context")
}

$sb.ToString() | Out-File -FilePath $outFile -Encoding utf8
Write-Host ""
Write-Section "<>" "Results saved"
Write-Status ">>" "${G}$outFile$X"
Write-Host ""
