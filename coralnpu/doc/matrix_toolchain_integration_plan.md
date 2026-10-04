# CoralNPU 矩阵工具链集成计划

更新时间：2026-10-01

## 1. 目标

将玄铁 RISC-V Matrix Extension 的软件支持接入 CoralNPU，使 C/C++ 程序能够：

1. 使用矩阵 intrinsic 或汇编生成 CoralNPU 支持的矩阵指令。
2. 通过 CoralNPU 的标量核、Decode、Dispatch、ROB 和 MatrixCore 正确执行。
3. 使用矩阵配置、mzero、矩阵 load/store 和 mmacc 完成 tiled GEMM。
4. 保留一条不依赖 GCC 完整矩阵后端的低级汇编路径，便于 bring-up 和回归测试。

本计划不默认修改 MatrixCore 或 PE RTL。工具链集成阶段只修改软件工具链、头文件、测试程序和必要的编译配置；如果发现硬件解码与玄铁编码不一致，先记录差异，再单独讨论是否修改硬件。

## 2. 当前状态

### 2.1 玄铁仓库已经包含的内容

目录 /home/wjj/2-NPU/riscv-matrix-extension-spec 不只是 spec 文档，还包含：

- xuantie-gnu-toolchain：玄铁 GNU 工具链工程。
- doc/intrinsic/rvm-intrinsic-api.adoc：矩阵 intrinsic API 文档。
- demos/intrinsic_matmul/matmul.c：矩阵 intrinsic 示例。
- qemu：带矩阵扩展支持的 QEMU 子模块。
- shl 和 hhb：面向矩阵扩展的软件栈和部署工具。

示例使用的接口包括：

    #include <thead_matrix.h>

    mint32_t ma = __riscv_th_mld(x, stride, msize_m, msize_k);
    mint32_t mb = __riscv_th_mld(y, stride, msize_m, msize_k);
    mint32_t ans = __riscv_th_mld(z, stride, msize_m, msize_k);
    ans = __riscv_th_mmul_mm(ma, mb, msize_m, msize_k);
    __riscv_th_mst(out, stride, ans, msize_m, msize_k);

示例编译选项为：

    -march=rv64gcv_zfh_xtheadc_xtheadmatrix
    -mabi=lp64d

### 2.2 当前本机工具链状态

当前 /opt/riscv 是普通工具链：

    riscv64-unknown-elf-gcc 15.2.0
    默认架构：rv64gc

当前工具链不能识别 xtheadmatrix、thead_matrix.h 或玄铁矩阵 intrinsic。因此不能只复制头文件；intrinsic 依赖 GCC 后端 builtin、Binutils opcode 表、矩阵类型和 ABI 约定。

### 2.3 CoralNPU 当前硬件范围

重点代码位置包括：

- hdl/chisel/src/coralnpu/matrix/MatrixDecode.scala
- hdl/chisel/src/coralnpu/matrix/MatrixInterface.scala
- hdl/chisel/src/coralnpu/matrix/MatrixCore.scala
- hdl/chisel/src/coralnpu/scalar/SCore.scala
- hdl/chisel/src/coralnpu/scalar/DispatchV2.scala

当前重点支持范围包括：

- msettilem、msettilen、msettilek。
- mzero。
- mmacc.w.b、mmaccu.w.b、mmaccus.w.b、mmaccsu.w.b。
- A/B/C 及部分 whole/transposed load/store。
- MatrixCore 的 DMA、PE、累加和 C 写回路径。

当前 Python/cocotb 测试中的手工 32 位指令编码只能作为硬件回归测试使用，不能当作正式 C API。

## 3. 总体策略

采用三条路径并行推进：

### 路径 A：复用玄铁工具链

优先使用玄铁预编译工具链或源码构建版本，生成矩阵汇编和 ELF。这样可以同时复用 intrinsic、assembler、GCC 后端和头文件。

主要风险：

