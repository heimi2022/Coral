这个工程可以把它理解成一套“完整可落地的 CoralNPU 硬件平台”，不是单纯一份 RTL。它把 NPU 核心、SoC 互连、仿真、FPGA 封装、bare-metal 软件、工具链和验证环境都放在了一起。入口说明在 README.md 和 doc/overview.md：目标是一个面向低功耗 ML 推理的 RISC-V NPU，ISA 大致是 rv32imf_zve32x_zicsr_zifencei_zbb，标量、向量/SIMD 和矩阵能力是融合设计。默认本地存储是 8KB ITCM 和 32KB DTCM，外设/外存通过总线接入。

从代码结构看，最核心的硬件层在 hdl/chisel/src/coralnpu。顶层 Core.scala 很清楚地说明了拼装关系：Core = SCore + 可选 RvvCore。其中 scalar/SCore.scala 是真正的标量前端主体，里面把 Fetch / Dispatch / CSR / LSU / RetirementBuffer / ALU / BRU / MLU / DVU / 浮点 串起来；doc/microarch/microarch.md、doc/microarch/dispatch.md、doc/microarch/lsu.md 则补了流水线、派发规则和 LSU 细节。一个很关键的特点是，这个仓库不是“全 Chisel”方案：向量部分在 rvv/RvvCore.scala 里主要扮演 Chisel 到既有 SystemVerilog RVV 后端的桥接层，而真正庞大的 RVV 设计资源在 hdl/verilog/rvv/design 和 hdl/verilog/rvv/inc。这说明它的演进路径更像“Chisel 标量/SoC骨架 + 复用成熟 Verilog RVV 后端”。

系统集成层在 hdl/chisel/src/soc。我觉得这里是这个仓库最值得注意的地方之一：SoCChiselConfig.scala 和 CrossbarConfig.scala 把 SoC 中有哪些模块、谁连谁、地址空间怎么分配，做成了“数据驱动配置”；CoralNPUXbar.scala 再根据这些配置动态生成 TileLink UL 交叉开关、宽度转换和异步时钟域桥。默认地址图也能从这里直接看出来：coralnpu_device 占本地 ITCM/DTCM/CSR 窗口，外部还有 ROM、4MB SRAM、UART、SPI、GPIO、I2C、DMA、DDR 控制口和 DDR 内存窗口。整个 Chisel SoC 总装在 CoralNPUChiselSubsystem.scala，而 FPGA 顶层再在 fpga/rtl/coralnpu_soc.sv 里把这套 Chisel 子系统和 ROM、SRAM、UART、I2C、OpenTitan 风格 TLUL 外设以及 DDR AXI 口拼到一起。所以这仓库既有“核级 RTL”，也有“可直接上板子的 SoC 包装”。

构建和软件工作流以 Bazel 为主。WORKSPACE 里能看出依赖非常重，包括 Scala/Chisel、rules_hdl、OpenTitan、SystemC、pybind、TFLite Micro、mpact、预编译 RISC-V toolchain 等。软件编译不是普通 cc_binary，而是走 rules/coralnpu_v2.bzl 里的 coralnpu_v2_binary：它会切换到 CoralNPU 专用 toolchain，生成 linker script，最后产出 .elf/.bin/.vmem 三种工件。入门程序在 examples/BUILD.bazel 和 doc/tutorials/writing_coralnpu_programs.md；如果想看更高层的软件-仿真结合路径，可以看 sw/coralnpu_sim/BUILD、tests/npusim_examples/BUILD 和 doc/tutorials/npusim_mobilenet_tutorial.md：这里已经提供了 Python 侧通过 pybind/mpact 驱动 NPU 模拟器、向 ELF 符号地址写入输入张量、运行 TFLite Micro 模型再回读输出的闭环。

验证体系也很完整，而且是分层的。最底层有 Chisel 单元测试；更常用的是 tests/cocotb/BUILD 这条 cocotb + Verilator/VCS 路径，覆盖了标量核、RVV load/store、算术、异常、debug、TLUL 子系统等大量场景；C++/SystemC 风格的 Verilator 仿真在 tests/verilator_sim/BUILD 和 hw_sim/BUILD；偏传统 DV 的 UVM 环境在 tests/uvm/README.md；而 RVV 自己还有独立的 SV 验证环境在 hdl/verilog/rvv/sve。换句话说，这个仓库既能做架构开发，也能做比较严肃的验证回归。

如果你要上手，我建议按这个顺序读。先读 README.md 和 doc/overview.md 建立全景；想懂核心流水线就接着看 Core.scala、scalar/SCore.scala、doc/microarch/dispatch.md、doc/microarch/lsu.md；想懂 SoC 互连和地址图就看 CrossbarConfig.scala、SoCChiselConfig.scala、CoralNPUXbar.scala；想跑程序就看 rules/coralnpu_v2.bzl 和 doc/tutorials/writing_coralnpu_programs.md；想验证就从 tests/cocotb/BUILD 开始找最小可跑目标。

