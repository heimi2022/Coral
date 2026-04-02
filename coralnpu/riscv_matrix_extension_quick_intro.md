# RISC-V Matrix Extension Proposal 快速介绍

## 这份 spec 是什么

这是一份 RISC-V Matrix Extension 的提案文档，用来给 RISC-V 增加一套面向矩阵计算的原生 ISA 扩展。它不是把矩阵计算塞进现有向量扩展里，而是选择了和向量扩展解耦的架构，单独定义矩阵寄存器、矩阵乘累加、矩阵 load/store、逐元素运算以及若干矩阵辅助指令。

一句话概括：

> 它想把 AI 和线性代数里最常见的 tile-based 矩阵计算，直接提升成 RISC-V 的一等指令模型。

## 为什么需要它

这份 proposal 的核心出发点是矩阵乘法通常不是“整块一次算完”，而是按 tile 分块处理。软件里经常会写三层循环，在 `m / k / n` 三个方向上不断搬运子块、做乘累加、处理尾块。这个扩展希望把这套模式直接固化到 ISA 里：

- 用专门的矩阵寄存器保存输入 tile 和输出 tile
- 用 `mtilem`、`mtilek`、`mtilen` 这三个 CSR 描述当前 tile 的形状
- 用专门的矩阵乘加指令表达 `C += A x B^T`
- 用专门的 load/store 指令把 A、B、C 三类 tile 从内存搬到寄存器

这样做的意义是：

- 让编译器和手写 kernel 更容易表达 tiled GEMM
- 让不同实现可以在统一 ISA 下裁剪硬件规模
- 比纯靠标量或普通向量拼装矩阵微内核更直接

## 最重要的编程模型

### 1. 两类矩阵寄存器

Spec 定义了 8 个矩阵寄存器：

- 4 个 Tile Registers：`tr0` 到 `tr3`
- 4 个 Accumulation Registers：`acc0` 到 `acc3`

可以把它们理解成：

- `tr*` 主要放输入矩阵块
- `acc*` 主要放输出累加结果

这个分离很关键，因为矩阵乘法的输入元素位宽和输出累加位宽经常不同，比如 `int8 -> int32`、`fp16 -> fp32`。

### 2. 三个实现相关参数

每个实现定义 3 个基础参数：

- `ELEN`：单个矩阵元素可支持的最大位宽
- `TLEN`：一个 tile register 的总位数
- `TRLEN`：tile register 每一行的位数

由此还能推导出：

- `ROWNUM = TLEN / TRLEN`
- `ARLEN`：accumulation register 每行位宽
- `ALEN`：整个 accumulation register 的总位宽

这几个参数决定了“一个 tile 能装多大的矩阵块”。所以这份 spec 不是固定死一种矩阵尺寸，而是提供一个可伸缩的硬件框架。

### 3. Tile 形状由 CSR 动态设置

当前计算 tile 的形状由 3 个 CSR 描述：

- `mtilem`
- `mtilek`
- `mtilen`

对应矩阵乘法里的三个维度：

- A 的形状是 `mtilem x mtilek`
- B 的形状是 `mtilen x mtilek`
- C 的形状是 `mtilem x mtilen`

设置它们的指令是：

```asm
msettilemi imm
msettilem  rs1
msettileki imm
msettilek  rs1
msettileni imm
msettilen  rs1
```

这套机制本质上就是为 tiling 和 tail handling 服务的。大多数循环迭代都跑满 tile，遇到边界时再把 `mtile*` 改成尾块大小。

## 指令体系怎么理解

这份 spec 的指令大致可以按 5 类看。

### 1. 配置类指令

最核心的是：

- `msettilem/k/n[i]`：设置 tile 大小
- `mrelease`：告诉系统矩阵状态可以丢弃，帮助降低上下文切换成本

`mrelease` 的设计很像“我这段矩阵 kernel 跑完了，寄存器内容不需要保留了”。

### 2. 矩阵乘累加指令

这是整份 spec 最核心的部分。基本语义是：

```text
md = md + ms1 * ms2
```

其中：

- `ms1`、`ms2` 来自 tile registers
- `md` 是 accumulation register

支持的类型覆盖了常见 AI 场景：

- 整数：如 `int8/uint8 -> int32`
- 浮点：`fp16`、`fp32`、`fp64`
- 混合精度：如 `fp16 -> fp32`、`bf16 -> fp32`
- fp8 路线：如 `fp8 -> fp16/bf16/fp32`

几个代表性例子：

```asm
mmacc.w.b   md, ms2, ms1
mmaccu.w.b  md, ms2, ms1
mfmacc.h    md, ms2, ms1
mfmacc.s.h  md, ms2, ms1
mfmacc.s.e4 md, ms2, ms1
```

如果你只想给别人一个直观印象，可以说：

> 它把“小块矩阵乘加”变成了一条 ISA 级操作，而不是让软件自己拆成很多标量或向量指令。

### 3. 矩阵 load/store 指令

这部分很有特色。因为在 `C = A x B^T` 这个模型下，A、B、C 三类矩阵块的逻辑形状并不一样，所以 spec 专门拆成三套访存指令：

- `mla* / msa*`：访问 A tile
- `mlb* / msb*`：访问 B tile
- `mlc* / msc*`：访问 C tile

而且同时支持：

- 非转置访问
- 转置访问

例如：