- 工具链可能默认面向 RV64 Linux。
- CoralNPU 的 XLEN、ABI、CSR 和矩阵寄存器语义可能不同。
- 玄铁 intrinsic 覆盖的指令集合比 CoralNPU 当前实现更大。

### 路径 B：把矩阵支持回移植到当前工具链

在当前 /opt/riscv 对应的 GCC/Binutils 版本上补充 xtheadmatrix、矩阵 builtin、矩阵类型和 assembler 支持。

优点是最终可以继续使用当前 GCC 版本和构建环境。缺点是工作量最大，涉及 GCC、Binutils、头文件、ABI 和测试套件。

### 路径 C：先提供 CoralNPU 专用汇编接口

在 GCC 完整支持完成前，使用已验证的 mnemonic、.insn 或固定 .word 生成矩阵指令。

这条路径适合快速验证 C kernel，长期也应保留为底层 debug 和 bring-up 接口。

推荐顺序：

    冻结 CoralNPU 编码
        -> Coral 专用 assembler/编码工具
        -> .insn/.word 端到端验证
        -> C/C++ 低级包装接口
        -> 再评估 GCC intrinsic 后端

玄铁 `v0.3.0` 工具链已经确认属于不同版本的 Matrix ISA，因此不再作为
CoralNPU 的直接实现路径。它保留为兼容性参考；除非以后找到明确匹配
`uop=10` 和当前字段布局的工具链版本，否则不修改 CoralNPU RTL 来适配它。

## 4. 阶段一：建立 ISA 编码基线（已完成）

### 4.1 建立指令清单

从 spec 和 CoralNPU 解码器分别列出每条指令的：

- 32 位格式。
- opcode。
- func、uop、func3 字段。
- ms1、ms2、md。
- rs1、rs2。
- 元素宽度。
- load/store 方向。
- mzero 的寄存器数量和起始寄存器。

首批只核对 CoralNPU 当前真正支持的指令：

    msettilem
    msettilen
    msettilek
    mzero
    mmacc.w.b
    mmaccu.w.b
    mmaccus.w.b
    mmaccsu.w.b
    mld/mst A
    mld/mst B
    mld/mst C

### 4.2 编写独立编码参考

建议新增：

    tests/toolchain/matrix_encode_reference.py

该脚本只负责：

- 根据字段生成机器码。
- 从机器码提取字段。
- 输出二进制字段和十六进制编码。
- 检查保留字段是否为零。

参考实现必须以 spec 字段表为第一来源，不能简单复制 MatrixDecode.scala 的逻辑，否则 RTL 和测试可能同时包含同一个错误。

### 4.3 阶段验收

每条指令至少准备：

- 一个默认寄存器样例。
- 一个非零 ms1/ms2/md 样例。
- 一个边界寄存器样例。
- 一个立即数或元素宽度边界样例。

阶段一的验收依据为：

1. CoralNPU 冻结字段和保留位规则。
2. `matrix_encode_reference.py` 生成并解析的机器码。
3. CoralNPU `MatrixDecode` 的输出字段。

玄铁 assembler 只作为独立版本的差异参考，不作为当前 CoralNPU 编码的
强制匹配对象。

阶段一的最终决策是：CoralNPU 矩阵乘使用 `uop=10`。这是当前项目的
冻结值，后续工具链工作不得重新采用上游表格中的 `uop=01`。

## 5. 阶段二：实现 CoralNPU 专用编码入口（已完成）

这一阶段不修改 MatrixCore、PE 或 MatrixDecode。目标是在软件侧生成与当前
RTL 完全一致的 32 位机器码，并建立可重复的验证闭环。

### 5.1 固定编码清单

为当前实际支持的指令建立单一清单：

    msettilemi/msettilem
    msettileni/msettilen
    msettileki/msettilek
    mzero
    mmacc.w.b
    mmaccu.w.b
    mmaccus.w.b
    mmaccsu.w.b
    矩阵 A/B/C load/store

