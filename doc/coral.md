# CoralNPU 学习笔记

## 当前进度

- 已完成仓库整体结构梳理
- 已完成 `matadd` 自定义指令第一版实现
- 已完成 RTL 单元级验证
- 已完成 `program.cc + .insn` 程序级验证
- 已完成 Verilator 与 VCS cocotb 验证
- 已完成 VCS + Verdi 波形观察

## 下一步计划

1. 扩充 `matadd` 的程序级测试 case
2. 继续增加一条最小 custom 指令，如 `matsub`
3. 开始规划第二版“真正矩阵扩展”的接口与执行模型

## 工程定位

这个仓库不是单纯一份 RTL，而是一套“完整可落地的 CoralNPU 硬件平台”。它把这些内容放在一起：

- NPU 核心 RTL
- SoC 互连与地址空间
- FPGA 封装
- bare-metal 软件
- 工具链与构建规则
- 仿真与验证环境

入口建议先看：

- `README.md`
- `doc/overview.md`

目标大致是一个面向低功耗 ML 推理的 RISC-V NPU，ISA 约为 `rv32imf_zve32x_zicsr_zifencei_zbb`。默认本地存储为 8KB ITCM 和 32KB DTCM。

## 代码结构总览

### 核心 RTL

核心硬件主目录是 `hdl/chisel/src/coralnpu`。

- `Core.scala`
  顶层拼装关系，`Core = SCore + 可选 RvvCore`
- `scalar/SCore.scala`
  标量前端主体，串起 `Fetch / Dispatch / CSR / LSU / RetirementBuffer / ALU / BRU / MLU / DVU / Float`
- `doc/microarch/microarch.md`
- `doc/microarch/dispatch.md`
- `doc/microarch/lsu.md`

一个关键特点是：这不是“全 Chisel”方案。

- 标量骨架与 SoC 主要是 Chisel
- RVV 前端桥接在 `rvv/RvvCore.scala`
- 大量 RVV 后端资源在 `hdl/verilog/rvv/design` 和 `hdl/verilog/rvv/inc`

所以它更像：

- `Chisel 标量/SoC 骨架`
- `复用成熟 Verilog RVV 后端`

### SoC 集成

SoC 主目录是 `hdl/chisel/src/soc`。

- `SoCChiselConfig.scala`
- `CrossbarConfig.scala`
- `CoralNPUXbar.scala`
- `CoralNPUChiselSubsystem.scala`

这里最值得注意的是“数据驱动配置”：

- 模块有哪些
- 谁连谁
- 地址空间怎么分

都可以从配置里直接看出来。

FPGA 顶层还会在 `fpga/rtl/coralnpu_soc.sv` 中，把 Chisel 子系统与 ROM、SRAM、UART、I2C、TLUL 外设、DDR AXI 口拼起来。

### 构建与软件

构建主线是 Bazel。

- 规则入口：`rules/coralnpu_v2.bzl`
- 核心软件规则：`coralnpu_v2_binary`

它不是普通 `cc_binary`，而是会：

- 切换到 CoralNPU 专用 toolchain
- 生成 linker script
- 产出 `.elf / .bin / .vmem`

入门可看：

- `examples/BUILD.bazel`
- `doc/tutorials/writing_coralnpu_programs.md`

如果想看更高层的软件-仿真闭环，可看：

- `sw/coralnpu_sim/BUILD`
- `tests/npusim_examples/BUILD`
- `doc/tutorials/npusim_mobilenet_tutorial.md`

### 验证体系

验证是分层的：

- Chisel 单元测试
- `tests/cocotb/BUILD`
  cocotb + Verilator / VCS
- `tests/verilator_sim/BUILD`
- `hw_sim/BUILD`
- `tests/uvm/README.md`
- `hdl/verilog/rvv/sve`

也就是说，这个仓库既能做架构开发，也能做比较完整的验证回归。

## 推荐入门顺序

1. `README.md` + `doc/overview.md`
   先建立全景
2. `Core.scala` + `scalar/SCore.scala`
   先看核心流水线拼装
3. `doc/microarch/dispatch.md` + `doc/microarch/lsu.md`
   看 dispatch 和 LSU 细节
4. `hdl/chisel/src/soc/*`
   看 SoC 互连与地址图
5. `rules/coralnpu_v2.bzl` + `doc/tutorials/writing_coralnpu_programs.md`
   看软件构建与 bare-metal 程序入口
6. `tests/cocotb/BUILD`
   找最小可跑验证目标

## 常用命令索引

```bash
# 标量单元测试
bazel test //hdl/chisel/src/coralnpu:coralnpu_scalar_tests

# 编译 tutorial 程序
bazel build //tests/cocotb/tutorial:coralnpu_v2_program

# Verilator cocotb 验证
bazel run //tests/cocotb/tutorial:tutorial

# VCS cocotb 验证
bazel test --config=vcs //tests/cocotb/tutorial:vcs_tutorial_core_mini_axi_tutorial --test_output=all

# 保留 sandbox，便于用 Verdi 打开波形
bazel test --config=vcs //tests/cocotb/tutorial:vcs_tutorial_core_mini_axi_tutorial --test_output=all --sandbox_debug --cache_test_results=no
```

