# launch_comparison_height.ps1
# Oracle depth × truck height (Hv 30 vs 36) — parallel workers, resume-safe.
#
# Usage (from project root):
#   .\scripts\launch_comparison_height.ps1
#   .\scripts\launch_comparison_height.ps1 -NSeeds 3 -NWorkers 20 -HvList "30,36"
#
# Each worker writes results/comparison_oracle_depth_worker_{id}.csv
# Logs: results/logs_oracle_depth_height/worker_{id}.log

param(
    [int]$NSeeds    = 3,
    [int]$NWorkers  = 20,
    [string]$HvList = "30,36",
    [int]$ThreadsPerWorker = 1
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$Julia       = if ($env:JULIA) { $env:JULIA } else { "julia" }
$Script      = Join-Path $ProjectRoot "src\run_comparison_oracle_depth.jl"
$ResultsDir  = Join-Path $ProjectRoot "results"
$LogsDir     = Join-Path $ResultsDir "logs_oracle_depth_height"
$InstDir     = "3L_PDP_instances"

$nHeights = ($HvList -split ",").Count
$TotalJobs = 54 * $NSeeds * 3 * $nHeights
$JobsPerWorker = [math]::Ceiling($TotalJobs / $NWorkers)
$EstMin = [math]::Round(300 * $JobsPerWorker / 60)

if (-not (Test-Path $ResultsDir)) { New-Item -ItemType Directory -Path $ResultsDir | Out-Null }
if (-not (Test-Path $LogsDir))    { New-Item -ItemType Directory -Path $LogsDir | Out-Null }

Write-Host ""
Write-Host "========================================"
Write-Host "  Oracle depth x truck height study"
Write-Host "========================================"
Write-Host "  Instances   : 54 ($InstDir)"
Write-Host "  Oracles     : 1C-SP, 2C-SP, 3C-SP"
Write-Host "  T_op        : 300 s"
Write-Host "  Seeds       : 1..$NSeeds"
Write-Host "  Hv values   : $HvList  (30=3.0 m, 36=3.6 m, dm units)"
Write-Host "  Workers     : $NWorkers"
Write-Host "  Threads/worker: $ThreadsPerWorker"
Write-Host "  Jobs/worker : ~$JobsPerWorker  (total $TotalJobs)"
Write-Host "  Est. serial : ~$EstMin min per worker (less with parallelism)"
Write-Host "  Logs        : $LogsDir"
Write-Host "========================================"
Write-Host ""

$Procs = @()
for ($wid = 0; $wid -lt $NWorkers; $wid++) {
    $logFile = Join-Path $LogsDir "worker_${wid}.log"
    $args = @(
        "--threads=$ThreadsPerWorker",
        "--project=$ProjectRoot",
        $Script,
        "$NSeeds", "$wid", "$NWorkers", $InstDir, $HvList
    )
    $Procs += Start-Process -FilePath $Julia `
        -ArgumentList $args `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError $logFile `
        -WorkingDirectory $ProjectRoot `
        -NoNewWindow -PassThru
    Write-Host "  Worker $wid started (PID $($Procs[-1].Id)) -> $logFile"
}

Write-Host ""
Write-Host "Waiting for workers..."
$failed = $false
foreach ($p in $Procs) {
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) {
        Write-Host "  Worker PID $($p.Id): FAILED (exit $($p.ExitCode))"
        $failed = $true
    }
}
if ($failed) {
    Write-Host "One or more workers failed — check $LogsDir"
    exit 1
}
Write-Host "All workers finished."

$Merged = Join-Path $ResultsDir "comparison_oracle_depth_height.csv"
"instance,seed,oracle,Hv,obj,time_limit_s,pack_calls,pack_feasible" | Set-Content $Merged
for ($wid = 0; $wid -lt $NWorkers; $wid++) {
    $wcsv = Join-Path $ResultsDir "comparison_oracle_depth_worker_${wid}.csv"
    if (Test-Path $wcsv) {
        Get-Content $wcsv | Where-Object { $_ -notmatch "^instance" } | Add-Content $Merged
    }
}
$nRows = (Get-Content $Merged | Measure-Object -Line).Lines - 1
Write-Host ""
Write-Host "Merged $nRows rows -> $Merged"
Write-Host "Analyze:  julia --project=. src/analyze_comparison_height.jl"
