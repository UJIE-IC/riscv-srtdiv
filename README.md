<<<<<<< ours
<<<<<<< ours
# riscv-srtdiv
=======
=======
>>>>>>> theirs
# riscv-srtdiv

> 一个面向 FPGA 的 RISC-V RV32M 除法器项目，目标是实现结构清晰、可验证、可复用的 **基 4 SRT 除法核心**。

`riscv-srtdiv` 专注于 RISC-V M 扩展中的除法相关指令。项目第一阶段不绑定任何具体 CPU 核，也不依赖复杂总线协议，而是先实现一个独立的除法 IP：输入操作数和指令类型，输出计算结果以及用于调试和验证的状态信息。

这个项目适合用于：

- 学习 RV32M 除法指令的精确定义
- 理解 SRT 除法算法在硬件中的实现方式
- 在 FPGA 上实现一个轻量、稳定、易集成的整数除法器
- 为后续 RV32IM CPU 或 SoC 项目提供可复用的 M 扩展执行单元

## 项目目标

本项目计划实现 RV32M 中的四条除法/取余指令：

| 指令 | 类型 | 结果 |
| --- | --- | --- |
| `DIV` | 有符号除法 | 商 |
| `DIVU` | 无符号除法 | 商 |
| `REM` | 有符号取余 | 余数 |
| `REMU` | 无符号取余 | 余数 |

设计目标：

- 支持完整 RV32M 除法语义
- 使用基 4 SRT 迭代算法
- 单实例迭代结构，接口简单，便于集成
- 特殊情况可提前返回，降低无效迭代开销
- 面向 FPGA 进行时序和资源取舍
- 提供可自动化回归的仿真测试环境

## 为什么选择基 4 SRT

整数除法器常见实现方案包括恢复除法、不恢复除法、SRT 除法和 Newton 迭代等。对于 FPGA 上的 RV32M 首版实现，我们优先选择 **基 4 SRT**。

原因很直接：

- 每轮产生 2 bit 商，32 位除法通常约 16 轮完成
- 商选择表较小，组合逻辑容易控制
- 余数更新路径比高基数 SRT 更短
- 不依赖 DSP，适合作为独立整数执行单元
- 验证复杂度明显低于基 8、基 16 或 Newton 方案

不同方案的大致取舍如下：

| 方案 | 每轮商位 | 典型周期 | 资源压力 | 时序压力 | 适合场景 |
| --- | ---: | ---: | --- | --- | --- |
| 恢复/不恢复除法 | 1 bit | 32+ | 低 | 低 | 极简实现 |
| 基 4 SRT | 2 bit | 16 左右 | 中低 | 中低 | RV32M 首版 |
| 基 8 SRT | 3 bit | 11 左右 | 中 | 中高 | 性能优化版 |
| 基 16 SRT | 4 bit | 8 左右 | 高 | 高 | 更激进实现 |
| Newton 迭代 | 多 bit | 少 | 依赖乘法器/DSP | 中高 | 高吞吐设计 |

本项目的策略是：**先把基 4 SRT 做正确、做干净、做可测，再考虑更高基数或 DSP 迭代优化。**

## 外部接口

第一版除法核心建议采用 `valid/ready` 风格的简单握手协议：

```verilog
module rv32m_srt_divider (
  input         clk,
  input         rst_n,

  input         in_valid,
  output        in_ready,
  input  [1:0]  in_op,
  input  [31:0] in_rs1,
  input  [31:0] in_rs2,

  output        out_valid,
  input         out_ready,
  output [31:0] out_result,

  output        out_div_by_zero,
  output        out_overflow
);
```

建议操作编码：

```text
2'b00: DIV
2'b01: DIVU
2'b10: REM
2'b11: REMU
```

握手规则：

- `in_valid && in_ready` 时，模块接收一条新的除法请求
- 计算期间 `in_ready` 拉低，表示当前除法器忙
- `out_valid` 拉高时，`out_result` 和状态信号有效
- `out_valid && out_ready` 后，本次结果被接收，模块返回空闲或接收下一条请求

`out_div_by_zero` 和 `out_overflow` 是调试/验证状态信号，不是架构异常信号。

## RISC-V 除法语义

RISC-V M 扩展对除 0 和有符号溢出有明确规定。它们不会触发异常跳转，不会写 `mcause`，也不要求 CSR 参与处理。

### 除 0

当 `rs2 == 0` 时：

