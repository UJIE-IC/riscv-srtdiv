# riscv-srtdiv

`riscv-srtdiv` 是一个面向 FPGA 的 RV32M 整数除法器项目。当前阶段的目标不是接入某一个 CPU 核，而是先实现一个独立、可验证、可复用的 **radix-4 SRT divider IP**：输入 RV32M 除法类操作、两个 32 位操作数，输出符合 RISC-V 规范的商或余数。

这个项目会优先把算法做正确、接口做干净、验证做充分。后续再考虑接入 RV32IM 流水线、做更高基数 SRT、或者用 DSP 乘法器尝试 Newton / Goldschmidt 方案。

## 目标

第一版只覆盖 RV32M 中的除法相关指令：

| 指令 | 含义 | 输出 |
| --- | --- | --- |
| `DIV` | signed 32-bit division | quotient |
| `DIVU` | unsigned 32-bit division | quotient |
| `REM` | signed 32-bit remainder | remainder |
| `REMU` | unsigned 32-bit remainder | remainder |

设计目标：

- 使用 radix-4 SRT 迭代算法，每轮产生 2 个商位。
- 使用 minimally redundant digit set：`q_i in {-2, -1, 0, +1, +2}`。
- 使用 on-the-fly conversion 直接维护非冗余商，避免最后再做一条很长的加法转换路径。
- 完整支持 RV32M 对除 0 和 signed overflow 的规定结果。
- 除法器本身不产生 trap，不依赖 CSR，也不绑定某个 CPU 微结构。
- 外部只暴露简单 `valid/ready` 协议，方便后续接入流水线或单元测试环境。

## 为什么先做 radix-4 SRT

对于 FPGA 上的 RV32M 除法，radix-4 SRT 是一个比较稳的起点：

| 方案 | 每轮商位 | 典型迭代次数 | 特点 |
| --- | ---: | ---: | --- |
| radix-2 restoring / non-restoring | 1 | 32 | 最简单，但周期长 |
| radix-4 SRT | 2 | 最多 16 | 表小、路径短、验证压力适中 |
| radix-8 SRT | 3 | 最多 11 | 周期更少，但选商和倍数生成更复杂 |
| radix-16 SRT | 4 | 最多 8 | 性能更高，但时序压力明显上升 |
| Newton / Goldschmidt | 多位收敛 | 少 | 适合复用 DSP/FMA，但控制、初值表和舍入验证更重 |

本项目先选择 radix-4，是为了把 SRT 的关键细节做扎实：归一化、选商、冗余余数迭代、OTF 商转换、最终修正、RV32M 特殊语义。

## 外部接口

顶层模块为：

```systemverilog
module rv32m_srt_divider_top (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,

  input  logic        req_valid_i,
  output logic        req_ready_o,
  input  logic [1:0]  req_op_i,
  input  logic [31:0] req_rs1_i,
  input  logic [31:0] req_rs2_i,

  output logic        rsp_valid_o,
  input  logic        rsp_ready_i,
  output logic [31:0] rsp_result_o,
  output logic        rsp_div_by_zero_o,
  output logic        rsp_overflow_o,

  output logic        busy_o
);
```

`req_op_i` 编码：

| 编码 | 指令 |
| --- | --- |
| `2'b00` | `DIV` |
| `2'b01` | `DIVU` |
| `2'b10` | `REM` |
| `2'b11` | `REMU` |

握手规则：

- `req_valid_i && req_ready_o` 为 1 时，顶层接收一条新请求。
- 当前实现按单发射迭代除法器建模：一个除法正在进行时，`req_ready_o` 拉低。
- `rsp_valid_o` 为 1 时，`rsp_result_o` 和状态信号有效。
- `rsp_valid_o && rsp_ready_i` 为 1 后，本次结果被消费，除法器回到空闲。
- `flush_i` 用于后续接入 CPU 流水线时取消在途操作。

`rsp_div_by_zero_o` 和 `rsp_overflow_o` 是调试/验证状态信号，不是架构异常信号。

## RV32M 特殊语义

RISC-V M 扩展规定，整数除法的除 0 和 signed overflow 都不会触发异常跳转，也不写 `mcause`，不需要 CSR 参与。

除数为 0 时：

| 指令 | 结果 |
| --- | --- |
| `DIV` | `32'hffff_ffff` |
| `DIVU` | `32'hffff_ffff` |
| `REM` | `rs1` |
| `REMU` | `rs1` |

RV32 signed overflow 只有一种情况：

```text
rs1 = 32'h8000_0000  // -2^31
rs2 = 32'hffff_ffff  // -1
```

此时：

| 指令 | 结果 |
| --- | --- |
| `DIV` | `32'h8000_0000` |
| `REM` | `32'h0000_0000` |

