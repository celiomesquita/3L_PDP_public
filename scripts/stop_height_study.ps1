# Stop height-study Julia workers and optionally merge CSVs.
param([switch]$Merge)

$Root = Split-Path $PSScriptRoot -Parent
$PidFile = Join-Path $Root "results\height_study_pids.txt"
if (Test-Path $PidFile) {
    Get-Content $PidFile | ForEach-Object {
        Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $PidFile -Force
    Write-Host "Stopped workers listed in $PidFile"
} else {
    $n = (Get-Process julia -ErrorAction SilentlyContinue).Count
    Get-Process julia -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Host "Stopped $n julia process(es) (no pid file)."
}

if ($Merge) {
    $merged = Join-Path $Root "results\comparison_oracle_depth_height.csv"
    "instance,seed,oracle,Hv,obj,time_limit_s,pack_calls,pack_feasible" | Set-Content $merged
    Get-ChildItem (Join-Path $Root "results\comparison_oracle_depth_worker_*.csv") |
        Sort-Object { [int]($_.BaseName -replace '\D+','') } |
        ForEach-Object {
            Get-Content $_.FullName | Where-Object { $_ -notmatch "^instance" } | Add-Content $merged
        }
    $rows = (Get-Content $merged | Measure-Object -Line).Lines - 1
    Write-Host "Merged $rows rows -> $merged"
}
