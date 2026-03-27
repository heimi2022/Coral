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

### 这次实验踩到的关键坑

最关键的一次真实 bug 不是 ALU 逻辑，而是 decode 分类写错了。

一开始误把 `matadd` 放进了 `isAluImm()`，没有放进 `isAluReg()`。这样会导致：

- 指令虽然能被 decode 到
- dispatch 也能把它送到 ALU
- 但 decode 会把它当成“立即数 ALU 指令”
- 结果 `rs2` 不会按寄存器源操作数读取

最后修正方式是：

- 从 `isAluImm()` 中去掉 `matadd`
- 放进 `isAluReg()`

这也是为什么后来 `DispatchTest` 一开始会看到 `rs2Read_valid == 0`。

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

先编译程序：

```bash
bazel build //tests/cocotb/tutorial:coralnpu_v2_program
```

编译成功后会生成：

- `bazel-bin/tests/cocotb/tutorial/coralnpu_v2_program.elf`
- `bazel-bin/tests/cocotb/tutorial/coralnpu_v2_program.bin`
- `bazel-bin/tests/cocotb/tutorial/coralnpu_v2_program.vmem`

这一步说明：

- `program.cc` 能被 CoralNPU 专用 toolchain 编译
- `.insn` 写法被当前工具链接受

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