## Chisel 生成 Verilog 的位置与拆分方式

当前这个仓库里，Chisel 生成出来的 Verilog 默认不回写源码目录，而是放在 Bazel 输出目录：

- `1-RTL/coralnpu/bazel-bin/...`

需要注意，直接执行：

```bash
find bazel-bin/hdl/chisel/src -name '*.sv'
```

通常会看到很多结果，但其中大部分并不是“顶层 emit 出来的单独 RTL 文件”，而是：

- `_scalac/...`
  Scala/Chisel 构建过程中带出的资源文件、外部 Verilog 依赖
- `runfiles/...`
  测试或 Verilator 运行时依赖

真正和自己当前顶层最相关的，通常是 Bazel 包目录顶层的输出文件。

### 单文件输出

以 `CoreMiniAxi` 为例：

```bash
bazel build //hdl/chisel/src/coralnpu:core_mini_axi_cc_library_emit_verilog
```

生成的合并版顶层文件在：

- `bazel-bin/hdl/chisel/src/coralnpu/CoreMiniAxi.sv`

这个文件会把当前顶层相关 module 合并在一个 `.sv` 里，适合直接喂给现有 Verilator / 下游流程。

### 拆分版目录输出

如果希望看到“一个 module 一个文件”的拆分版，可以执行：

```bash
bazel build //hdl/chisel/src/coralnpu:core_mini_axi_cc_library_split_verilog_dir
```

这条命令的作用不是跑测试，而是：

1. 先生成 `CoreMiniAxi` 的 Verilog
2. 再把 split-verilog 结果展开成一个目录产物

输出目录在：

- `bazel-bin/hdl/chisel/src/coralnpu/core_mini_axi_cc_library_split_verilog_dir/`

里面会看到类似：

- `Alu.sv`
- `DispatchV2.sv`
- `SCore.sv`
- `CoreMini.sv`
- `DBus2AxiV2.sv`

也就是说，这个目录更适合阅读、定位模块、对比修改前后的 RTL。

### 推荐查找方式

如果只想看“真正的 emit 结果”，建议先排除 `_scalac` 和 `runfiles`：

```bash
find bazel-bin/hdl/chisel/src -name '*.sv' \
  ! -path '*/_scalac/*' \
  ! -path '*/runfiles/*'
```

如果只关心 `CoreMiniAxi` 的拆分版：

```bash
find bazel-bin/hdl/chisel/src/coralnpu/core_mini_axi_cc_library_split_verilog_dir -maxdepth 1 -name '*.sv'
```

## 学习路线与最小任务

如果是第一次系统接触这个仓库，最稳的路线不是直接做完整矩阵单元，而是先学会“给 CPU 加一条很小的新指令”，再考虑真正的矩阵扩展。因为一个完整矩阵扩展通常会同时涉及：

- 指令编码
- 解码与 dispatch
- 执行单元
- 写回路径
- hazard / scoreboard
- 测试
- 软件侧指令生成方式

作为第一阶段，建议走 **路线 A：最小教学版**：

- 不增加新寄存器文件
- 先做一两条 custom 指令
- 输入来自 `rs1/rs2`
- 输出写回 `rd`

### 推荐阅读顺序

1. `doc/overview.md`
   建立全局图景，先知道仓库里有哪些层次。
2. `doc/microarch/microarch.md`
   理解 `fetch -> decode/dispatch -> execute/writeback` 主线。
3. `doc/microarch/dispatch.md`
   重点理解新指令为什么不只是“能 decode”就够了。
4. `doc/microarch/mlu.md`
   把 MLU 当成执行单元模板来读。

### 推荐先看的源码

- `hdl/chisel/src/coralnpu/scalar/Decode.scala`
  决定 32 位指令编码如何被识别和分类。
- `hdl/chisel/src/coralnpu/scalar/Alu.scala`
  最适合作为第一条自定义指令的执行模板。
- `hdl/chisel/src/coralnpu/scalar/Mlu.scala`
  适合学习多周期执行单元的接口和流水。
- `hdl/chisel/src/coralnpu/scalar/MluTest.scala`
  适合学习 Chisel 单元测试写法。
- `hdl/chisel/src/coralnpu/Core.scala`
  用来理解标量核与 RVV 核的顶层拼装关系。

### 第一版目标

第一版建议固定成：

- 指令名：`matadd rd, rs1, rs2`
- 语义：`rd = rs1 + rs2`
- 执行单元：复用 ALU

它的目的不是实现真正的矩阵计算，而是跑通整条链路：

- 指令编码
- Decode
- Dispatch
- Execute
- Writeback
- 测试