我这次主要做的是静态梳理，没有实际触发完整 Bazel 构建或回归，所以结论偏“代码结构与设计路径分析”，不是运行结果验证。如果你愿意，我下一步可以继续帮你做两种更深入的研究之一：一是“只啃 RTL 主线”，把 Fetch -> Dispatch -> LSU/RVV -> Retirement 逐模块画成一张中文结构图；二是“只啃构建和验证主线”，把最小可运行 target、依赖和调试入口整理成一份上手指南。







如果你是小白，我会建议你把目标分成两步：

1. 先学会“给这个 CPU 加一条很小的新指令”
2. 再把它扩展成真正的“矩阵扩展”

不要一开始就做完整矩阵单元，不然会同时撞上 ISA、解码、寄存器、流水线、hazard、软件工具链、验证，挫败感会很强。

**先建立正确预期**

在这个仓库里，“加一个矩阵扩展”通常不只是改一处代码，而是要同时碰这些层：

- 指令编码
- 解码逻辑
- dispatch/scoreboard
- 执行单元
- 写回路径
- 测试
- 可能还包括软件侧如何生成这条指令

也就是说，它更像“做一个小 feature”，不是“改一个参数”。

**这个项目里你先该看什么**

先看这几个文档，顺序很重要：

1. overview.md
   先建立全局图景。这里能看出 CoralNPU 本来就有 scalar、vector、matrix 三种能力。
2. microarch.md
   先理解流水线只有三大块：fetch -> decode/dispatch -> execute/writeback
3. dispatch.md
   这是你以后加新执行单元最容易踩坑的地方。新指令不是“decode 到了就能发”，还要考虑一个周期能发几条、资源冲突、是否阻塞后续指令。
4. mlu.md
   这是我最推荐你照着学的例子。MLU 是一个结构清晰、复杂度适中的执行单元，非常适合拿来当“加新单元”的模板。

**你该从哪几个源码文件入手**

把注意力先集中在这几处：

- Decode.scala
  这里决定“32 位指令比特模式”会被识别成什么操作。你以后加新指令，第一站几乎一定是这里。
- Mlu.scala
  这是执行单元的好模板。你可以先学它怎么收请求、怎么取 rs1/rs2、怎么流水、怎么写回 rd。
- MluTest.scala
  这是最适合小白学“怎么给硬件模块写单元测试”的地方。
- Core.scala
  这里能看到 scalar core 和 RVV core 怎么接起来，帮助你理解顶层拼装方式。

**最好的起步方式**

不要先做“矩阵乘法扩展”。
先做一个“假的矩阵指令”，例如：

- matadd rd, rs1, rs2
  功能先简单定义成：rd = rs1 + rs2
  只是名字叫 matrix，先跑通整条硬件路径。

这样做的目的不是功能强，而是让你练会这条完整链路：

- 在 Decode.scala 里识别一条新指令
- 在 dispatch 里把它送到某个执行单元
- 在执行单元里计算结果
- 写回寄存器
- 写测试确认它真的工作

只要这一步你做通了，后面把“加法”换成“矩阵操作”就有抓手了。

**我建议你的学习路线**

第一周目标：先把仓库跑通

- 跑你已经成功过的 Verilator 或 VCS 测试
- 学会区分 bazel build、bazel test、bazel run
- 知道 hdl/chisel/src/coralnpu 是硬件源码主目录

第二周目标：看懂一条现有指令怎么走

- 从 mul 开始
- 看 Decode.scala 里怎么识别 mul
- 看它怎么进入 Mlu
- 看 MluTest.scala 怎么验证

第三周目标：自己复制一条最小新指令

- 最简单做法不是新建完整矩阵单元
- 而是先在现有执行路径上加一个自定义 op
- 比如先复用 ALU 或 MLU 的接口，做一条最小 custom 指令

第四周目标：再考虑“矩阵扩展”的真实形态
你需要先回答三个设计问题：

- 你的矩阵数据放哪里？普通标量寄存器、vector 寄存器，还是单独 matrix 寄存器？
- 你的矩阵指令是单周期、小规模，还是多周期、带内部状态？
- 你的矩阵结果写回哪里？rd，vector regfile，还是 accumulator？

这三个问题不先定，代码会越改越乱。

**从工程上看，真正的矩阵扩展通常有三条路**

路线 A：最小教学版

- 不增加新寄存器文件
- 只做一两条矩阵相关 custom 指令
- 输入来自 rs1/rs2
- 输出写回 rd
  适合入门，最快出成果

路线 B：复用 RVV/现有 SIMD 能力

- 把矩阵操作拆成 vector/macc 风格
- 少碰顶层结构
  适合中等复杂度

路线 C：真正的 matrix unit

- 新执行单元
- 新寄存器或 accumulator
- 新 dispatch 规则
- 新 hazard/scoreboard
- 新软件接口
  这才是“像论文/产品那样的矩阵扩展”，但不适合作为第一步

如果你是第一次碰 CPU，我真心建议你先走路线 A。

**你现在最该做的第一个小任务**

我建议你立刻做这个练习：

- 阅读 Mlu.scala
- 阅读 MluTest.scala
- 目标不是完全看懂，而是回答两个问题：
  - 请求是怎么送进执行单元的？
  - 结果是怎么写回寄存器的？

