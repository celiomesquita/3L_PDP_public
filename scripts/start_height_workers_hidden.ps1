# Start height-study workers detached from Cursor terminals.
# Run once from project root:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start_height_workers_hidden.ps1
#
# Monitor:  Get-Content results/logs_oracle_depth_height/worker_0.log -Tail 5 -Wait
# Stop:     .\scripts\stop_height_study.ps1

param(
    [int]$NSeeds = 3,
    [int]$NWorkers = 20,
    [string]$HvList = "30,36"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
$Julia = if ($env:JULIA) { $env:JULIA } else { "julia" }
$Script = Join-Path $Root "src\run_comparison_oracle_depth.jl"
$Logs = Join-Path $Root "results\logs_oracle_depth_height"
$PidFile = Join-Path $Root "results\height_study_pids.txt"
New-Item -ItemType Directory -Force -Path $Logs | Out-Null

$running = @(Get-Process julia -ErrorAction SilentlyContinue)
if ($running.Count -ge 5) {
    Write-Host "Already $($running.Count) julia process(es) running - not starting duplicates."
    Write-Host "To stop: .\scripts\stop_height_study.ps1"
    exit 0
}

$pids = @()
for ($wid = 0; $wid -lt $NWorkers; $wid++) {
    $log = Join-Path $Logs "worker_${wid}.log"
    $cmd = "cd /d `"$Root`" & `"$Julia`" --threads=1 --project=`"$Root`" `"$Script`" $NSeeds $wid $NWorkers 3L_PDP_instances $HvList >> `"$log`" 2>&1"
    $p = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c", $cmd `
        -WindowStyle Minimized `
        -PassThru
    $pids += $p.Id
    Start-Sleep -Milliseconds 150
}
$pids | Set-Content $PidFile
Write-Host "Launched $NWorkers cmd wrappers. PIDs saved to $PidFile"
Start-Sleep -Seconds 6
$nj = @(Get-Process julia -ErrorAction SilentlyContinue).Count
Write-Host "Julia processes now: $nj"
