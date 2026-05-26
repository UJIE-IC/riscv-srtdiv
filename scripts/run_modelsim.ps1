$ErrorActionPreference = "Stop"

if (Test-Path work) {
    Remove-Item -Recurse -Force work
}

vlib work
vlog -sv -f sim/modelsim_files.f
vsim -c work.tb_rv32m_srt_divider -do sim/run_modelsim.do
