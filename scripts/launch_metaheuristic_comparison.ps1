# Table I — preliminary metaheuristic comparison (6 instances × 3 seeds, 300 s).
#
# Usage (from repo root):
#   .\scripts\launch_metaheuristic_comparison.ps1

$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path -Parent $PSScriptRoot
$JuliaExe   = if ($env:JULIA) { $env:JULIA } else { "julia" }

Set-Location $ProjectDir
New-Item -ItemType Directory -Force (Join-Path $ProjectDir "results") | Out-Null

& $JuliaExe --threads 18,2 --project=. src/run_metaheuristic_comparison.jl 300 1,2,3
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Done. Output: results/metaheuristic_comparison.csv (or timestamped variant from script)."