清单需要同时记录助记符、字段、保留位、合法参数范围和预期机器码。
其中四条 `mmacc` 的 `uop` 必须写成 `10`。

### 5.2 提供独立 Coral assembler/disassembler

已新增以下入口：

    tests/toolchain/coral_matrix_as.py
    tests/toolchain/coral_matrix_dis.py
    tests/toolchain/coral_matrix_asm.s

要求：

- 配置、mzero、矩阵乘、A/B/C、whole 和 transposed load/store 都有正式
  mnemonic 入口。
- 汇编参数进行寄存器、立即数、mzero 对齐和 whole `rs2=x0` 检查。
- `c0..c3` 映射为物理字段 `4..7`，`m0..m7` 可直接访问原始字段。
- 输出 `.word`、十六进制或 little-endian 二进制；`.word` 输出可以由现有
  `/opt/riscv` assembler 继续生成对象文件。
- 反汇编未知编码时保留为 `.word`，不会错误猜测成合法矩阵指令。

### 5.3 建立工具链 probe 和 round-trip 回归

新增一个最小汇编/C probe，完成：

1. 生成一条代表性的 Coral 矩阵指令。
2. 用当前 assembler 生成对象文件。
3. 用 `objdump` 取出机器码。
4. 与 `matrix_encode_reference.py` 的预期编码比较。
5. 把 probe 接入 Bazel 或独立 shell 检查。

基础 probe 的验收已完成：11 条代表性指令的最终 `.text` 字节与冻结编码
逐条一致；独立 assembler/disassembler 的 25 条样例 round-trip 也已通过，
且不需要修改硬件 RTL。验证命令为：

    cd /home/wjj/2-NPU/coralnpu
    python3 tests/toolchain/check_coral_matrix_roundtrip.py
    python3 tests/toolchain/check_coral_matrix_probe.py

当前入口是 Coral 专用 assembler front end，而不是玄铁旧版 assembler 的
兼容层。它把正式 mnemonic 转换为 `.word`，因此能立即服务 C/汇编 kernel；
后续若需要 GCC 原生 mnemonic，只需把同一套 opcode 表移植到 Binutils。

## 6. 当前结论和后续边界

截至 2026-10-01，工具链 bring-up 已经具备可交付的低级汇编路径：

1. 冻结编码由参考 encoder、assembler、disassembler 三处共同验证。
2. Coral 矩阵乘固定使用 `uop=10`。
3. 玄铁 `v0.3.0` 工具链仍作为不兼容版本保留，不能直接生成 Coral 指令。
4. 硬件 RTL 没有为适配玄铁工具链而修改。

只有在需要“普通 gas 直接识别 Coral mnemonic”或 GCC 自动生成矩阵指令时，
才继续做 Binutils/GCC 后端移植；这属于工具链增强，不是当前 MatrixCore
验证的前置条件。

## 6. 阶段三：验证玄铁 assembler 的可复用部分

### 6.1 安装独立工具链

优先使用 spec 仓库 demos/env.sh 指向的预编译工具链；若不可用，再构建源码版本：

    cd /home/wjj/2-NPU/riscv-matrix-extension-spec/xuantie-gnu-toolchain
    git submodule update --init --recursive
    ./configure --prefix=/opt/xuantie-matrix --enable-multilib
    make

Linux 目标使用：

    make linux

不要覆盖 /opt/riscv。两套工具链应并行安装，便于对比。

### 6.2 汇编最小样例

为每条 CoralNPU 支持的指令建立独立 .S 文件，例如：

    .text
    msettilem  x5
    msettilen  x6
    msettilek  x7
    mzero      acc0
    mmacc.w.b  acc0, tr0, tr1

具体助记符和矩阵寄存器写法以玄铁 assembler 的实际支持为准，不假设 spec 文档中的寄存器别名一定与 assembler 完全相同。