### 第一版最少改动点

1. `Decode.scala`
   - 新增 `matadd` 解码位
   - 添加自定义 `BitPat`
   - 在 dispatch 中把 `matadd` 映射到 `AluOp.MATADD`
2. `Alu.scala`
   - 在 `AluOp` 中新增 `MATADD`
   - 在 `MuxLookup` 中实现 `MATADD -> rs1 + rs2`
3. `AluTest.scala`
   - 新增最小单元测试
   - 验证 `3 + 5 = 8`

### 编码选择

第一版建议使用 **RISC-V custom-0 opcode**，不要抢标准指令编码：

- `opcode = 0001011` (`custom-0`)

这样最干净：

- `funct7` 区分矩阵/自定义子类
- `funct3` 区分具体操作
- `rs1/rs2/rd` 继续复用标准 R-type 位置

第一阶段只要做到“不与现有指令冲突”即可。

### 第一周最小里程碑

1. 看懂 `mul` 是怎么走的
   - 重点看 `Decode.scala` 和 `Mlu.scala`
2. 看懂 ALU 是怎么写回的
   - 重点看 `Alu.scala`
3. 给 ALU 增加一个新 op：`MATADD`
4. 跑通标量单测

命令：

```bash
bazel test //hdl/chisel/src/coralnpu:coralnpu_scalar_tests
```

### 一个现实建议

第一阶段不要急着让 C 代码直接写 `matadd(a, b)` 接口，更不要一开始就碰编译器扩展。先把硬件单测跑通，后面如果需要从软件侧发射这条指令，可以先用：

- `.word 0x...`
- 或 `.insn ...`

这种方式做验证，比改 GCC/binutils 简单很多。


## matadd 实验记录（已完成）

这次实验的目标不是实现真正的矩阵乘法，而是完整打通一条最小自定义指令链路：

- 指令名：`matadd`
- 第一版功能：`rd = rs1 + rs2`
- 路线：复用现有 ALU
- 验证目标：从 RTL 单测一直走到程序级 VCS cocotb 验证

### 指令定义

这一版把 `matadd` 定义成一条 **RISC-V custom-0** 指令，采用标准 R-type 格式：

- `opcode = 0001011` (`custom-0`)
- `funct3 = 000`
- `funct7 = 0101010` (`0x2A`)

编码格式：

```text
[31:25] funct7 = 0101010
[24:20] rs2
[19:15] rs1
[14:12] funct3 = 000
[11:7]  rd
[6:0]   opcode = 0001011
```

语义：

```text
x[rd] = (x[rs1] + x[rs2]) mod 2^32
```

例子：

- `matadd x3, x1, x2` -> `0x5420818b`
- `matadd x7, x5, x6` -> `0x5462838b`

### 实际改动点

这次实验最后落到 4 个核心位置：

1. `hdl/chisel/src/coralnpu/scalar/Alu.scala`
   - 在 `AluOp` 中新增 `MATADD`
   - 在 `MuxLookup` 中实现 `AluOp.MATADD -> (rs1 + rs2)`

2. `hdl/chisel/src/coralnpu/scalar/Decode.scala`
   - 在 `DecodedInstruction` 中新增 `matadd`
   - 增加解码规则：

   ```scala
   d.matadd := op === BitPat("b0101010_?????_?????_000_?????_0001011")
   ```

   - 在 ALU dispatch 中增加：

   ```scala
   d.matadd -> MakeValid(true.B, AluOp.MATADD)
   ```

   - 把 `d.matadd` 放进 `decoded = Cat(...)`

3. `hdl/chisel/src/coralnpu/scalar/AluTest.scala`
   - 新增 `MATADD` 单元测试

4. `hdl/chisel/src/coralnpu/scalar/DispatchTest.scala`
   - 新增 `DispatchV2` 测试
   - 直接验证 `matadd` 机器码是否被送到 `ALU`

### RTL 单元级验证

先跑标量单元测试：

```bash
bazel test //hdl/chisel/src/coralnpu:coralnpu_scalar_tests --test_output=all
```

最终结果：

- `AluSpec` 中 `MATADD` 通过
- `ScalarDispatchSpec` 中 `Dispatch MATADD to ALU` 通过
- 全部 `22 / 22` 测试通过

这一步说明两件事：

- `MATADD` 在 ALU 内部执行逻辑正确
- `matadd` 的机器码已经能被 `DispatchV2` 正确识别并派发到 `ALU`

### 程序级验证：`program.cc + .insn`

在 `tests/cocotb/tutorial/program.cc` 中，最终采用 `inline asm + .insn` 的方式从软件侧发射这条自定义指令，而不是先改 GCC/binutils。

核心写法如下：

```cpp
static inline uint32_t matadd(uint32_t a, uint32_t b) {
  uint32_t out;
  asm volatile(
      ".insn r 0x0b, 0x0, 0x2a, %0, %1, %2\n"
      : "=r"(out)
      : "r"(a), "r"(b));
  return out;
}
```

