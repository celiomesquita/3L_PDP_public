$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$LogDir  = Join-Path $Root "results\logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$log   = Join-Path $LogDir "memetic_hetero_$stamp.log"
$err   = Join-Path $LogDir "memetic_hetero_$stamp.err"

Set-Location $Root

function Run-Step {
    param(
        [string]   $Name,
        [string[]] $JuliaArgs
    )
    $started = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$started] START $Name" | Tee-Object -FilePath $log -Append
    & julia @JuliaArgs 2>> $err | Tee-Object -FilePath $log -Append
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
    $finished = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$finished] END $Name" | Tee-Object -FilePath $log -Append
}

# Generate hetero instances if not yet present
$HeteroDir = Join-Path $Root "3L_PDP_instances_hetero"
if (-not (Test-Path $HeteroDir) -or
    (Get-ChildItem $HeteroDir -Filter "*.txt" -ErrorAction SilentlyContinue).Count -lt 270) {
    Run-Step "Generate heterogeneous instances" @("--project=.", "src\gen_hetero_instances.jl")
}

Run-Step "3L-PDP-H memetic benchmark (baseline)"  @("--threads", "18,2", "--project=.", "src\run_memetic_benchmark.jl", "300", "1", "3lpdp_h", "auto", "results\memetic_benchmark_3lpdp_h.csv",   "3L_PDP_instances_hetero")
Run-Step "3L-PDP-D memetic benchmark (PC5)"        @("--threads", "18,2", "--project=.", "src\run_memetic_benchmark.jl", "300", "1", "3lpdp_d", "auto", "results\memetic_benchmark_3lpdp_d_h.csv", "3L_PDP_instances_hetero")
Run-Step "3L-PDP-C memetic benchmark (PC7)"        @("--threads", "18,2", "--project=.", "src\run_memetic_benchmark.jl", "300", "1", "3lpdp_c", "auto", "results\memetic_benchmark_3lpdp_c.csv",   "3L_PDP_instances_hetero")
Run-Step "Results summary generation"                  @("--project=.", "src\gen_tables.jl")

"Done. Logs: $log ; $err" | Tee-Object -FilePath $log -Append