只要你能说清这两个问题，你就已经跨过最难的第一道门槛了。

**如果你愿意，我建议我们下一步直接做实操**

我可以带着你走一个最小可落地练习：

1. 先选一条“假的矩阵指令”定义
2. 我帮你定位应该改哪些文件
3. 我们先把 decode 路径跑通
4. 再补测试

这是最适合小白的路线，而且能最快让你看到“我真的在改 CPU”。





我建议你的第一版目标就定成：

**做一条假的矩阵指令 matadd rd, rs1, rs2**
第一版功能先定义成：
rd = rs1 + rs2

它名字叫“矩阵扩展”，但实现先复用现有 ALU，目的不是功能强，而是让你完整跑通这条链路：

指令编码 -> Decode -> Dispatch -> Execute -> Writeback -> 测试

**为什么先这么做**
因为这样你暂时不用碰：

- 新寄存器文件
- 新矩阵存储格式
- 多周期矩阵流水线
- 复杂 hazard 规则
- 编译器/汇编器支持

你只需要学会“怎么在 CPU 里加一条新指令”。

**第一版最少改 3 个地方**

1. Decode.scala
   你要做的事：
   - 在 DecodedInstruction 里加一个新布尔位，比如 matadd
   - 给它写一条新的 BitPat(...) 解码规则
   - 在 dispatch 里把 matadd 映射到某个执行 op
2. Alu.scala
   你要做的事：
   - 在 AluOp 里加一个新枚举，比如 MATADD
   - 在 MuxLookup 里实现它，第一版直接写成 (rs1 + rs2)
3. AluTest.scala
   你要做的事：
   - 加一个最小单元测试
   - 验证 MATADD 输入 3 和 5，输出 8

**最重要的设计选择**
第一版我建议你用 **RISC-V custom opcode**，不要去抢已有标准指令编码。

你可以先用一个保留的 custom opcode，比如：

- custom-0: 0001011

这样思路最干净：

- funct7 标识矩阵子类
- funct3 标识具体矩阵操作
- rs1/rs2/rd 用标准 R-type 位置

你现在不用一下子把编码想得很复杂。第一版只要保证：
“这个 bit pattern 不和现有指令冲突” 就够了。

**你第一周的最小里程碑**
做到这 4 件事就很棒了：

1. 看懂 mul 是怎么走的
   重点看：
   Decode.scala (line 595)
   Mlu.scala
2. 看懂 alu 是怎么写回的
   重点看：
   Alu.scala
3. 给 ALU 增加一个新 op MATADD
4. 跑通标量单测
   这个仓库现成有标量测试目标：
   BUILD (line 199)

命令是：

```
bazel test //hdl/chisel/src/coralnpu:coralnpu_scalar_tests 
```

**一个很关键的现实建议**
第一阶段不要急着让 C 代码直接写 matadd(a,b,c)。

因为那会把你带进：

- GCC/binutils
- 汇编器扩展
- intrinsic
- ABI

这些太容易分散精力。

第一阶段只做硬件单测就够了。
如果后面你真想从软件侧喂这条指令，先用 .word 0x... 的方式手写一条机器码，比改工具链简单得多。

**我建议你的实施顺序**

1. 在 AluOp 里加 MATADD
2. 在 Alu.scala 里实现 MATADD = rs1 + rs2
3. 在 Decode.scala 里加 matadd 的解码位
4. 在 dispatch 里把 matadd -> AluOp.MATADD
5. 写一个测试
6. 跑 coralnpu_scalar_tests

**你现在最值得做的下一步**
直接开干这个最小任务：

- 新指令名：matadd
- 功能：rd = rs1 + rs2
- 执行单元：复用 ALU
- 验证方式：chisel_test

如果你愿意，我下一条可以直接把这个路线细化成“具体改哪几行、先改哪个文件”的施工单。



我们走 **路线 A 的最小版本**：

- 新指令名：matadd
- 第一版功能：rd = rs1 + rs2
- 先复用 ALU
- 目标不是“真的矩阵乘法”，而是先学会给 CPU 加一条自定义指令

**总共 5 步**

1. 给 ALU 增加一个新操作 MATADD
2. 给 ALU 写这个操作的计算逻辑
3. 在 Decode 里识别 matadd 这条指令
4. 在 Dispatch 里把 matadd 送到 ALU
5. 写测试并运行

今天先做 **第 1 步**。

**第 1 步：给 ALU 增加一个新操作名**

打开这个文件：

Alu.scala

找到这一段：

```
object AluOp extends ChiselEnum {  // RV32IM  val ADD  = Value  val SUB  = Value  ... 
```

在里面加一个新枚举，放在 ADD 后面最容易看懂，例如改成：

```
object AluOp extends ChiselEnum {  // RV32IM  val ADD  = Value  val MATADD = Value  val SUB  = Value  val SLT  = Value  ... } 
```

你现在只做这一件事，别往下改。

**做完后检查两件事**

1. 文件能保存成功
2. 没有把别的枚举删掉或拼错

做完以后，把你改完的这一小段贴给我，我带你做 **第 2 步：给 MATADD 写执行逻辑**。