这里：

- `0x0b` 对应 `custom-0`
- `0x0` 对应 `funct3`
- `0x2a` 对应 `funct7`

#### 补充理解：`.insn` 到底是什么

`.insn` 是 GNU 汇编器提供的一个伪指令，用来“手工描述并生成一条机器指令”。

它适合当前这种场景：

- 硬件里已经实现了自定义指令
- 但 GCC / binutils 还没有正式支持 `matadd` 这个助记符
- 这时可以先不改编译器，直接告诉汇编器按指定格式把机器码拼出来

这一句：

```cpp
.insn r 0x0b, 0x0, 0x2a, %0, %1, %2
```

含义是：

- `r`
  按 R-type 指令格式编码
- `0x0b`
  `opcode = custom-0`
- `0x0`
  `funct3`
- `0x2a`
  `funct7`
- `%0`
  放到 `rd`
- `%1`
  放到 `rs1`
- `%2`
  放到 `rs2`

也就是按下面这个 R-type 位布局去组一条指令：

```text
 31          25 24    20 19    15 14   12 11     7 6       0
+--------------+--------+--------+-------+---------+---------+
|   funct7     |  rs2   |  rs1   |funct3 |   rd    | opcode  |
|   0101010    |   %2   |   %1   | 000   |   %0    | 0001011 |
+--------------+--------+--------+-------+---------+---------+
```

#### 补充理解：`%0 / %1 / %2` 为什么正好对应 `rd / rs1 / rs2`

GCC inline asm 的写法是：

```cpp
asm volatile("..."
    : 输出操作数
    : 输入操作数
    : clobber);
```

在这段代码里：

```cpp
asm volatile(
    ".insn r 0x0b, 0x0, 0x2a, %0, %1, %2\n"
    : "=r"(out)
    : "r"(a), "r"(b));
```

操作数编号规则是“先输出，再输入”，所以：

- `%0` = 第 1 个输出操作数 = `out`
- `%1` = 第 1 个输入操作数 = `a`
- `%2` = 第 2 个输入操作数 = `b`

而约束字符串：

- `"=r"(out)`
  表示给 `out` 分配一个通用寄存器，并作为写输出
- `"r"(a)`
  表示给 `a` 分配一个通用寄存器
- `"r"(b)`
  表示给 `b` 分配一个通用寄存器

所以编译器实际做的事情就是：

- 给 `out` 分一个寄存器，作为 `rd`
- 给 `a` 分一个寄存器，作为 `rs1`
- 给 `b` 分一个寄存器，作为 `rs2`

换句话说，这段代码不是固定写死 `x3/x1/x2`，而是让编译器自由分配寄存器，再由 `.insn` 按 `rd/rs1/rs2` 的位置把它们编码进 `matadd` 指令。

先编译程序：

```bash
bazel build //tests/cocotb/tutorial:coralnpu_v2_program
```

编译成功后会生成：

- `coralnpu_v2_program.elf`
- `coralnpu_v2_program.bin`
- `coralnpu_v2_program.vmem`

需要注意：`coralnpu_v2_binary` 这条规则内部用了 Bazel 的平台切换，所以这三个产物 **不一定直接显示在** `bazel-bin/tests/cocotb/tutorial/` 下面。

在当前仓库里，实际更常见的两个位置是：

- `bazel-out/k8-fastbuild-ST-*/bin/tests/cocotb/tutorial/`
- 某个测试 runner 的 runfiles 目录，例如：
  - `bazel-bin/tests/cocotb/tutorial/tutorial_cocotb_runner.sh.runfiles/coralnpu_hw/tests/cocotb/tutorial/`
  - `bazel-bin/tests/cocotb/tutorial/vcs_tutorial_core_mini_axi_tutorial_cocotb_runner.sh.runfiles/coralnpu_hw/tests/cocotb/tutorial/`

如果想稳妥定位，推荐直接查：

```bash
find bazel-out -path '*tests/cocotb/tutorial/coralnpu_v2_program.elf'
find bazel-out -path '*tests/cocotb/tutorial/coralnpu_v2_program.bin'
find bazel-out -path '*tests/cocotb/tutorial/coralnpu_v2_program.vmem'
```

这一步说明：

- `program.cc` 能被 CoralNPU 专用 toolchain 编译
- `.insn` 写法被当前工具链接受

#### 常用查看命令：反汇编与符号表

如果想看 ELF 里的汇编，可用：

```bash
/opt/riscv/bin/riscv64-unknown-elf-objdump -dS bazel-bin/tests/cocotb/tutorial/coralnpu_v2_program.elf | less
```

这里：

- `-d`
  反汇编
- `-S`
  把源码行和汇编穿插显示

如果只想看 `main` 附近：

```bash
/opt/riscv/bin/riscv64-unknown-elf-objdump -dS bazel-bin/tests/cocotb/tutorial/coralnpu_v2_program.elf | sed -n '/<main>:/,+12p'
```