检查汇编和反汇编：

    riscv64-unknown-linux-gnu-as \
      -march=rv64gcv_zfh_xtheadc_xtheadmatrix \
      -o matrix.o matrix.S

    riscv64-unknown-linux-gnu-objdump \
      -d -M no-aliases matrix.o

### 6.3 记录差异

每次对比标记为：

- 编码一致，语法不同。
- 语法一致，编码不同。
- 编码和语法都不一致。
- 玄铁支持而 CoralNPU 尚未实现。
- CoralNPU 当前使用了自定义扩展。

只有“编码一致、语法不同”适合仅通过修改头文件或 assembler 别名解决。其他差异要先决定 ISA 兼容策略。

## 7. 阶段四：验证玄铁 intrinsic

### 7.1 检查头文件和矩阵类型

需要确认 thead_matrix.h 的实际位置，并检查：

- mint8_t、mint32_t 等类型定义。
- mrow_t、mcol_t 的宽度。
- mld/mst 参数顺序。
- mmul/mmacc 的返回值语义。
- 是否隐式执行 msettile。
- 矩阵寄存器是否由编译器分配。
- 是否有 mzero 对应的 intrinsic。

### 7.2 生成汇编并反汇编

以玄铁示例为起点：

    cd /home/wjj/2-NPU/riscv-matrix-extension-spec/demos/intrinsic_matmul
    riscv64-unknown-linux-gnu-gcc \
      -march=rv64gcv_zfh_xtheadc_xtheadmatrix \
      -mabi=lp64d -O2 -S matmul.c -o matmul.s
    rg -n "mld|mst|mmul|mmacc|mzero|msettile" matmul.s

如果需要机器码：

    riscv64-unknown-linux-gnu-gcc \
      -march=rv64gcv_zfh_xtheadc_xtheadmatrix \
      -mabi=lp64d -O2 matmul.c -o matmul.elf
    riscv64-unknown-linux-gnu-objdump -d matmul.elf

### 7.3 CoralNPU 兼容性检查

对每条生成指令检查：

- CoralNPU 是否识别该 opcode。
- 字段是否落在 CoralNPU 预期位置。
- md 是否对应当前 C/accumulator 编号。
- ms1/ms2 是否对应当前 A/B 编号。
- msettile 是否写入当前硬件使用的配置状态。
- load/store 的 stride、转置方向和寄存器类型是否一致。
- CSR、trap、ROB retirement 是否存在软件可观察差异。

## 8. 阶段五：定义 CoralNPU 软件接口

### 8.1 低级汇编接口

建议新增：

    include/coral_matrix_asm.h

提供以下类别的封装：

    coral_msettilem(value)
    coral_msettilen(value)
    coral_msettilek(value)
    coral_mzero(c_reg)
    coral_mmacc_w_b(ms1, ms2, md)
    coral_mld_a(base, stride, reg)
    coral_mld_b(base, stride, reg)
    coral_mld_c(base, stride, reg)
    coral_mst_a(base, stride, reg)
    coral_mst_b(base, stride, reg)
    coral_mst_c(base, stride, reg)

底层优先级：

1. 已验证的 assembler mnemonic。
2. .insn。
3. 固定 .word 编码。

不要把动态字段直接拼进普通 C 字符串汇编；寄存器和立即数字段需要明确约束或宏展开，并加入编译期范围检查。

### 8.2 高级 intrinsic 接口

如果玄铁 API 语义和 CoralNPU 完全一致，可以兼容玄铁名字。如果只有部分一致，建议提供：

    include/coral_matrix.h

不要为了名字兼容而隐藏语义差异，尤其要明确：

- CoralNPU 当前支持哪些元素宽度。
- A/B 的 S1.6 数据格式如何表达。
- MX scale 的指数编码如何传递。
- C 的定制 32 位累加格式如何通过 load/store 暴露。
- 两条连续 MATMUL 是否允许对同一 C 累加。

## 9. 阶段六：必要时修改 GCC/Binutils

### 9.1 Binutils

如果玄铁 assembler 已支持目标编码，优先复用它的 opcode 定义。

