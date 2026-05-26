# ModelSim 本地仿真指南

这份文档面向第一次从 GUI 转到命令行使用 ModelSim 的同学。你以前在 GUI 里点按钮，本质上也是在做同一套流程：

```text
创建库 -> 编译 RTL/testbench -> 加载 testbench -> 运行仿真 -> 看结果/波形
```

命令行只是把这些步骤显式写出来，方便重复运行、写脚本、做自动回归。

## 1. ModelSim 里几个常用程序

ModelSim 不是只有一个程序。最常见的是这几个命令：

```text
vlib    创建仿真库
vlog    编译 Verilog/SystemVerilog
vsim    启动仿真器
```

它们在 Windows 里其实就是可执行文件：

```text
vlib.exe
vlog.exe
vsim.exe
```

所以当你在 PowerShell 里输入：

```powershell
vlog -sv -f sim/modelsim_files.f
```

PowerShell 并不会自己理解 SystemVerilog。它只负责找到 `vlog.exe`，然后把 `-sv -f sim/modelsim_files.f` 这些参数交给 ModelSim 的编译器。

## 2. 为什么终端能直接输入 vlog/vsim

Windows 终端找命令时，会去 `PATH` 环境变量里列出的目录挨个查找。

如果 ModelSim 的安装目录已经在 `PATH` 里，你就可以直接输入：

```powershell
vlog
vsim
```

如果没在 `PATH` 里，终端会提示找不到命令。可以用下面的命令检查：

```powershell
Get-Command vlog
Get-Command vsim
```

如果能看到类似输出，说明配置好了：

```text
Application     vlog.exe     ...\modelsim_ase\win32aloem\vlog.exe
Application     vsim.exe     ...\modelsim_ase\win32aloem\vsim.exe
```

如果没有输出，就需要把 ModelSim 的可执行文件目录加入系统 `PATH`，或者每次都使用完整路径。比如：

```powershell
E:\intelFPGA_pro\21.1\modelsim_ase\win32aloem\vlog.exe -sv -f sim/modelsim_files.f
```

工程里建议配置 `PATH`，因为这样每个项目都可以直接运行 `vlib/vlog/vsim`。

## 3. 本工程的仿真目录结构

本项目把仿真相关文件整理在这些目录里：

```text
riscv-srtdiv/
|-- rtl/                    # 可综合 RTL
|-- tb/                     # testbench
|-- sim/                    # ModelSim 文件列表和 .do 脚本
|   |-- modelsim_files.f
|   |-- run_modelsim.do
|   `-- wave_modelsim.do
|
|-- scripts/                # 一键运行脚本
|   `-- run_modelsim.ps1
|
|-- docs/
|   `-- modelsim_guide.md
|
`-- README.md
```

`rtl/` 和 `tb/` 是源文件。`sim/` 和 `scripts/` 是为了让仿真过程可重复、可记录。

## 4. 三条核心命令

如果不用脚本，ModelSim 命令行仿真最核心就是三步。

### 4.1 创建 work 库

```powershell
vlib work
```

`work` 是 ModelSim 默认工作库。可以把它理解成“编译结果目录”。

RTL/testbench 编译后不是直接变成普通 `.exe`，而是进入 `work` 这个库。之后 `vsim` 从 `work` 里加载 testbench。

如果工程改过很多次，旧的 `work/` 可能残留过期编译结果，所以脚本会先删除旧 `work/` 再重新创建。

### 4.2 编译 SystemVerilog

```powershell
vlog -sv -f sim/modelsim_files.f
```

参数含义：

```text
vlog    ModelSim 的 Verilog/SystemVerilog 编译器
-sv     按 SystemVerilog 模式编译
-f      从文件列表读取要编译的文件
```

`sim/modelsim_files.f` 内容是：

```text
rtl/rv32m_srt_lzc.sv
rtl/rv32m_srt_qds_radix4.sv
rtl/rv32m_srt_otf.sv
rtl/rv32m_srt_postprocess.sv
rtl/rv32m_srt_csa.sv
rtl/rv32m_srt_core.sv
rtl/rv32m_srt_divider_top.sv
tb/tb_rv32m_srt_divider.sv
```

文件顺序建议从底层模块到顶层模块，再到 testbench。这样依赖关系最清楚，也更利于定位错误。

### 4.3 运行 testbench

```powershell
vsim -c work.tb_rv32m_srt_divider -do sim/run_modelsim.do
```

参数含义：

```text
vsim                        ModelSim 仿真器
-c                          command line 模式，不打开 GUI
work.tb_rv32m_srt_divider   work 库里的 tb_rv32m_srt_divider 模块
-do                         执行 ModelSim Tcl 脚本
```

`sim/run_modelsim.do` 内容是：

```tcl
onerror {quit -code 1}
run -all
quit -f
```

含义：

```text
onerror {quit -code 1}   如果仿真命令出错，让命令行返回失败
run -all                 一直运行，直到 testbench 里调用 $finish
quit -f                  仿真结束后退出
```

## 5. 一键运行

项目根目录下执行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_modelsim.ps1
```

脚本内部做的事情是：

```powershell
if (Test-Path work) {
    Remove-Item -Recurse -Force work
}

vlib work
vlog -sv -f sim/modelsim_files.f
vsim -c work.tb_rv32m_srt_divider -do sim/run_modelsim.do
```

如果通过，会看到：

```text
PASS 2014 tests
```

## 6. GUI 怎么用

命令行和 GUI 不冲突。你可以先用命令编译：

```powershell
vlib work
vlog -sv -f sim/modelsim_files.f
```

然后打开 GUI：

```powershell
vsim work.tb_rv32m_srt_divider
```

进入 GUI 后，在 Transcript 窗口输入：

```tcl
add wave -r /*
run -all
```

也可以直接执行项目里的 GUI 波形脚本：

```powershell
vsim work.tb_rv32m_srt_divider -do sim/wave_modelsim.do
```

`wave_modelsim.do` 做两件事：

```tcl
add wave -r /*
run -all
```

这样会递归添加所有信号到波形窗口，然后运行完整仿真。

## 7. 为什么要用脚本

GUI 点按钮适合交互式调试，但有几个问题：

```text
1. 每个人点的顺序可能不一样
2. 很难记录到底编译了哪些文件
3. 不适合每天重复回归
4. 不适合以后接 CI
```

脚本把流程固定下来：

```text
固定文件列表
固定编译选项
固定 testbench
固定运行命令
```

这样你每次只需要跑同一个命令，就能知道 RTL 有没有被改坏。

## 8. 生成物是什么

ModelSim 运行后会产生一些文件或目录：

```text
work/        编译库
transcript   ModelSim 命令记录
vsim.wlf     波形数据库
*.log        日志
```

这些是仿真生成物，不是源码，不建议提交到 git。本项目的 `.gitignore` 已经忽略它们。

## 9. 常见问题

### 9.1 找不到 vlog 或 vsim

检查：

```powershell
Get-Command vlog
Get-Command vsim
```

如果找不到，就把 ModelSim 的可执行目录加入 `PATH`。

### 9.2 编译报找不到模块

通常是 `sim/modelsim_files.f` 文件顺序不对，或者漏了某个 RTL 文件。

解决方法：

```text
1. 确认被实例化的子模块在顶层之前编译
2. 确认 testbench 最后编译
3. 确认路径是相对项目根目录的路径
```

### 9.3 GUI 里没有波形

进入仿真后需要手动添加波形：

```tcl
add wave -r /*
```

再运行：

```tcl
run -all
```

或者直接用：

```powershell
vsim work.tb_rv32m_srt_divider -do sim/wave_modelsim.do
```