| 指令 | 结果 |
| --- | --- |
| `DIV` | `32'hffff_ffff` |
| `DIVU` | `32'hffff_ffff` |
| `REM` | `rs1` |
| `REMU` | `rs1` |

### 有符号溢出

RV32 中唯一的有符号除法溢出情况是：

```text
rs1 = 32'h8000_0000    // -2^31
rs2 = 32'hffff_ffff    // -1
```

此时结果为：

| 指令 | 结果 |
| --- | --- |
| `DIV` | `32'h8000_0000` |
| `REM` | `32'h0000_0000` |

`DIVU` 和 `REMU` 是无符号指令，不存在有符号溢出。

### 正常有符号运算

`DIV` 的商向 0 舍入，`REM` 的余数满足：

```text
rs1 = rs2 * quotient + remainder
```

并且有符号余数的符号与被除数 `rs1` 一致。

## 内部结构规划

第一版核心可以拆成以下模块：

```text
rtl/
|-- rv32m_srt_divider.v      # 顶层控制、握手、特殊情况处理
|-- rv32m_srt_preprocess.v   # 符号处理、绝对值、结果符号记录
|-- rv32m_srt_qds.v          # radix-4 商选择逻辑
|-- rv32m_srt_iter.v         # 余数迭代更新
`-- rv32m_srt_postprocess.v  # 商/余数修正与符号恢复
```

推荐状态机：

```text
IDLE
  |
  v
PREPARE
  |
  +--> SPECIAL_RETURN
  |
  v
ITERATE
  |
  v
POSTPROCESS
  |
  v
OUTPUT
```

其中：

- `IDLE`：等待输入请求
- `PREPARE`：判断指令类型、符号、除 0、溢出
- `SPECIAL_RETURN`：对除 0和溢出直接返回规定结果
- `ITERATE`：执行基 4 SRT 迭代
- `POSTPROCESS`：商转换、余数修正、符号恢复
- `OUTPUT`：等待下游接收结果

## 验证计划

验证是这个项目的重点之一。除法器很容易在符号、边界值和余数修正上出错，因此测试需要覆盖充分。

建议测试目录：

```text
tb/
|-- tb_rv32m_srt_divider.sv
|-- ref_rv32m_div.py
`-- test_vectors/
```

验证分层：

1. 定向测试
   - 除数为 0
   - `-2^31 / -1`
   - 正数除正数、正数除负数、负数除正数、负数除负数
   - 商为 0、商为 1、余数为 0
   - `0x0000_0000`、`0x7fff_ffff`、`0x8000_0000`、`0xffff_ffff`

2. 随机测试
   - 随机生成 `rs1`、`rs2`、`op`
   - 使用软件参考模型计算期望结果
   - 自动比对 RTL 输出

3. 指令级测试
   - 后续接入 CPU 后运行 RV32M 指令测试
   - 检查寄存器写回、流水线阻塞和数据相关

## 推荐仓库结构

```text
riscv-srtdiv/
|-- README.md
|-- rtl/
|   |-- rv32m_srt_divider.v
|   |-- rv32m_srt_qds.v
|   `-- rv32m_srt_iter.v
|
|-- tb/
|   |-- tb_rv32m_srt_divider.sv
|   `-- ref_rv32m_div.py
|
|-- docs/
|   |-- algorithm.md
|   `-- interface.md
|
`-- scripts/
    `-- run_sim.ps1
```

## 开发路线

- [ ] 定义顶层接口和操作编码
- [ ] 完成 RV32M 特殊情况处理
- [ ] 完成符号预处理和结果符号恢复
- [ ] 完成基 4 SRT 商选择逻辑
- [ ] 完成迭代余数更新和计数控制
- [ ] 完成商转换与余数修正
- [ ] 编写 SystemVerilog testbench
- [ ] 编写 Python 参考模型
- [ ] 完成定向测试和随机测试
- [ ] FPGA 综合，评估 LUT/FF/时钟频率
- [ ] 接入 RV32IM CPU 流水线

## 设计原则

- **语义优先**：严格遵守 RISC-V M 扩展定义。
- **先稳后快**：先实现可靠的基 4 SRT，再做基数提升或流水化优化。
- **接口独立**：除法器本身不绑定某个 CPU 微架构。
- **便于观察**：保留除 0、溢出、busy、valid 等调试信息。
- **适合 FPGA**：避免过深组合路径，优先保证可综合、可收敛、可验证。

## License

本项目建议使用 MIT License 或 Apache License 2.0。若后续引入第三方代码或参考实现，应在对应文件中保留原始版权和许可证说明。
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