如果当前 Binutils 不支持，需要检查：

- riscv-opc.c 中的 opcode 表。
- operand 字段解析。
- -march 扩展字符串解析。
- disassembler 的反汇编格式。
- gas 和 objdump 测试。

验收要求：

    assemble(disassemble(bytes)) == bytes

至少覆盖所有 CoralNPU 已实现矩阵指令。

### 9.2 GCC

只有需要真正支持 C intrinsic、矩阵类型和编译器寄存器分配时，才进入 GCC 后端。可能涉及：

- xtheadmatrix target option。
- 矩阵 builtin 声明。
- thead_matrix.h。
- 矩阵类型和 machine mode。
- RTL pattern 或 machine description。
- 寄存器约束。
- 优化器对矩阵指令的移动、合并和删除规则。
- volatile 和 memory clobber 语义。

第一版建议先让 intrinsic 生成固定且可控的汇编，不立即实现自动矩阵化。

### 9.3 ABI 和上下文切换

需要确认：

- 矩阵寄存器是 caller-saved 还是 callee-saved。
- C 函数是否允许跨函数调用保留矩阵寄存器。
- 中断、异常和上下文切换是否保存矩阵状态。
- msettile 配置是否属于线程状态。
- WFI、trap 和 ROB retirement 对软件是否可见。

如果 CoralNPU 尚无完整 OS 上下文切换支持，第一版软件接口应限制为单个不跨函数调用的矩阵 kernel，或明确要求调用者保存和恢复状态。

## 10. 阶段七：测试计划

### 10.1 汇编器测试

每条指令至少测试：

- 合法编码可以汇编。
- 非法字段被拒绝。
- 反汇编名称和字段正确。
- 机器码与独立 Python 参考一致。

### 10.2 C intrinsic 测试

建立最小程序：

1. 配置 M/N/K。
2. load A/B。
3. mzero C。
4. 执行一次 mmacc.w.b。
5. store C。
6. 与软件参考模型比较。

随后加入：

- K=32 和 K=64。
- M/N 尾块。
- 多条 MATMUL 对同一 C 累加。
- A/B scale 变化。
- 负数、零值和 int8 边界。
- AXI backpressure。
- MatrixCore 与标量/RVV 高负载并发。

### 10.3 CoralNPU 集成测试

完整链路应覆盖：

    C 源码
      -> 工具链
      -> ELF/汇编
      -> 指令存储器
      -> Coral Decode/Dispatch
      -> ROB
      -> MatrixCore
      -> AXI RAM
      -> C 输出

每个测试同时检查：

- retired PC 顺序。
- 是否出现非法指令 trap。
- MatrixCore 命令顺序。
- AXI 地址、长度和 strobe。
- A/B/C 寄存器选择。
- 最终输出 bit-exact。
- source、padding 和 guard 区域未被破坏。

## 10. 推荐执行顺序

### 第 1 步：不改硬件，完成编码对照

产物：

- 指令字段表。
- 独立编码参考。
- 玄铁 assembler 机器码样本。
- CoralNPU decode 对照结果。

### 第 2 步：安装独立玄铁工具链

产物：

- /opt/xuantie-matrix。
- 可执行的 riscv gcc、as、objdump。
- 可找到的 thead_matrix.h。

### 第 3 步：编译玄铁 intrinsic demo

产物：

- matmul.s。
- matmul.elf。
- 关键矩阵指令的机器码。

### 第 4 步：接入最小 CoralNPU kernel

先只接入 msettile、mzero、mld/mst C 和一个 mmacc。不先接入完整 SHL、HHB 或 ResNet 软件栈。

### 第 5 步：补充 CoralNPU 低级 C 头文件

如果玄铁 intrinsic 暂时不能直接使用，先提供 coral_matrix_asm.h，用固定编码或 .insn 生成可执行 kernel。

### 第 6 步：决定是否回移植到当前 GCC