```asm
mlae16 md, (rs1), rs2
mlbe16 md, (rs1), rs2
mlce32 md, (rs1), rs2
mlbte16 md, (rs1), rs2
msce32 ms3, (rs1), rs2
```

这里 `rs1` 是基地址，`rs2` 是行跨度。这个设计说明 spec 很强调把内存布局和 tile 搬运本身也标准化，而不仅仅是定义算子。

### 4. MISC 类矩阵操作

除了乘法和访存，它还提供了一批“拼 tile”的辅助指令，例如：

- `mzero`：清零矩阵寄存器
- `mmov.*`：矩阵寄存器和 GPR 之间移动标量
- `mdup*`：广播一个标量
- `mpack`：打包
- `mrslide* / mcslide*`：按行或列滑动
- 行广播、列广播、元素广播

这些指令的意义在于：矩阵计算不只有 GEMM，还经常要做 padding、拼接、广播、边界处理和中间结果整理。

### 5. 逐元素运算和类型转换

Spec 还定义了矩阵逐元素算术和类型转换，覆盖：

- 整数逐元素运算
- 浮点逐元素运算
- 定点/浮点转换
- 更窄格式打包和裁剪

这说明它不想只做“纯 matmul ISA”，而是想提供一个更完整的矩阵子系统。

## CSR 和状态管理是另一个重点

除了 `mtilem/k/n`，还有一组矩阵控制状态 CSR：

- `xmcsr`
- `xmxrm`：定点舍入模式
- `xmsat`：定点饱和标志
- `xmfflags`：浮点异常标志
- `xmfrm`：浮点舍入模式
- `xmsaten`：饱和模式开关
- `xmisa`：实现支持哪些矩阵子集
- `xtlenb` / `xtrlenb` / `xalenb`：报告寄存器规模

这里最值得讲的一点是：

> 这份 proposal 不要求所有实现都支持完整矩阵能力，而是通过 `xmisa` 让硬件公开“我支持哪些精度和哪些子功能”。

比如：

- `mmi8i32`：是否支持 `int8 -> int32` 矩阵乘
- `mmf16f16`：是否支持 `fp16 -> fp16`
- `mmf16f32`：是否支持 `fp16 -> fp32`
- `mmbf16f32`：是否支持 `bf16 -> fp32`
- `mmf8f32`：是否支持 `fp8 -> fp32`
- `miew` / `mfew` / `mfic`：是否支持整数逐元素、浮点逐元素、整浮转换

这让 spec 在实现上比较灵活，也更接近真实硬件产品的裁剪方式。

## 一个最容易讲清楚的执行流程

如果要在会议上 1 分钟讲明白这套 ISA 怎么用，可以直接用下面这条主线：

1. 先用 `msettilem/k/n` 设置当前 tile 大小
2. 用 `mla*` 和 `mlb*` 把 A、B 的子块搬进 `tr*`
3. 用 `mlc*` 或 `mzero` 初始化 `acc*`
4. 执行一次或多次 `mmacc` / `mfmacc`
5. 必要时做逐元素处理、转换、广播或 pack
6. 用 `msc*` 把结果写回内存
7. kernel 结束后执行 `mrelease`

这就是一个典型的 tile-based GEMM 微内核执行模型。

## 这份 proposal 的几个亮点

- 它直接把 tiled matrix compute 提升成 ISA 概念，而不是完全依赖编译器模式匹配
- 输入 tile 和输出 accumulation 分离，天然适合 mixed precision
- CSR 驱动 tile 形状，能比较自然地处理尾块
- load/store 不是通用二维搬运，而是围绕 `A / B / C` 三类矩阵乘角色设计
- 通过 `xmisa` 做能力发现，便于不同实现裁剪

## 也要提醒听众的几个点

- 这是 proposal，不是已经完全定稿的标准
- 设计明显偏向矩阵乘法和 AI kernel，而不是通用线性代数所有模式
- 和 RVV 是“解耦”的，不是简单地在向量寄存器上复用语义
- 真正能用哪些精度、哪些逐元素操作，要看实现报告的 `xmisa`
- 软件栈是否好用，最终还取决于编译器、intrinsic、ABI、上下文切换和操作系统支持

## 如果只给别人讲 30 秒

可以直接这么说：

> 这份 RISC-V Matrix Extension Proposal 想做的是，把分块矩阵乘法需要的寄存器模型、tile 尺寸配置、矩阵乘加、矩阵访存和常见辅助操作都标准化。它和 RVV 分开设计，专门引入 tile register 和 accumulation register，核心围绕 `C += A x B^T` 这种 AI 常见 kernel 展开，同时支持 int8、fp16、bf16、fp32、fp8 等多种精度和 mixed precision 路线。

## 如果要给别人画一张脑图

可以按下面 4 个关键词展开：

- `Tile shape`
  `mtilem / mtilek / mtilen`
- `Registers`
  `tr0-tr3` + `acc0-acc3`
- `Compute`
  `mmacc / mfmacc`
- `Data movement`
  `mla/mlb/mlc` + transpose + stride

## 参考依据

这份摘要基于 `spec/` 目录中的 AsciiDoc 源文件整理，重点参考了：

- `intro.adoc`
- `param.adoc`
- `program_model.adoc`
- `csr.adoc`
- `tilereg.adoc`
- `instructions.adoc`
- `config_set.adoc`
- `matmul.adoc`
- `load-store.adoc`

对应 PDF 为 `riscv_matrix_extension_proposal.pdf`，Makefile 中标记的版本是 `v0.6.0 Draft`。