这时通常能看到：

- `lw` 从 `input1_buffer/input2_buffer` 读数据
- 一条显示为 `.insn ...` 的未知指令
- 这条未知指令实际上就是自定义的 `matadd`

例如这次看到的是：

```text
154:   54d7070b                .insn   4, 0x54d7070b
```

如果想看符号表，可用：

```bash
/opt/riscv/bin/riscv64-unknown-elf-nm -n bazel-bin/tests/cocotb/tutorial/coralnpu_v2_program.elf
```

符号表最重要的作用是确认：

- `main` 在什么地址
- `input1_buffer`
- `input2_buffer`
- `output_buffer`

例如这次的结果里：

```text
00000144 T main
00010000 D input1_buffer
00010004 D input2_buffer
00010008 D output_buffer
```

这能直接帮助理解：

- `main` 的入口位置
- 三个全局 buffer 在 `.data` 段里的实际地址布局

### cocotb 验证

在 `tests/cocotb/tutorial/tutorial.py` 中，测试流程是：

1. 载入 `coralnpu_v2_program.elf`
2. 用 `lookup_symbol` 找到 `input1_buffer`、`input2_buffer`、`output_buffer`
3. 向 DTCM 写入输入数据 `3` 和 `5`
4. 从 ELF 入口启动程序
5. 等待 core halt
6. 读回 `output_buffer`
7. 断言结果等于 `8`

### Verilator 与 VCS 运行命令

#### Verilator

```bash
bazel run //tests/cocotb/tutorial:tutorial
```

运行结果打印：

```text
I got [8]
```

#### VCS

这个仓库默认在 `.bazelrc` 里屏蔽了 `vcs` tag，所以跑 VCS 时必须显式加 `--config=vcs`：

```bash
bazel test --config=vcs //tests/cocotb/tutorial:vcs_tutorial_core_mini_axi_tutorial --test_output=all
```

实际运行结果：

```text
Running on Chronologic Simulation VCS Release version ...
I got [8]
tutorial.core_mini_axi_tutorial passed
```

这一步说明：

- 程序级 `matadd` 验证已经在 **VCS** 上通过
- 从软件发射自定义指令到 RTL 执行再到结果读回，链路完整正确

### VCS + Verdi 波形观察

为了在 Verdi 里看到 `matadd` 的实际执行波形，需要重新运行一次 VCS，并保留 `sim_build`：

```bash
bazel test --config=vcs //tests/cocotb/tutorial:vcs_tutorial_core_mini_axi_tutorial --test_output=all --sandbox_debug --cache_test_results=no
```

波形文件可以用下面命令定位：

```bash
find ~/.cache/bazel/_bazel_$USER -path '*vcs_tutorial_core_mini_axi_tutorial_cocotb_runner.sh.runfiles/coralnpu_hw/sim_build/novas.fsdb'
```

进入 `sim_build` 后，用 Verdi 打开：

```bash
verdi -dbdir simv.daidir -ssf novas.fsdb &
```

这次观察最有用的一组信号是：

- `io_debug_dispatch_0_instInst`
- `decodedInsts_0_matadd`
- `_dispatch_io_alu_0_bits_op`
- `_regfile_io_readData_0_data`
- `_regfile_io_readData_1_data`
- `_alu_0_io_rd_bits_data`
- `io_debug_regfile_writeData_0_bits_data`

当前 `program.cc` 生成出来的那条 `matadd` 指令字，在这次实验里实际观察到的是：

- `0x54d7070b`

在波形里可以按下面这条链确认 `matadd` 已经真正跑通：

- `io_debug_dispatch_0_instInst == 32'h54d7070b`
- `decodedInsts_0_matadd == 1`
- `_dispatch_io_alu_0_bits_op == 5'h1`
- `_regfile_io_readData_0_data == 3`
- `_regfile_io_readData_1_data == 5`
- `_alu_0_io_rd_bits_data == 8`
- `io_debug_regfile_writeData_0_bits_data == 8`

这一步的意义是：不仅程序级结果正确，而且已经能在 `VCS + Verdi` 下直接看到 `matadd` 从取指、解码、派发、ALU 执行到写回的完整波形链路。

### 最终结论

这次 `matadd` 第一版实验已经完成了完整闭环：

- 自定义指令编码已定义
- Decode / Dispatch / ALU / Writeback 已接通
- 标量 RTL 单测通过
- `program.cc + .insn` 软件侧发射成功
- Verilator cocotb 程序级验证通过
- VCS cocotb 程序级验证通过

换句话说，这已经不只是“代码改好了”，而是：

**这个自定义指令已经被真实地编译、加载、执行，并且在 VCS 中验证得到正确结果 `8`。**

### 下一步建议

这次最小闭环做完后，后续可以沿三条路继续：

