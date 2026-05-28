# riscv-srtdiv

`riscv-srtdiv` 是一个面向 FPGA 学习和实现的 RV32M 整数除法器工程。当前目标不是直接接入某个 CPU 核，而是先把一个独立、可仿真、接口清晰的 radix-4 SRT 除法核心做完整。

工程支持 RV32M 中所有除法相关指令：

| 指令 | 运算类型 | 输出 |
| --- | --- | --- |
| `DIV` | signed division | quotient |
| `DIVU` | unsigned division | quotient |
| `REM` | signed remainder | remainder |
| `REMU` | unsigned remainder | remainder |

除法器使用单实例迭代结构，同一时间只处理一条请求。乘法、CSR、异常跳转和 CPU 流水线接入都不在当前版本范围内。

## 设计特点

- radix-4 SRT，每轮产生 2 个商位。
- 商 digit 集合为 `{-2, -1, 0, +1, +2}`。
- partial remainder 使用 `Q4.31` 定点格式。
- 余数迭代使用 `WS/WC` carry-save 形式保存。
- 使用 on-the-fly conversion 维护 `Q` 和 `Q-1`。
- 支持 RV32M 除 0 和 signed overflow 的架构规定结果。
- 顶层使用简单 `valid/ready` 协议，方便后续接入流水线。

## 目录结构

```text
riscv-srtdiv/
|-- README.md
|-- Unified_Digit_Selection_for_Radix-4_Recurrence_Division_and_Square_Root.pdf
|-- rtl/
|   |-- rv32m_srt_divider_top.sv
|   |-- rv32m_srt_core.sv
|   |-- rv32m_srt_lzc.sv
|   |-- rv32m_srt_qds_radix4.sv
|   |-- rv32m_srt_csa.sv
|   |-- rv32m_srt_otf.sv
|   `-- rv32m_srt_postprocess.sv
|-- tb/
|   `-- tb_rv32m_srt_divider.sv
|-- sim/
|   |-- modelsim_files.f
|   |-- run_modelsim.do
|   `-- wave_modelsim.do
|-- scripts/
|   |-- msim.ps1
|   `-- run_modelsim.ps1
`-- docs/
    `-- modelsim_guide.md
```

## 顶层接口

顶层模块是 `rv32m_srt_divider_top`：

```systemverilog
module rv32m_srt_divider_top (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input logic req_valid_i,
    output logic req_ready_o,
    input logic [1:0] req_op_i,
    input logic [31:0] req_rs1_i,
    input logic [31:0] req_rs2_i,

    output logic rsp_valid_o,
    input logic rsp_ready_i,
    output logic [31:0] rsp_result_o,
    output logic rsp_div_by_zero_o,
    output logic rsp_overflow_o,

    output logic busy_o
);
```

`req_op_i` 编码如下：

| 编码 | 指令 |
| --- | --- |
| `2'b00` | `DIV` |
| `2'b01` | `DIVU` |
| `2'b10` | `REM` |
| `2'b11` | `REMU` |

握手规则：

- `req_valid_i && req_ready_o` 为 1 时，顶层采样一条请求。
- `rsp_valid_o && rsp_ready_i` 为 1 时，下游消费一条结果。
- `busy_o` 表示除法器内部有在途请求。
- `flush_i` 会取消当前在途请求，并让状态机回到空闲。
- `rsp_div_by_zero_o` 和 `rsp_overflow_o` 只是调试状态，不代表 RISC-V trap。

## 模块结构

模块例化关系如下：

```text
rv32m_srt_divider_top
`-- rv32m_srt_core
    |-- rv32m_srt_lzc          # dividend leading zero count
    |-- rv32m_srt_lzc          # divisor leading zero count
    |-- rv32m_srt_qds_radix4   # radix-4 quotient digit selection
    |-- rv32m_srt_csa          # residual carry-save update
    |-- rv32m_srt_otf          # on-the-fly quotient conversion
    `-- rv32m_srt_postprocess  # residual restore and denormalization
```

