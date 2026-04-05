# Coral 工程入门与结构说明

这份文档只保留 Coral 工程本身的定位、结构、构建与入门信息。

如果你现在关注的是矩阵扩展主线，请看：

- [coral.md](./coral.md)

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
