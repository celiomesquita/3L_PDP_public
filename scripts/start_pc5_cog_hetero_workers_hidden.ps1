# PC5 vs CoG-SP on hardest 20% hetero instances (108 runs: 54 x 2 oracles, seed 1).
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start_pc5_cog_hetero_workers_hidden.ps1
#
# Prerequisite: julia --project=. src/select_hardest_hetero_instances.jl

param(
    [int]$SolverSeed = 1,
    [int]$NWorkers = 20
)

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
$Julia = if ($env:JULIA) { $env:JULIA } else { "julia" }

& $Julia --project=$Root "$Root\src\select_hardest_hetero_instances.jl"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$Script = Join-Path $Root "src\run_comparison_pc5_cog_hetero.jl"
$Logs = Join-Path $Root "results\logs_pc5_cog_hetero"
$PidFile = Join-Path $Root "results\pc5_cog_hetero_study_pids.txt"
New-Item -ItemType Directory -Force -Path $Logs | Out-Null

$running = @(Get-Process julia -ErrorAction SilentlyContinue)
if ($running.Count -ge 5) {
    Write-Host "Already $($running.Count) julia process(es) - stop first."
    exit 0
}

$pids = @()
for ($wid = 0; $wid -lt $NWorkers; $wid++) {
    $log = Join-Path $Logs "worker_${wid}.log"
    $cmd = "cd /d `"$Root`" & `"$Julia`" --threads=1 --project=`"$Root`" `"$Script`" $SolverSeed $wid $NWorkers 3L_PDP_instances_hetero >> `"$log`" 2>&1"
    $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmd -WindowStyle Hidden -PassThru
    $pids += $p.Id
    Start-Sleep -Milliseconds 150
}
$pids | Set-Content $PidFile
Write-Host "Launched $NWorkers workers. PIDs -> $PidFile"
Start-Sleep -Seconds 6
$nj = @(Get-Process julia -ErrorAction SilentlyContinue).Count
Write-Host "Julia processes now: $nj"