`DIVU` / `REMU` 是无符号运算，不存在 signed overflow。

## 算法约定

### 1. 符号预处理

有符号指令先转成绝对值做 unsigned division：

```text
A = abs(rs1)
B = abs(rs2)
```

最终恢复符号：

```text
DIV  quotient sign  = rs1[31] xor rs2[31]
REM  remainder sign = rs1[31]
```

无符号指令直接使用原始操作数。

### 2. 有效商位数

如果 `A < B`，商为 0，余数为 `A`，可以提前返回。

否则令：

```text
a_msb  = floor(log2(A))
b_msb  = floor(log2(B))
e      = a_msb - b_msb
q_bits = e + 1
```

`q_bits` 是整数商真正需要生成的二进制位数。radix-4 每轮产生 2 个商位：

```text
full_radix4_iters = q_bits / 2
need_odd_tail     = q_bits % 2
max_total_iters   = ceil(q_bits / 2)
```

对于 RV32，最坏情况需要 32 个商位，所以 radix-4 主迭代最多 16 轮。

### 3. 奇数商位处理

当 `q_bits` 为奇数时，最后只需要一个二进制商位。项目采用当前约定：仍复用 radix-4 选商逻辑得到一个 `q4`，再折叠成 radix-2 等价商位 `q1`：

```text
q4 = +2 or +1  -> q1 = +1
q4 =  0        -> q1 =  0
q4 = -1 or -2  -> q1 = -1
```

这样不需要单独设计一套 radix-2 选择表，也能保持 QDS 逻辑统一。

### 4. 递推形式

本项目按论文 *Unified Digit Selection for Radix-4 Recurrence Division and Square Root* 的写法组织 radix-4 recurrence：

```text
W_next = 4 * (W - q * D)
q in {-2, -1, 0, +1, +2}
```

也就是先根据当前 partial remainder 和 divisor 选出本轮商 `q`，再减去 `q * D`，最后左移 2 位进入下一轮。

### 5. 选商表

`rv32m_srt_qds_radix4.sv` 会实现论文中的 unified radix-4 digit selection。第一版先采用论文 Table VI 的 simple selection constants：

| `A` | `000` | `001` | `010` | `011` | `100` | `101` | `110` | `111` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `m2`  | 12 | 14 | 16 | 16 | 18 | 20 | 20 | 24 |
| `m1`  | 4  | 4  | 4  | 4  | 6  | 6  | 8  | 8  |
| `m0`  | -4 | -4 | -6 | -6 | -6 | -8 | -8 | -8 |
| `m-1` | -13 | -14 | -16 | -17 | -18 | -20 | -22 | -22 |

这些常数以 `1/8` 为单位。论文建议的硬件形式是：

- `A` 取 normalized divisor 的 3 个最高有效小数位。
- partial remainder 的高位 `WH` 使用 `Q4.3` 截断形式参与比较。
- QDS 输出 one-hot / signed digit 编码，对应 `{-2,-1,0,+1,+2}`。

后续 RTL 中会把 QDS 独立成组合模块，方便单独穷举验证选商区间。

### 6. On-the-fly conversion

SRT 的商是冗余 digit 序列，不能直接拼接成普通二进制商。本项目会维护两条寄存器：

```text
Q   : 当前转换出的商
QM  : 当前商减 1 的影子值
```

每轮根据 `q_i` 更新 `Q/QM`，避免最后对整条冗余 digit 序列做 carry-propagate 加法。radix-4 digit 对应两位注入：

| `q_i` | `Q_next` 注入 | `QM_next` 注入 |
| ---: | --- | --- |
| `+2` | `{Q,  2'b10}` | `{Q,  2'b01}` |
| `+1` | `{Q,  2'b01}` | `{Q,  2'b00}` |
| `0`  | `{Q,  2'b00}` | `{QM, 2'b11}` |
| `-1` | `{QM, 2'b11}` | `{QM, 2'b10}` |
| `-2` | `{QM, 2'b10}` | `{QM, 2'b01}` |

奇数尾位使用 `q1` 更新时，只注入 1 位。

## RTL 结构

当前工程已经补齐第一版可仿真的 RTL：

