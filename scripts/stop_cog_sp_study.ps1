# Stop CoG–SP benchmark workers.
param([switch]$MergeCsv)

$Root = Split-Path $PSScriptRoot -Parent
$PidFile = Join-Path $Root "results\cog_sp_study_pids.txt"
if (Test-Path $PidFile) {
    Get-Content $PidFile | ForEach-Object {
        $id = [int]$_
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $PidFile -Force
}
Get-Process julia -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host "Stopped julia/cmd workers."

if ($MergeCsv) {
    $out = Join-Path $Root "results\comparison_oracle_cog_sp.csv"
    "instance,seed,oracle,obj,time_limit_s,pack_calls,pack_feasible" | Set-Content $out
    Get-ChildItem (Join-Path $Root "results\comparison_oracle_cog_sp_worker_*.csv") | ForEach-Object {
        Get-Content $_.FullName | Select-Object -Skip 1 | Add-Content $out
    }
    Write-Host "Merged -> $out"
}
