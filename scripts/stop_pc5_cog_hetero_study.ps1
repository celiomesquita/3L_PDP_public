param([switch]$MergeCsv)

$Root = Split-Path $PSScriptRoot -Parent
$PidFile = Join-Path $Root "results\pc5_cog_hetero_study_pids.txt"
if (Test-Path $PidFile) {
    Get-Content $PidFile | ForEach-Object {
        Stop-Process -Id ([int]$_) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $PidFile -Force
}
Get-Process julia -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host "Stopped workers."

if ($MergeCsv) {
    $out = Join-Path $Root "results\comparison_pc5_cog_hetero.csv"
    "instance,seed,oracle,obj,time_limit_s,pack_calls,pack_feasible" | Set-Content $out
    Get-ChildItem (Join-Path $Root "results\comparison_pc5_cog_hetero_worker_*.csv") | ForEach-Object {
        Get-Content $_.FullName | Select-Object -Skip 1 | Add-Content $out
    }
    $n = (Get-Content $out | Measure-Object -Line).Lines - 1
    Write-Host "Merged -> $out ($n rows, expect 108)"
}
