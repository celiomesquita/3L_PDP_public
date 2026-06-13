# ALNS oracle-depth ablation (1C-SP / 2C-SP / 3C-SP), 300 s, parallel workers.
#
# Usage (from repository root):
#   .\scripts\launch_comparison.ps1
#   .\scripts\launch_comparison.ps1 -NSeeds 3 -NWorkers 5

param(
    [int]$NSeeds   = 3,
    [int]$NWorkers = 5
)

$ErrorActionPreference = "Stop"
$Root    = Split-Path -Parent $PSScriptRoot
$Julia   = if ($env:JULIA) { $env:JULIA } else { "julia" }
$Script  = Join-Path $Root "src\run_comparison_2csp.jl"
$Results = Join-Path $Root "results"
$Logs    = Join-Path $Results "logs_comparison_oracle"

New-Item -ItemType Directory -Force -Path $Results, $Logs | Out-Null

Write-Host ""
Write-Host "Launching $NWorkers workers (seeds=1..$NSeeds, T_op=300 s)..."
Write-Host ""

$Procs = @()
for ($w = 0; $w -lt $NWorkers; $w++) {
    $logFile = Join-Path $Logs "worker_${w}.log"
    $Procs += Start-Process -FilePath $Julia `
        -ArgumentList @(
            "--threads", "auto",
            "--project=$Root",
            $Script, "$NSeeds", "$w", "$NWorkers"
        ) `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError $logFile `
        -WorkingDirectory $Root `
        -NoNewWindow -PassThru
    Write-Host "  Worker $w started (PID $($Procs[-1].Id))"
}

Write-Host ""
Write-Host "Waiting for workers..."
$failed = $false
foreach ($p in $Procs) {
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { $failed = $true; Write-Host "  PID $($p.Id) exit $($p.ExitCode)" }
}
if ($failed) { exit 1 }

$Merged = Join-Path $Results "comparison_2csp_vs_3csp.csv"
"instance,seed,oracle,obj,time_limit_s,pack_calls,pack_feasible" | Set-Content $Merged
for ($w = 0; $w -lt $NWorkers; $w++) {
    $f = Join-Path $Results "comparison_worker_$w.csv"
    if (Test-Path $f) {
        Get-Content $f | Where-Object { $_ -notmatch "^instance" } | Add-Content $Merged
    }
}
Write-Host "Merged -> $Merged"
Write-Host "Analyze:  julia --project=. src/analyze_comparison.jl"