1. 扩充 `matadd` 的程序级 case
   - 例如 `0xffffffff + 1 -> 0`
   - 多组输入循环测试

2. 继续增加自定义指令
   - 如 `matsub`
   - 或者规划一个 `matmul` 原型编码

3. 开始考虑“真正矩阵扩展”的第二版设计
   - 输入放哪
   - 是否需要多周期执行
   - 是否需要独立状态/寄存器/accumulator

## 在 Coral 中实现矩阵扩展的计划表

当前最适合的思路不是一开始就改 RVV 大核，也不是先并编译器，而是先在 Coral 标量前端里增加一套独立的 `matrix extension` 通路，再逐步向玄铁矩阵扩展靠拢。

### 实施原则

- 先做 `subset`，不要第一版就追完整 Xuantie matrix spec
- 先做 RTL + CSR + 最小指令闭环，再考虑 toolchain / intrinsic
- 不修改 generated RVV 大文件，优先改 Chisel 源码
- 不把矩阵操作长期塞在普通 `ALU` 里，要单独建 `MatrixUnit`

### 第一版目标

第一版建议只做一个可运行、可验证、可扩展的最小子集：

- 数据类型先固定为 `int32`
- 固定参数：
  - `ELEN = 32`
  - `TLEN = 512`
  - `TRLEN = 128`
- 先实现 matrix CSR：
  - `xmcsr`
  - `mtilem`
  - `mtilen`
  - `mtilek`
  - `xmisa`
  - `xtlenb`
  - `xtrlenb`
  - `xalenb`
- 先实现 matrix 指令子集：
  - `msettilem`
  - `msettilen`
  - `msettilek`
  - `mld`
  - `mst`
  - `mmacc`
- `matadd` 先从“普通 ALU 占位操作”逐步迁到独立 matrix 通路

### 现有可复用入口

当前 Coral 已经有几个很好的挂点：

- 参数开关入口：
  - `hdl/chisel/src/coralnpu/Parameters.scala`
- CSR 解码与状态保存：
  - `hdl/chisel/src/coralnpu/scalar/Csr.scala`
- 自定义指令 decode：
  - `hdl/chisel/src/coralnpu/scalar/Decode.scala`
- 当前 `matadd` 占位实现：
  - `hdl/chisel/src/coralnpu/scalar/Alu.scala`
- 标量核心拼装：
  - `hdl/chisel/src/coralnpu/scalar/SCore.scala`
- 顶层拼装：
  - `hdl/chisel/src/coralnpu/Core.scala`

所以路线应该是：

- 先加 `enableMatrix`
- 再加 matrix CSR
- 再加 `MatrixUnit`
- 再把 `matadd` 和后续 matrix 指令接进去

### 分阶段计划

#### P0：冻结第一版规范

目标：

- 定义 Coral matrix v1 的最小兼容范围
- 明确第一版只做 Xuantie matrix `subset`

需要输出：

- 一份设计文档，建议新增 `doc/matrix_plan.md`

文档至少写清：

- CSR 列表
- 指令列表
- tile / acc 寄存器模型
- 异常策略
- 第一版不支持的内容

#### P1：增加 matrix 参数开关

目标：

- 在参数系统里正式引入 matrix extension

建议修改：

- `hdl/chisel/src/coralnpu/Parameters.scala`

建议增加：

- `enableMatrix`
- `matrixElen`
- `matrixTlen`
- `matrixTrlen`
- `matrixTileRegCount`
- `matrixAccRegCount`

建议默认值：

- `enableMatrix = false`
- `matrixElen = 32`
- `matrixTlen = 512`
- `matrixTrlen = 128`
- `matrixTileRegCount = 4`
- `matrixAccRegCount = 4`

验收标准：

- 代码可 elaboration
- 顶层可以通过参数打开或关闭 matrix

#### P2：增加 matrix CSR 配置面

目标：

- 让软件可以读写 matrix 配置状态

建议修改：

- `hdl/chisel/src/coralnpu/scalar/Csr.scala`

建议做法：

- 新增 Xuantie 风格 matrix CSR 地址和状态寄存器
- 第一版允许 CSR 直接读写 `mtilem / mtilen / mtilek`
- `KISA` 中加入 matrix capability bit

建议第一版 CSR：

- `xmcsr`
- `mtilem`
- `mtilen`
- `mtilek`
- `xmisa`
- `xtlenb`
- `xtrlenb`
- `xalenb`

验收标准：

- 软件可通过 `csrr/csrw` 正常访问 matrix CSR
- 仿真中可以观察到 CSR 状态变化

#### P3：建立独立 matrix 接口

目标：

- 不再把 matrix 扩展长期混在 `ALU` 语义里

建议新增目录：

- `hdl/chisel/src/coralnpu/matrix/`

建议新增文件：

- `MatrixInterface.scala`

第一版建议定义：

- `MatrixConfigState`
- `MatrixCmd`
- `TileRegWriteDataIO`
- `AccRegWriteDataIO`
- `MatrixFaultInfo`

