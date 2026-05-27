param(
    [ValidateSet("run", "gui", "compile", "clean")]
    [string]$Mode = "run"
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $ProjectRoot

function Assert-Tool {
    param(
        [string]$Name
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Cannot find '$Name'. Please add the ModelSim executable directory to PATH."
    }
}

function Remove-ModelSimGenerated {
    $targets = @(
        "work",
        "transcript",
        "vsim.wlf"
    )

    foreach ($target in $targets) {
        if (Test-Path $target) {
            Remove-Item -Recurse -Force $target
        }
    }
}

function Compile-Design {
    Assert-Tool "vlib"
    Assert-Tool "vlog"

    Remove-ModelSimGenerated
    vlib work
    vlog -sv -f sim/modelsim_files.f
}

switch ($Mode) {
    "clean" {
        Remove-ModelSimGenerated
    }

    "compile" {
        Compile-Design
    }

    "run" {
        Assert-Tool "vsim"
        Compile-Design
        vsim -c work.tb_rv32m_srt_divider -do sim/run_modelsim.do
    }

    "gui" {
        Assert-Tool "vsim"
        Compile-Design
        vsim work.tb_rv32m_srt_divider -do sim/wave_modelsim.do
    }
}