```text
rtl/
|-- rv32m_srt_divider_top.sv      # 顶层握手、请求锁存、特殊语义、符号恢复
|-- rv32m_srt_core.sv             # radix-4 SRT 主控制器，负责归一化、迭代和完成信号
|-- rv32m_srt_lzc.sv              # leading-zero / leading-one 位置计算
|-- rv32m_srt_qds_radix4.sv       # Unified radix-4 quotient digit selection
|-- rv32m_srt_otf.sv              # on-the-fly quotient conversion
|-- rv32m_srt_postprocess.sv      # 基于最终 residual 的商修正与余数恢复
`-- rv32m_srt_csa.sv              # CSA 基础模块，用于保存 carry-save partial remainder
```

顶层只关心 RV32M 指令语义和外部协议。真正的 SRT 细节放在 `rv32m_srt_core.sv` 内部，后续可以替换成 radix-8/radix-16 或流水线版本，而不改变外部接口。

第一版 core 使用 radix-4 SRT recurrence 和论文 Table VI 选商表生成商 digit，并用 OTF 转换得到二进制商。partial remainder 在迭代中以 `WS/WC` 两路 carry-save 形式保存；最终后处理先把 `WS + WC` 压缩成普通二进制 residual，再根据 residual 符号选择 `Q/QM`，并通过条件加回 normalized divisor、右移反归一化来恢复余数。后处理不再使用 `quotient * divisor` 回代，因此不会在结果路径上引入乘法器。

## 仿真

工程仿真环境改为 ModelSim，相关文件如下：

```text
sim/
|-- modelsim_files.f
|-- run_modelsim.do
`-- wave_modelsim.do

scripts/
`-- run_modelsim.ps1

docs/
`-- modelsim_guide.md
```

命令行一键运行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_modelsim.ps1
```

或者使用统一任务脚本：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/msim.ps1 run
powershell -ExecutionPolicy Bypass -File scripts/msim.ps1 gui
```

脚本执行：

```powershell
vlib work
vlog -sv -f sim/modelsim_files.f
vsim -c work.tb_rv32m_srt_divider -do sim/run_modelsim.do
```

如果希望打开 ModelSim GUI 看波形，可以先编译，再执行：

```powershell
vsim work.tb_rv32m_srt_divider -do sim/wave_modelsim.do
```

ModelSim 命令行、环境变量、`work` 库、`.f` 文件列表和 `.do` 脚本的详细解释见 [docs/modelsim_guide.md](docs/modelsim_guide.md)。

当前 testbench 覆盖：

- `DIV/DIVU/REM/REMU`
- 除 0
- `32'h8000_0000 / 32'hffff_ffff` signed overflow
- `abs(rs1) < abs(rs2)` 提前返回
- 随机 RV32M 除法/取余用例

## 顶层状态机

第一版顶层按单实例迭代结构设计：

```text
IDLE
  | accept request
  v
DISPATCH
  |-- special case --> OUTPUT
  |
  `-- normal divide --> WAIT_CORE
                          |
                          v
                       OUTPUT
```

- `IDLE`：等待新请求。
- `DISPATCH`：处理除 0、signed overflow、`abs(rs1) < abs(rs2)` 等提前返回情况；正常情况启动 SRT core。
- `WAIT_CORE`：等待 SRT core 返回 unsigned quotient/remainder magnitude。
- `OUTPUT`：等待下游消费结果。

## 验证计划

建议按三层验证：

1. QDS 单元验证
   - 穷举 `A` 和 `WH` 截断输入。
   - 检查 digit 是否落在允许选择区间内。
   - 单独覆盖边界常数 `m2/m1/m0/m-1`。

2. Core 算法验证
   - 对 unsigned division 做定向和随机测试。
   - 覆盖 `A < B`、`A == B`、`B == 1`、`B == 3`、最大商、非整除余数。
   - 检查恒等式：`dividend = divisor * quotient + remainder`，且 `remainder < divisor`。

3. RV32M 顶层验证
   - 覆盖 `DIV/DIVU/REM/REMU`。
   - 覆盖除 0 和 `32'h8000_0000 / 32'hffff_ffff`。
   - 随机对比软件参考模型。
   - 检查 `valid/ready/flush` 行为。

## 开发路线

- [x] 确定顶层外部协议。
- [x] 确定 RV32M 特殊语义处理方式。
- [x] 确定 radix-4 SRT recurrence 形式。
- [x] 确定奇数商位使用 `q4 -> q1` 折叠。
- [x] 实现 `rv32m_srt_lzc.sv`。
- [x] 实现 `rv32m_srt_qds_radix4.sv`。
- [x] 实现 `rv32m_srt_otf.sv`。
- [x] 实现 `rv32m_srt_core.sv`。
- [x] 实现 testbench 和软件参考模型。
- [x] 使用 ModelSim 完成基础随机回归。
- [ ] 完成 FPGA 综合资源与时序评估。

## 当前状态

当前仓库已经形成第一版可仿真的 RV32M radix-4 SRT divider。ModelSim 下可通过 `vlib`、`vlog` 和 `vsim` 完成编译与仿真，基础 testbench 输出 `PASS 2014 tests`。当前 RTL 已经把 `rv32m_srt_csa.sv` 接入迭代路径，并且后处理已经改为直接从 SRT residual 恢复余数，不再使用乘法回代。下一步建议重点做 FPGA 综合资源与时序评估，并继续扩大随机测试规模。