验收标准：

- matrix 通路的接口独立成型
- 不依赖 RVV 内部实现细节

#### P4：扩展 Decode

目标：

- 在 decode 中正式识别 matrix 指令

建议修改：

- `hdl/chisel/src/coralnpu/scalar/Decode.scala`

建议增加：

- `isMatrix()`
- `writesMatrixReg()`
- `readsMatrixReg()`
- `isMatrixLoadStore()`

并新增第一版指令识别：

- `msettilem`
- `msettilen`
- `msettilek`
- `mld`
- `mst`
- `mmacc`

当前已有：

- `matadd`

建议：

- 把 `matadd` 作为 matrix 通路的过渡入口

验收标准：

- matrix 指令不落到 `undef`
- dispatch 能把 matrix 指令分到独立端口

#### P5：建立 MatrixUnit 空壳

目标：

- 先把 matrix 执行通路搭起来

建议新增：

- `hdl/chisel/src/coralnpu/matrix/MatrixUnit.scala`

第一版空壳功能：

- 接收 `MatrixCmd`
- 接收 `MatrixConfigState`
- 输出 `ready / valid / busy / trap`
- 先不做复杂计算

验收标准：

- `SCore` 能实例化 `MatrixUnit`
- matrix 指令可进入该单元

#### P6：在 SCore / Core 中接线

目标：

- 把 matrix unit 真的接入 Coral

建议修改：

- `hdl/chisel/src/coralnpu/scalar/SCore.scala`
- `hdl/chisel/src/coralnpu/Core.scala`

需要完成：

- dispatch 到 matrix unit 的连接
- 标量寄存器读操作数连接
- matrix fault 接入 fault manager
- 结果回写路径接入 retirement / regfile

验收标准：

- 顶层可综合 elaboration
- 波形中能看到 matrix 指令通过独立通路传播

#### P7：实现 tile / accumulator 寄存器文件

目标：

- 建立真正的矩阵状态存储

建议新增：

- `MatrixRegfile.scala`

第一版建议：

- `4` 个 tile 寄存器
- `4` 个 accumulator 寄存器

验收标准：

- CSR 与指令可以正确影响 tile shape
- tile / acc 数据可被读写

#### P8：实现 matrix load/store

目标：

- 支持矩阵数据在 DTCM 和 tile reg 之间搬运

建议新增：

- `MatrixLoadStore.scala`

建议策略：

- 第一版尽量复用现有 LSU / DTCM 通路
- 不一开始新做一套复杂总线协议

第一版支持：

- `mld`
- `mst`

验收标准：

- 可把 DTCM 数据装载进 tile reg
- 可把 tile reg 数据写回 DTCM

#### P9：实现最小计算 datapath

目标：

- 完成第一版真正有意义的矩阵算子

建议新增：

- `MatrixMac.scala`

第一版功能建议只做：

- `int32 mmacc`

验收标准：

- 能完成最小矩阵乘加
- 和软件 golden model 对比一致

#### P10：异常与状态管理

目标：

- 定义 matrix extension 的 fault 行为

建议处理：

- 非法 tile shape
- CSR 配置非法
- busy 冲突
- 未初始化 tile 访问
- 非法 matrix opcode

建议修改：

- `matrix/*`
- `scalar/FaultManager.scala`

验收标准：

- 非法使用时 fault 行为稳定且可重复

#### P11：软件 bring-up

目标：

- 先不依赖完整编译器，先把软件闭环跑起来

第一版建议：

- 继续使用 `.insn`
- 手写 matrix 汇编
- 先生成 `elf/bin/vmem`

建议测试内容：

- CSR 读写程序
- `msettile*` 程序
- `mld/mst` 程序
- `mmacc` 程序

验收标准：

- 能从 bare-metal 程序驱动 matrix CSR 和 matrix 指令

#### P12：工具链接入

目标：

- 在 RTL 跑通后，再考虑玄铁工具链能力

建议顺序：

1. 先接 `binutils/opcodes/objdump`
2. 再考虑 intrinsic
3. 最后考虑 GCC backend

注意：

- 建议“并入流程”，不要直接把整套 GCC 源码塞进 Coral 仓库
- 更适合把玄铁工具链作为外部工具链使用

验收标准：

- 汇编器能识别 matrix 指令
- `objdump` 能正确反汇编

#### P13：RTL 导出与综合

目标：

- 把 matrix 版本纳入现有 RTL 导出与综合流

需要完成：

- 增加带 matrix 开关的 emit 目标
- 增加 matrix 版本 Verilog 导出
- 更新综合脚本

验收标准：

- 能导出带 matrix 的 RTL
- 能进入综合流程

### 建议实施顺序

最适合现在马上开始的顺序是：

