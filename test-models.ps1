#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Tests qwen3-coder-next and 9 randomly selected installed models.

.DESCRIPTION
    Loads each model, sends "What are your capabilities?", captures the response
    and token rate, unloads the model, then moves to the next. Produces a summary
    table at the end. Exits with code 0 if all models pass, 1 otherwise.

    Selects a mix of small (<10 GB) and large (>=10 GB) models to exercise both
    single-GPU and multi-GPU code paths.

.PARAMETER OllamaHost
    Ollama API base URL. Default: http://localhost:11434

.PARAMETER RandomCount
    Number of random models to test in addition to qwen3-coder-next. Default: 9

.PARAMETER TimeoutSec
    Max seconds to wait for a single model generation. Default: 300

.EXAMPLE
    .\test-models.ps1
    .\test-models.ps1 -RandomCount 5 -TimeoutSec 120
#>
[CmdletBinding()]
param(
    [string]$OllamaHost = "http://localhost:11434",
    [int]$RandomCount = 9,
    [int]$TimeoutSec = 300
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Status($msg, $color = "Cyan") {
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor $color
}

function Invoke-OllamaApi {
    param([string]$Endpoint, [hashtable]$Body)
    $json = $Body | ConvertTo-Json -Depth 10
    $resp = Invoke-RestMethod -Uri "$OllamaHost$Endpoint" -Method Post `
        -ContentType "application/json" -Body $json -TimeoutSec $TimeoutSec
    return $resp
}

function Unload-Model([string]$model) {
    try {
        $body = @{ model = $model; keep_alive = 0 } | ConvertTo-Json
        Invoke-RestMethod -Uri "$OllamaHost/api/generate" -Method Post `
            -ContentType "application/json" -Body $body -TimeoutSec 30 | Out-Null
    } catch {
        Write-Host "    (unload warning: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

# ── Verify server is reachable ───────────────────────────────────────────────

Write-Status "Checking ollama server at $OllamaHost ..."
try {
    Invoke-RestMethod -Uri "$OllamaHost/" -Method Head -TimeoutSec 10 | Out-Null
} catch {
    Write-Host "ERROR: Cannot reach ollama server at $OllamaHost" -ForegroundColor Red
    Write-Host "Start it with: ollama serve" -ForegroundColor Yellow
    exit 1
}
Write-Status "Server is reachable." "Green"

# ── Get installed models ─────────────────────────────────────────────────────

Write-Status "Fetching installed model list ..."
$tags = Invoke-RestMethod -Uri "$OllamaHost/api/tags" -TimeoutSec 10
$allModels = $tags.models

# Filter out cloud-only models, embedding models, and zero-size entries
$localModels = $allModels | Where-Object {
    $_.size -gt 0 -and
    $_.name -notmatch "embed" -and
    $_.name -notmatch "cloud"          # exclude any model tag containing "cloud"
}

$modelNames = $localModels | ForEach-Object { $_.name }
Write-Status "Found $($modelNames.Count) local non-embedding models."

# ── Build test list ──────────────────────────────────────────────────────────

$required = "qwen3-coder-next:latest"
if ($required -notin $modelNames) {
    Write-Host "ERROR: Required model '$required' not found." -ForegroundColor Red
    Write-Host "Available: $($modelNames -join ', ')" -ForegroundColor Yellow
    exit 1
}

# Split candidates into small (<10 GB) and large (10-45 GB) buckets so we
# exercise both single-GPU and multi-GPU code paths.
$maxSizeGB = 45   # hard cap — models above this risk OOM on 48 GiB combined VRAM
$sizeThresholdGB = 10

$candidates = $localModels | Where-Object {
    $_.name -ne $required -and ($_.size / 1GB) -le $maxSizeGB
}
$smallPool = @($candidates | Where-Object { ($_.size / 1GB) -lt $sizeThresholdGB } | ForEach-Object { $_.name })
$largePool = @($candidates | Where-Object { ($_.size / 1GB) -ge $sizeThresholdGB } | ForEach-Object { $_.name })

Write-Status "Candidate pool: $($smallPool.Count) small (<${sizeThresholdGB}GB), $($largePool.Count) large (${sizeThresholdGB}-${maxSizeGB}GB)"

# Pick a balanced mix — aim for roughly half from each bucket, adjusting if
# one pool is too small
$wantLarge = [Math]::Min([Math]::Ceiling($RandomCount / 2), $largePool.Count)
$wantSmall = [Math]::Min($RandomCount - $wantLarge, $smallPool.Count)
# If we still have room, backfill from whichever pool has extras
$remaining = $RandomCount - $wantLarge - $wantSmall
if ($remaining -gt 0 -and $largePool.Count -gt $wantLarge) {
    $extraLarge = [Math]::Min($remaining, $largePool.Count - $wantLarge)
    $wantLarge += $extraLarge
    $remaining -= $extraLarge
}
if ($remaining -gt 0 -and $smallPool.Count -gt $wantSmall) {
    $extraSmall = [Math]::Min($remaining, $smallPool.Count - $wantSmall)
    $wantSmall += $extraSmall
}

$randomPicks = @()
if ($wantSmall -gt 0) { $randomPicks += $smallPool | Get-Random -Count $wantSmall }
if ($wantLarge -gt 0) { $randomPicks += $largePool | Get-Random -Count $wantLarge }

# Shuffle so large/small aren't grouped
$randomPicks = $randomPicks | Get-Random -Count $randomPicks.Count

# qwen3-coder-next always first
$testList = @($required) + $randomPicks
Write-Status "Will test $($testList.Count) models: $required + $($randomPicks.Count) random ($wantSmall small, $wantLarge large)"
Write-Host ""

# ── Run tests ────────────────────────────────────────────────────────────────

$results = @()
$failures = 0
$testNumber = 0

foreach ($model in $testList) {
    $testNumber++
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Status "[$testNumber/$($testList.Count)] Testing: $model" "Yellow"

    $result = [PSCustomObject]@{
        Model         = $model
        Status        = "FAIL"
        PromptTokSec  = 0.0
        EvalTokSec    = 0.0
        TotalDuration = ""
        ResponseSnip  = ""
        Error         = ""
    }

    try {
        # Use /api/generate with stream=false for easy parsing
        $body = @{
            model   = $model
            prompt  = "What are your capabilities? /no_think"
            stream  = $false
            options = @{
                num_predict = 512
                num_ctx     = 4096
            }
        }

        $attempt = 0
        $maxAttempts = 2
        $resp = $null
        while ($attempt -lt $maxAttempts) {
            $attempt++
            try {
                Write-Status "  Sending prompt (attempt $attempt) ..."
                $resp = Invoke-OllamaApi -Endpoint "/api/generate" -Body $body
                break
            } catch {
                if ($attempt -lt $maxAttempts -and $_.Exception.Message -match "500") {
                    Write-Host "    Retrying after 500 error (may be transient) ..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds 5
                } else {
                    throw
                }
            }
        }

        $response = $resp.response

        # A model that produces eval tokens is working, even if the visible
        # response is empty (thinking models may spend all tokens in <think> tags)
        $hasOutput = ($response -and $response.Trim().Length -gt 0)
        $evalCount = if ($null -ne $resp.PSObject.Properties['eval_count']) { $resp.eval_count } else { 0 }
        $hasTokens = ($evalCount -gt 0)
        if (-not $hasOutput -and -not $hasTokens) {
            throw "Empty response and zero eval tokens from model"
        }

        # Parse timing from response (null-safe — some models may omit fields)
        $promptTokSec = 0.0
        $evalTokSec   = 0.0
        $totalDurStr  = ""

        $ped = if ($null -ne $resp.PSObject.Properties['prompt_eval_duration']) { $resp.prompt_eval_duration } else { 0 }
        $pec = if ($null -ne $resp.PSObject.Properties['prompt_eval_count'])    { $resp.prompt_eval_count }    else { 0 }
        $ed  = if ($null -ne $resp.PSObject.Properties['eval_duration'])        { $resp.eval_duration }        else { 0 }
        $ec  = if ($null -ne $resp.PSObject.Properties['eval_count'])           { $resp.eval_count }           else { 0 }
        $td  = if ($null -ne $resp.PSObject.Properties['total_duration'])       { $resp.total_duration }       else { 0 }

        if ($ped -gt 0 -and $pec -gt 0) {
            $promptDurSec = $ped / 1e9
            if ($promptDurSec -gt 0) {
                $promptTokSec = [Math]::Round($pec / $promptDurSec, 2)
            }
        }
        if ($ed -gt 0 -and $ec -gt 0) {
            $evalDurSec = $ed / 1e9
            if ($evalDurSec -gt 0) {
                $evalTokSec = [Math]::Round($ec / $evalDurSec, 2)
            }
        }
        if ($td -gt 0) {
            $totalSec = [Math]::Round($td / 1e9, 1)
            $totalDurStr = "${totalSec}s"
        }

        # Truncate response for display
        if ($response) {
            $snippet = ($response -replace "`r?`n", " ").Trim()
            if ($snippet.Length -gt 120) { $snippet = $snippet.Substring(0, 117) + "..." }
        } else {
            $snippet = "(thinking model - $($resp.eval_count) eval tokens)"
        }

        $result.Status        = "PASS"
        $result.PromptTokSec  = $promptTokSec
        $result.EvalTokSec    = $evalTokSec
        $result.TotalDuration = $totalDurStr
        $result.ResponseSnip  = $snippet

        Write-Status "  PASS | Eval: $evalTokSec tok/s | Prompt: $promptTokSec tok/s | Total: $totalDurStr" "Green"
        Write-Host "  Response: $snippet" -ForegroundColor Gray

    } catch {
        $result.Error  = $_.Exception.Message
        $result.Status = "FAIL"
        $failures++

        # Truncate error for display
        $errMsg = $_.Exception.Message
        if ($errMsg.Length -gt 150) { $errMsg = $errMsg.Substring(0, 147) + "..." }
        Write-Status "  FAIL | $errMsg" "Red"
    }

    $results += $result

    # Unload model to free VRAM for next test
    Write-Status "  Unloading $model ..."
    Unload-Model $model
    Start-Sleep -Seconds 3
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 78) -ForegroundColor DarkGray
Write-Host "TEST SUMMARY" -ForegroundColor Cyan
Write-Host ("=" * 78) -ForegroundColor DarkGray
Write-Host ""

$results | Format-Table -AutoSize -Property `
    @{L="Model";          E={$_.Model}},
    @{L="Status";         E={$_.Status}},
    @{L="Eval tok/s";     E={$_.EvalTokSec}},
    @{L="Prompt tok/s";   E={$_.PromptTokSec}},
    @{L="Total";          E={$_.TotalDuration}},
    @{L="Error";          E={if ($_.Error) { $_.Error.Substring(0, [Math]::Min(60, $_.Error.Length)) } else { "" }}}

$passed = ($results | Where-Object { $_.Status -eq "PASS" }).Count
$total  = $results.Count

Write-Host ""
if ($failures -eq 0) {
    Write-Host "ALL $total TESTS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$passed/$total PASSED, $failures FAILED" -ForegroundColor Red
    $results | Where-Object { $_.Status -eq "FAIL" } | ForEach-Object {
        Write-Host "  FAILED: $($_.Model) - $($_.Error)" -ForegroundColor Red
    }
    exit 1
}