各 RTL 模块职责：

| 模块 | 作用 |
| --- | --- |
| `rv32m_srt_divider_top` | 外部协议、指令译码、特殊结果、符号预处理和符号恢复 |
| `rv32m_srt_core` | radix-4 SRT 主状态机、归一化、迭代控制 |
| `rv32m_srt_lzc` | 计算 leading zero count 和最高有效位位置 |
| `rv32m_srt_qds_radix4` | 根据 divisor 高位和 residual 高位选择 `q_i` |
| `rv32m_srt_csa` | 执行 `R - qD` 的 carry-save 压缩 |
| `rv32m_srt_otf` | 根据 SRT digit 在线更新 `Q/Q-1` |
| `rv32m_srt_postprocess` | 处理负余数修正、奇数尾位右移和余数反归一化 |

## 顶层状态机

`rv32m_srt_divider_top` 的状态机：

```text
ST_IDLE
  | req_valid_i && req_ready_o
  v
ST_DISPATCH
  |-- div_by_zero / overflow --> ST_OUTPUT
  `-- normal request ---------> ST_WAIT_CORE
                                  |
                                  | core_done
                                  v
                               ST_OUTPUT
                                  |
                                  | rsp_valid_o && rsp_ready_i
                                  v
                               ST_IDLE
```

状态说明：

| 状态 | 作用 |
| --- | --- |
| `ST_IDLE` | 等待新请求 |
| `ST_DISPATCH` | 判断特殊情况，或者启动 SRT core |
| `ST_WAIT_CORE` | 等待 core 完成无符号幅值除法 |
| `ST_OUTPUT` | 保持结果，等待响应通道握手 |

## Core 状态机

`rv32m_srt_core` 的状态机：

```text
ST_IDLE
  | start_i
  v
ST_ITERATE
  | iter_left_q == 1
  v
ST_CORRECT
  |
  v
ST_POST
  |
  v
ST_IDLE
```

状态说明：

| 状态 | 作用 |
| --- | --- |
| `ST_IDLE` | 接收正数 dividend/divisor 幅值并初始化归一化数据 |
| `ST_ITERATE` | 执行 radix-4 SRT 迭代，更新 carry-save residual 和 OTF 商 |
| `ST_CORRECT` | 将 `WS/WC` 合成为普通二进制 residual，并记录 residual 符号 |
| `ST_POST` | 选择 `Q/Q-1`，恢复余数，输出 quotient/remainder |

## 算法流程

顶层先把有符号操作转成正数幅值：

```text
A = abs(rs1)
B = abs(rs2)
```

core 内部做归一化：

```text
X = A << lzc(A)
D = B << lzc(B)
e = lzc(B) - lzc(A)
```

当 `A >= B` 时，`e` 等价于：

```text
e = msb(A) - msb(B)
```

普通 radix-4 SRT 迭代公式为：

```text
R_next = 4 * (R - q_i * D)
q_i in {-2, -1, 0, +1, +2}
```

最后一轮不再左移 2 位，因为此时已经进入结果修正阶段：

```text
R_final = R - q_i * D
```

## 奇数尾位处理

当 `e` 为奇数时，最后一轮 radix-4 会多产生 1 个二进制商位。当前实现不单独设计 radix-2 QDS，而是在最后一轮把 radix-4 digit 折叠成 radix-2 等价 digit：

```text
q4 = +2 or +1  -> q1 = +1  -> q_keep = +2
q4 =  0        -> q1 =  0  -> q_keep =  0
q4 = -1 or -2  -> q1 = -1  -> q_keep = -2
```

数学关系为：

```text
R_real = (P - 2*q1*D) / 2
```

所以 RTL 在最后一轮使用 `q_keep = 2*q1` 做 `P - q_keep*D`，再在 postprocess 中把商和余数右移 1 位。

## 负余数修正

SRT 最终 residual 可能为负。若 residual 非负：

```text
Q_correct = Q
R_correct = R
```

若 residual 为负：

```text
Q_correct = Q - 1
R_correct = R + D
```

当 `e` 为奇数时，最后一轮等价 radix-2，恢复公式变成：

```text
R_correct = R / 2 + D
          = (R + 2D) / 2
