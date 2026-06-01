$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $Root "results\logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$log = Join-Path $LogDir "memetic_table2_$stamp.log"
$err = Join-Path $LogDir "memetic_table2_$stamp.err"

Set-Location $Root

function Run-Step {
    param(
        [string] $Name,
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

Run-Step "3L-PDP memetic benchmark" @("--threads", "18,2", "--project=.", "src\run_memetic_benchmark.jl", "300", "1,2,3,4,5", "3lpdp")
Run-Step "3L-PDP-D memetic benchmark" @("--threads", "18,2", "--project=.", "src\run_memetic_benchmark.jl", "300", "1,2,3,4,5", "3lpdp_d")
Run-Step "3L-PDP-S memetic benchmark" @("--threads", "18,2", "--project=.", "src\run_memetic_benchmark.jl", "300", "1,2,3,4,5", "3lpdp_s")
Run-Step "Results summary generation" @("--project=.", "src\gen_tables.jl")

"Done. Logs: $log ; $err" | Tee-Object -FilePath $log -Append
