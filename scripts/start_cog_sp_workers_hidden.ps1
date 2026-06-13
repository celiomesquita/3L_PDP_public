# Start 3C-SP PC2 vs CoG-SP benchmark (324 runs: 2 oracles x 54 inst x 3 seeds).
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start_cog_sp_workers_hidden.ps1
#
# Monitor: Get-Content results/logs_oracle_cog_sp/worker_0.log -Tail 5 -Wait
# Stop:    .\scripts\stop_cog_sp_study.ps1

param(
    [int]$NSeeds = 3,
    [int]$NWorkers = 20
)

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
$Julia = if ($env:JULIA) { $env:JULIA } else { "julia" }
$Script = Join-Path $Root "src\run_comparison_cog_sp.jl"
$Logs = Join-Path $Root "results\logs_oracle_cog_sp"
$PidFile = Join-Path $Root "results\cog_sp_study_pids.txt"
New-Item -ItemType Directory -Force -Path $Logs | Out-Null

$running = @(Get-Process julia -ErrorAction SilentlyContinue)
if ($running.Count -ge 5) {
    Write-Host "Already $($running.Count) julia process(es) - not starting duplicates."
    Write-Host "Stop first: .\scripts\stop_cog_sp_study.ps1"
    exit 0
}

$pids = @()
for ($wid = 0; $wid -lt $NWorkers; $wid++) {
    $log = Join-Path $Logs "worker_${wid}.log"
    $cmd = "cd /d `"$Root`" & `"$Julia`" --threads=1 --project=`"$Root`" `"$Script`" $NSeeds $wid $NWorkers 3L_PDP_instances >> `"$log`" 2>&1"
    $p = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c", $cmd `
        -WindowStyle Hidden `
        -PassThru
    $pids += $p.Id
    Start-Sleep -Milliseconds 150
}
$pids | Set-Content $PidFile
Write-Host "Launched $NWorkers CoG-SP workers. PIDs -> $PidFile"
Start-Sleep -Seconds 6
$nj = @(Get-Process julia -ErrorAction SilentlyContinue).Count
Write-Host "Julia processes now: $nj"