```

因此 postprocess 中的 restore addend 只有三种情况：

| `residual_negative_i` | `shift_down_i` | 加数 |
| --- | --- | --- |
| `0` | `0/1` | `0` |
| `1` | `0` | `D` |
| `1` | `1` | `2D` |

## 执行周期数

设：

```text
e = lzc(B) - lzc(A) = msb(A) - msb(B)
```

当前实现的 radix-4 迭代次数为：

```text
iter = floor((e + 1) / 2) + 1
```

等价写法：

```text
e = 2k     -> iter = k + 1
e = 2k + 1 -> iter = k + 2
```

在 `rsp_ready_i = 1` 且没有 `flush_i` 的情况下，从请求被顶层采样到 `rsp_valid_o` 拉高：

| 情况 | 响应延迟 |
| --- | --- |
| 除 0 / signed overflow | 1 cycle |
| `A < B`，core 提前返回 | 2 cycles |
| 正常 SRT 迭代 | `iter + 4` cycles |

RV32 最坏情况下 `e = 31`：

```text
iter = floor((31 + 1) / 2) + 1 = 17
normal latency = 17 + 4 = 21 cycles
```

这里的周期数是当前未流水化、单请求迭代结构的结果。后续如果把 `ST_CORRECT/ST_POST` 合并、改变 QDS 路径、或者改成多级流水，周期数需要重新统计。

## RV32M 特殊语义

RISC-V M 扩展规定，整数除法的除 0 和 signed overflow 不触发异常跳转，不写 CSR。

除数为 0：

| 指令 | 返回值 |
| --- | --- |
| `DIV` | `32'hffff_ffff` |
| `DIVU` | `32'hffff_ffff` |
| `REM` | `rs1` |
| `REMU` | `rs1` |

signed overflow 只有一种情况：

```text
rs1 = 32'h8000_0000
rs2 = 32'hffff_ffff
```

返回值：

| 指令 | 返回值 |
| --- | --- |
| `DIV` | `32'h8000_0000` |
| `REM` | `32'h0000_0000` |

`DIVU` 和 `REMU` 是无符号运算，不存在 signed overflow。

## 仿真

工程使用 ModelSim / Questa 系列命令行工具：

```powershell
.\scripts\msim.ps1 run
```

常用命令：

| 命令 | 作用 |
| --- | --- |
| `.\scripts\msim.ps1 run` | 编译并在命令行运行 testbench |
| `.\scripts\msim.ps1 gui` | 编译并打开 ModelSim GUI 和波形 |
| `.\scripts\msim.ps1 compile` | 只编译 RTL 和 testbench |
| `.\scripts\msim.ps1 clean` | 删除 `work/`、`transcript`、`vsim.wlf` |

如果 PowerShell 阻止脚本运行，可以使用：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/msim.ps1 run
```

底层执行流程是：

```powershell
vlib work
vlog -sv -f sim/modelsim_files.f
vsim -c work.tb_rv32m_srt_divider -do sim/run_modelsim.do
```

ModelSim 命令、环境变量和 GUI 波形使用方式见：

```text
docs/modelsim_guide.md
```

## 当前验证

当前 testbench 覆盖：

- `DIV / DIVU / REM / REMU`
- signed 和 unsigned 路径
- signed 四种符号组合
- 除 0
- signed overflow
- `A < B`、`A == B`、`A > B`
- 随机操作数回归

当前回归结果：

```text
COVER op=1111 signed_div_sign=1111 signed_rem_sign=1111 unsigned_relation=1111 signed_relation=1111 special=1111
PASS 2030 tests
Errors: 0, Warnings: 0
```