只有在以下条件满足后才进入 GCC/Binutils 回移植：

- 玄铁编码与 CoralNPU 编码已确认一致，或差异已明确接受。
- 最小 kernel 已在 CoralNPU RTL 上通过。
- 玄铁 intrinsic 语义已拆解清楚。
- CoralNPU 的 RV32/RV64 和 ABI 目标已经确定。

## 11. 关键决策点

### 11.1 兼容玄铁编码还是定义 Coral 自有编码

优先兼容玄铁编码，因为可以复用 spec、assembler、intrinsic 文档、demo 和 QEMU 软件生态。

只有在以下情况才建议定义 Coral 自有编码：

- 玄铁编码与现有 Coral 硬件冲突。
- 玄铁字段无法表达 Coral 的 scale 或定制累加语义。
- Coral 的硬件目标明确不是玄铁矩阵 ISA。

如果自定义，应使用独立扩展名和独立头文件，不要伪装成完整 xtheadmatrix。

### 11.2 兼容玄铁 intrinsic 名字还是使用 Coral 名字

- 语义完全一致的接口可以兼容玄铁名字。
- 语义不同的接口使用 coral_ 前缀。
- 底层编码测试使用 coral_matrix_asm.h。

### 11.3 是否修改 MatrixDecode

只有完成机器码对照后才修改。允许的原因包括：

- 当前 decode 与 spec 或 assembler 明确不一致。
- 当前 decode 无法区分需要支持的合法编码。
- 当前 decode 与 Coral 自有扩展的明确设计要求不一致。

不能因为 intrinsic 名字不同就修改 MatrixDecode。名字属于软件接口，编码才是硬件契约。

## 12. 完成定义

第一阶段工具链集成完成，至少满足：

- 有明确的 CoralNPU 矩阵指令字段表。
- 独立编码参考与 RTL decode 对照通过。
- assembler 能生成所有当前支持指令。
- objdump 能正确反汇编这些指令。
- C/C++ 能通过 intrinsic 或 Coral 汇编头文件生成矩阵指令。
- 最小矩阵乘 kernel 在 CoralNPU 仿真上通过。
- K=32/K=64、M/N 尾块和连续累加测试通过。
- 标量/RVV 与 MatrixCore 高负载并发测试通过。
- ELF 不依赖人工修改机器码。
- 对暂不支持的玄铁指令有明确失败行为，而不是静默生成错误结果。

## 13. 建议的仓库文件布局

    coralnpu/
      doc/
        matrix_toolchain_integration_plan.md
        matrix_toolchain_compatibility.md
      include/
        coral_matrix_asm.h
        coral_matrix.h
      tests/toolchain/
        matrix_encode_reference.py
        matrix_assembler_test.S
        matrix_intrinsic_smoke.c

其中：

- coral_matrix_asm.h 是低级、可控、便于 bring-up 的接口。
- coral_matrix.h 是稳定后提供给应用代码的高级接口。
- matrix_encode_reference.py 是独立于 RTL 的编码基线。
- matrix_toolchain_compatibility.md 记录玄铁与 Coral 的逐条差异。

## 14. 最终建议

当前最稳妥的路线是：

    1. 保留现有 /opt/riscv，不覆盖。
    2. 单独安装玄铁矩阵工具链。
    3. 用玄铁 assembler 编译最小矩阵指令样例。
    4. 将机器码逐条与 MatrixDecode 对照。
    5. 先用 .insn 或 .word 建立 Coral 低级 C 接口。
    6. 用 CoralNPU 仿真验证 C kernel。
    7. 最后决定是否回移植到当前 GCC 15 和 Binutils 2.46。

这样可以把三个问题分开定位：

- 指令编码是否一致。
- 工具链是否能生成指令。
- CoralNPU 硬件是否正确执行指令。

不要在这三个问题尚未分离前，同时修改 MatrixDecode、MatrixCore、GCC 和 intrinsic，否则出现错误时很难判断根因。