1. 写 `matrix_plan.md`，冻结第一版范围
2. 修改 `Parameters.scala`
3. 修改 `Csr.scala`
4. 新建 `matrix/MatrixInterface.scala`
5. 修改 `Decode.scala`
6. 新建 `matrix/MatrixUnit.scala`
7. 修改 `SCore.scala`
8. 修改 `Core.scala`
9. 写最小 CSR / decode / dispatch 测试

### 第一周目标

第一周建议只追求这几个结果：

- `enableMatrix` 参数加入系统
- matrix CSR 能读写
- matrix 指令能 decode
- `MatrixUnit` 空壳能接入顶层
- 仿真中能看到 matrix 指令进入独立通路

不要第一周就追：

- 完整 tile load/store
- 完整 `mmacc`
- GCC backend

### 第二周目标

- tile / acc regfile
- `msettilem/n/k`
- `mld / mst`
- 最小 `mmacc`

### 不建议的路线

- 不建议第一步直接改 generated RVV `.sv`
- 不建议第一步就并入完整玄铁 GCC
- 不建议长期把 matrix 逻辑继续塞在 `Alu.scala`
- 不建议第一版就追 full Xuantie ISA

### 里程碑

- `M1`：CSR 与 decode 打通
- `M2`：MatrixUnit 空壳接入完成
- `M3`：tile load/store 跑通
- `M4`：`mmacc` 计算正确
- `M5`：bare-metal 程序可驱动
- `M6`：RTL 可导出并可综合

### 玄铁工具什么时候用

玄铁矩阵扩展仓库里，当前最常见会接触到的三类工具/组件是：

- `spec/`
  规范文档
- `qemu/`
  模拟器 / 参考行为模型
- `xuantie-gnu-toolchain/riscv-binutils-gdb`
  汇编器、链接器、反汇编器、调试器
- `xuantie-gnu-toolchain/riscv-gcc`
  C/C++ 编译器

建议不要一开始就把这些都拉进 Coral 主开发路径，而是按阶段使用。

#### 当前阶段：只需要规范，不急着用工具链

如果当前目标是：

- 设计 Coral matrix extension 架构
- 增加 CSR
- 增加 decode
- 增加 `MatrixUnit`
- 先跑通最小 RTL 闭环

那么只需要重点看：

- `spec/csr.adoc`
- `spec/program_model.adoc`
- `spec/tilereg.adoc`

这个阶段可以暂时不用：

- `riscv-gcc`
- `riscv-binutils-gdb`
- `qemu`

也就是说，当前阶段主目标是“先把硬件接口和行为定下来”。

#### RTL 初步跑通后：开始用 qemu

当以下内容已经基本确定后：

- matrix CSR 已定义
- matrix 指令编码已冻结第一版
- tile / acc 模型已确定

这时开始看 `qemu/` 最有价值。

用途：

- 跑 matrix 程序
- 作为参考模型
- 对比 Coral 仿真结果
- 帮助检查指令和 CSR 行为是否合理

注意：

- `qemu` 不是用来替代 RTL 仿真的
- 它更像软件侧参考模型

#### 需要写助记符汇编时：开始用 binutils

当你不想一直用 `.insn`，而希望：

- 写 matrix 指令助记符
- 正确反汇编 ELF
- 检查编码和反汇编结果

这时开始看：

- `xuantie-gnu-toolchain/riscv-binutils-gdb`

这个阶段最有用的是：

- `as`
- `objdump`
- `ld`

也就是说，`binutils` 是在“软件可用性提升阶段”开始变得重要，而不是第一周必须接入。

#### 需要 intrinsic / C 编译支持时：再看 gcc

只有当下面这些都基本稳定后：

- matrix ISA 子集已经确定
- CSR 命名和行为不再频繁变化
- load/store / mmacc 已经跑通
- 你准备让 C 代码直接调用 matrix 能力

这时才应该开始看：

- `xuantie-gnu-toolchain/riscv-gcc`

主要目标：

- intrinsic
- builtin
- 编译器生成 matrix 指令

这个阶段成本最高，不建议提前做。

#### 当前结论

对当前 Coral matrix extension 项目，建议优先级是：

1. 先看 `spec/`
2. 先做 Coral RTL 和 CSR
3. 再看 `qemu`
4. 再看 `binutils`
5. 最后才看 `gcc`

一句话说：

- 规范现在就用
- `qemu` 在 RTL 第一版成型后用
- `binutils` 在想摆脱 `.insn` 时用
- `gcc` 在想支持 intrinsic / 自动编译时再用

### 外部参考

- Xuantie matrix CSR:
  - `https://github.com/XUANTIE-RV/riscv-matrix-extension-spec/blob/master/spec/csr.adoc`
- Xuantie programmer model:
  - `https://github.com/XUANTIE-RV/riscv-matrix-extension-spec/blob/master/spec/program_model.adoc`
- Xuantie tile / accumulator model:
  - `https://github.com/XUANTIE-RV/riscv-matrix-extension-spec/blob/master/spec/tilereg.adoc`


