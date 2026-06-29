# Coral Matrix DSE Target

## 1. 适用范围

本文档定义 Coral 矩阵子系统在当前阶段的架构范围、软件可见语义、已落地 RTL 基线以及用于设计空间探索（DSE）的目标抽象。

本文档明确区分以下内容：

1. 软件可见 / spec 级语义是什么
2. 当前代码库里已经有哪些 RTL 实现
3. DSE 时应采用的目标架构抽象是什么

当前代码库中的矩阵子系统仍处于演进中，尤其是 `MatrixCore / MatrixDma / MatrixRegFile` 之间存在旧路径与新路径并存的情况。因此，DSE、性能分析和存储层级建模均应以本文档定义的架构冻结版本为准，而不应直接以某一个过渡态 RTL 文件作为唯一依据。

---

## 2. 总体结论

Coral 当前矩阵子系统可抽象为：

- 一个由标量核驱动的、与主流水线**弱解耦**的矩阵执行单元
- 一个独立的矩阵寄存器文件：
  - 包含 tile 寄存器类
  - 包含 accumulator 寄存器类
- 一个独立的矩阵 DMA：
  - 长期目标是 `DRAM <-> MatrixDma <-> MatrixRegFile`
  - 不再走普通 LSU / DTCM 路径
- 一个 tile 级矩阵乘加后端

对于当前阶段的 DSE，重点不在 CPU cache，而在：

- `MatrixRegFile` 的容量、组织方式、bank 宽度、端口和访问模式
- `MatrixDma` 的 burst / outstanding / 行跨距访问能力
- `PE array` 与本地矩阵寄存器容量之间的匹配关系

---

## 3. 软件可见矩阵模型

### 3.1 软件可见寄存器类别

当前软件可见的矩阵寄存器编码为 `3 bit`：

- `000..011`：`tr0..tr3`
- `100..111`：`acc0..acc3`

推荐 DSE 时采用下面的语义理解：

- `tr*`：主要承载输入矩阵 tile，典型对应 `A/B`
- `acc*`：主要承载累加 / 输出矩阵，典型对应 `C`

这和当前矩阵计算路径的约束一致：

- 两个源操作数必须来自 tile 寄存器
- 目标操作数必须是 acc 寄存器

### 3.2 软件可见矩阵访存语义

当前 `MatrixMemOp` 已经定义了：

- `LD_A / LD_B / LD_C`
- `ST_A / ST_B / ST_C`
- `LD_WHOLE / ST_WHOLE`
- `LD_AT / LD_BT / LD_CT`
- `ST_AT / ST_BT / ST_CT`

可将其理解为：

- 支持按角色区分的矩阵 load/store
- 支持 whole-register 和 shaped 访问
- 支持 transpose 风格访问

当前 `MatrixDmaLoad` 的归一化 load 语义是：

- `mem_rows_i`：本条命令要发多少次 burst
- `mem_cols_i * elem_bytes`：单次 burst 的有效字节数
- 第 `i` 次 burst 地址：
  - normal：`base + i * stride`
  - 更一般的软件语义：
    - normal：`base + row * stride + col * elem_bytes`
    - transpose：`base + col * stride + row * elem_bytes`

其中：

- `stride` 单位是**字节**
- `elemWidth` 为 `2 bit`：
  - `00/01/10/11 = 8/16/32/64 bit`

### 3.3 配置 CSR

当前矩阵配置通过 CSR 提供：

- `mtilem`
- `mtilek`
- `mtilen`
- `xmsaten`

建议 DSE 先把它们理解为运行时 tile 维度配置，其中当前 RTL 的主设计点是：

- `M`
- `N`
- `K`

---

## 4. 当前参数基线

矩阵子系统的关键参数在 `hdl/chisel/src/coralnpu/Parameters.scala` 中定义。

对 DSE 而言，应保留如下抽象参数：

- `matrixElen`
  - 基本元素宽度
- `matrixTlen`
  - tile 寄存器总位宽
- `matrixTrlen`
  - tile 寄存器单逻辑行位宽
- `matrixTileRegCount`
  - tile 寄存器数量
- `matrixAccRegCount`
  - acc 寄存器数量

派生关系为：

- `matrixRowNum = matrixTlen / matrixTrlen`
- `matrixArlen = matrixRowNum * matrixElen`
- `matrixAlen = matrixArlen * matrixRowNum`

其中：

- `matrixRowNum`
  - 表示 tile / acc 的逻辑行数
- `matrixArlen`
  - 表示 acc 的单逻辑行位宽
- `matrixAlen`
  - 表示 acc 寄存器总位宽

---

## 5. 矩阵寄存器几何结构

这是 DSE 最需要冻结的部分。

### 5.1 逻辑几何

对 DSE 而言，应把矩阵寄存器几何理解为**参数化逻辑几何**，而不是固定尺寸实例。

- tile：
  - 由 `matrixTlen` 和 `matrixTrlen` 定义
  - 逻辑行数由 `matrixRowNum` 定义
- acc：
  - 由 `matrixAlen` 和 `matrixArlen` 定义
  - 逻辑行数与 tile 几何相关联

因此：

- tile 单行需要若干个传输 beat
- acc 单行需要若干个传输 beat
- 具体 beat 数由“单行字节数 / beat 字节数”共同决定

### 5.2 beat 级传输抽象

DMA / AXI 侧采用 beat 级传输接口，其中：

- beat 宽度由外存数据通路参数定义
- beat 字节数是 DSE 变量

因此：

- 寄存器内 beat 编址由“寄存器总字节数 / beat 字节数”决定
- 行内 beat 编址由“逻辑行字节数 / beat 字节数”决定

### 5.3 推荐给 DSE 的物理理解

虽然 `MatrixDmaLoad.sv` 的说明文字把 backend 说成“多个 beat 级 bank”，但**当前真正已经落地的 `MatrixRegFile.sv` 实现更接近“一寄存器一宏”的组织风格**。

因此，当前已实现的物理基线应理解为：

- 一个逻辑寄存器对应一个物理 SRAM 宏
- tile 与 acc 使用不同容量等级的物理宏

这是后续 DSE 的**baseline physical organization**。

---

## 6. MatrixRegFile：当前已落地 RTL

### 6.1 当前已经实现的端口

`MatrixRegFile.sv` 目前已经提供三类端口：

1. 计算路径 whole-register 端口
   - `tile_rd0`
   - `tile_rd1`
   - `acc_rd`
   - `acc_wr`

2. DMA 侧 beat 级端口
   - `mem_rd_en/kind/reg/beat -> mem_rd_data`
   - `mem_wr_en/kind/reg/beat/data/strb`

3. debug / legacy 端口
   - whole-register preload / readback

### 6.2 当前实现方式

当前实现不是纯粹的“宏直接组合读写”，而是：

- 每个逻辑寄存器对应一个同步 SRAM 宏
- 另维护一份 `shadow_q`
  - 用于 whole-register 组合读
  - 也用于 beat 级写入时做 read-modify-write

因此，**当前 `shadow_q` 是行为建模 / bring-up 辅助结构，不应直接算入未来硅实现的正式矩阵寄存器容量**。

对 DSE 而言，应把：

- `shadow_q`
  - 看成 RTL 便利性结构
- 物理 SRAM 宏
  - 看成真正的物理 baseline

### 6.3 DSE 时建议如何抽象 MatrixRegFile

推荐抽象成下面的结构：

- 逻辑寄存器数：
  - `N_tile_reg`
  - `N_acc_reg`
- 物理宏组织：
  - baseline：`1 macro / logical register`
- 数据几何：
  - tile row bytes
  - acc row bytes
- 传输几何：
  - beat bytes

如果做进阶 DSE，可引入两种备选组织：

1. baseline
   - 一寄存器一宏
2. future candidate
   - 一寄存器拆成多 bank
   - tile：每行若干 bank
   - acc：每行若干 bank

但请注意：**当前代码里真正已经稳定实现的是 baseline，而不是 future candidate。**

---

## 7. 计算后端：当前状态与 DSE 解释

当前代码库里实际上有两条“矩阵计算后端”线索。

### 7.1 已接入 `MatrixCore` 的旧计算路径

`MatrixCore.sv` 当前的计算路径是：

- 从 `MatrixRegFile` 读两个 whole-tile 源寄存器
- 读一个 whole-acc 目标寄存器
- 通过一个 whole-register 粒度的 MAC 计算块
- 结果整块写回 acc

它的特点是：

- 以 whole-register 粒度工作
- 作为 bring-up / ISA 贯通最小实现存在
- 目前只真实支持 `MMACC_W_B`

### 7.2 新的 WS 计算后端草案

另有一条较新的、尚未完全接入主线的计算后端，文档见 `hdl/verilog/matrix/PE.md`，核心模块包括：

- `pe_ws`
- `pe_array`
- `pe_ctrl`
- `matmul_tiling`
- `accumulaters`

它的设计特征更适合作为真正的 DSE 对象：

- `WS (Weight Stationary)` 数据流
- 目标 tile 规模由 `M / N / K` 配置共同决定
- 有权重 ping/pong
- 依赖本地矩阵寄存器 / SRAM 供数

### 7.3 对 DSE 的建议

如果 DSE 目标是“未来 Coral 要实现的实用矩阵后端”，建议：

- **用 `PE.md` 所描述的 WS 后端作为 compute-side architectural intent**
- **用 `MatrixRegFile.sv` 当前参数作为 storage-side baseline**

也就是：

- 计算后端：按 `M / N / K` 参数化、`WS` 数据流理解
- 寄存器文件：按“tile/acc 分离、beat 级访问、一寄存器一宏 baseline”理解

---

## 8. Matrix DMA：当前状态与 DSE 解释

### 8.1 长期目标

根据 `doc/matrix_dma_spec.md`，当前明确的路线是：

```text
DRAM <-> MatrixDma <-> MatrixRegFile
```

也就是：

- 矩阵搬运不再长期依赖普通 LSU / DTCM
- 由矩阵 DMA 直接通过 AXI master 访问外部 DRAM
- 寄存器文件对 DMA 暴露 beat 级读写口

### 8.2 当前已经实现的 DMA 特征

`MatrixDma.sv` / `MatrixDmaLoad.sv` 当前已经体现出的关键结构包括：

- AXI 数据宽度：
  - 参数化
- read outstanding：
  - 参数化
- 单 AXI ID
- in-order read response
- load 路径比 store 路径更成熟
- load 可以多行请求在途，但仍按命令顺序完成

### 8.3 load 路径的关键抽象

`MatrixDmaLoad.sv` 的核心可抽象为：

- issue side
  - 一条矩阵 load 命令拆成多行 burst
  - 只要 outstanding 没满，就继续发下一行
- receive side
  - 返回按单 ID 顺序接收
  - 对齐时每个 beat 直接写 matrix register beat
  - 非对齐时用“上一拍 + 当前拍”拼接

### 8.4 store 路径的当前状态

store 路径目前仍在 `MatrixDma.sv` 顶层维护，成熟度低于 load 路径。

对 DSE 的建议是：

- 第一优先级分析 load-side bandwidth / latency hiding
- store-side 先按保守模型处理
  - write outstanding depth 先按较保守配置处理
  - 元素/行写回能力不作为第一阶段主优化目标

---

## 9. 当前代码库中的不一致点

这是另一个 AI 最容易被带偏的地方。

### 9.1 `MatrixCore.sv` 与新 `MatrixDma.sv` 并未完全对齐

当前 `MatrixCore.sv` 里实例化 `MatrixDma` 的端口风格，仍带有旧式 whole-register memory side 接口痕迹；而当前单独存在的 `MatrixDma.sv` 已经是：

- AXI master read/write
- beat-level regfile read/write
- load/store 分离实现

因此：

- **不要把当前 `MatrixCore.sv` 的 DMA 例化直接当成最终架构冻结**
- 对 DSE 应采用 `doc/matrix_dma_spec.md + MatrixDmaLoad.sv + MatrixRegFile.sv` 共同描述出的“新 DMA 架构”

### 9.2 `MatrixCoreWrapper` 仍保留旧 direct-memory blackbox 接口

Chisel 侧 `MatrixCoreWrapper` 仍使用 `MatrixMemDirectIO`，这是旧的直接 dmem 请求风格。

对 DSE 而言应理解为：

- 这是当前系统集成还未完全收口的历史接口
- **不应作为未来矩阵内存系统的目标建模接口**

### 9.3 `shadow_q` 不是最终硅结构

`MatrixRegFile.sv` 中的大宽度 `tile_shadow_q / acc_shadow_q` 是行为便利结构，不应直接进入面积建模。

---

## 10. 建议冻结给 DSE 的架构版本

用于 DSE 的单一、自洽架构冻结版本可定义为：

### 10.1 计算阵列

- 数据流：
  - `WS`
- 目标 tile：
  - `M`
  - `N`
  - `K`
- 计算角色：
  - 两个 tile 源
  - 一个 acc 目的 / 累加

### 10.2 本地矩阵寄存器

- tile regs：
  - 数量参数化
  - 容量参数化
- acc regs：
  - 数量参数化
  - 容量参数化
- 物理 baseline：
  - 一寄存器一宏
- 传输 beat：
  - 由 `AXI_DATA` 定义

### 10.3 行几何

- tile row bytes：
  - 参数化
- acc row bytes：
  - 参数化

### 10.4 DMA / 外存

- 外存接口：
  - AXI master
- AXI 数据宽度：
  - 参数化
- read outstanding：
  - 参数化
- write outstanding：
  - 参数化
- read response：
  - single ID
  - in-order

### 10.5 访问模式

需要覆盖至少三类：

1. whole-register load/store
2. shaped normal load/store
3. shaped transpose load/store

其中 `stride` 单位为字节。

---

## 11. 建议 DSE 扫描的参数

建议将 DSE 参数分为三组。

### 11.1 必扫参数

- `matrixTileRegCount`
- `matrixAccRegCount`
- tile macro size
- acc macro size
- AXI beat width
- read outstanding depth
- PE 阵列规模
- `K` 归约宽度

### 11.2 强烈建议扫描的参数

- one-register-one-macro vs multi-bank-per-register
- tile / acc 容量比例
- tile row bytes / acc row bytes
- 是否双缓冲
- DMA command queue depth
- DMA load/store 是否可部分重叠

### 11.3 第二阶段再扫的参数

- multiple AXI IDs
- out-of-order read response
- store outstanding > 1
- regfile 与 compute 之间更细粒度 bank 拆分
- tile/acc 数量进一步扩展

---

## 12. 建议 DSE 输出的指标

建议至少输出下面这些指标：

- 总面积
- 仅矩阵本地 SRAM 面积
- 仅矩阵本地 SRAM 静态功耗
- 仅矩阵本地 SRAM 动态读功耗
- 仅矩阵本地 SRAM 动态写功耗
- 单次 tile load latency
- 单次 acc load/store latency
- 满负载时 PE 利用率
- 外存带宽需求
- 对 `prefill-like` 大矩阵批量搬运的吞吐
- 对 `decode-like` 小批量频繁搬运的效率

---

## 13. DSE 相关论文与资料

下面分成两类：

1. 方法论 / 工具类经典论文
2. 近年的 memory-centric / Transformer / LLM 相关论文

### 13.1 方法论 / 工具类

#### MAESTRO

- 标题：`Understanding Reuse, Performance, and Hardware Cost of DNN Dataflows: A Data-Centric Approach Using MAESTRO`
- 年份：`2018`
- 链接：<https://arxiv.org/abs/1805.02566>
- 为什么相关：
  - 最适合拿来理解数据流、复用、buffer 访问次数和带宽需求
  - 做自研 DSE 工具时，非常适合作为中间 cost model 的方法论参考

#### Gemmini

- 标题：`Gemmini: Enabling Systematic Deep-Learning Architecture Evaluation via Full-Stack Integration`
- 年份：`2019`
- 链接：<https://arxiv.org/abs/1911.09925>
- 为什么相关：
  - 典型 `systolic array + scratchpad + accumulator` 组织
  - 和 Coral 当前 `tile + acc + DMA` 思路最接近的开源参考之一

#### ZigZag

- 标题：`ZigZag: A Memory-Centric Rapid DNN Accelerator Design Space Exploration Framework`
- 年份：`2020`
- 链接：<https://arxiv.org/abs/2007.11360>
- 为什么相关：
  - 特别强调 memory hierarchy 和 mapping 联合探索
  - 对 banked local memory / mapping 影响分析很有参考价值

### 13.2 近年的 memory-centric / LLM 相关论文

#### A Configurable and Efficient Memory Hierarchy for Neural Network Hardware Accelerator

- 年份：`2024`
- 链接：<https://arxiv.org/abs/2404.15823>
- 为什么相关：
  - 直接讨论本地 memory hierarchy 的可配置性
  - 适合用来参考“容量缩减多少、性能损失多少”的分析方法

#### OpenGeMM

- 标题：`OpenGeMM: A High-Utilization GeMM Accelerator Generator with Lightweight RISC-V Control and Tight Memory Coupling`
- 年份：`2024`
- 链接：<https://arxiv.org/abs/2411.09543>
- 为什么相关：
  - 带有 lightweight RISC-V control 和 tightly coupled multi-banked scratchpad
  - 与 Coral 当前“CPU 驱动 + 本地矩阵存储 + strided memory access”高度相关

#### Hybrid Systolic Array Accelerator with Optimized Dataflow for Edge Large Language Model Inference

- 年份：`2025`
- 链接：<https://arxiv.org/abs/2507.09010>
- 为什么相关：
  - 明确讨论 LLM `prefill` 和 `decode` 两阶段的不同瓶颈
  - 适合参考“算力主导 vs 带宽主导”下，矩阵本地存储应如何配比

#### AccLLM

- 标题：`AccLLM: Accelerating Long-Context LLM Inference Via Algorithm-Hardware Co-Design`
- 年份：`2025`
- 链接：<https://arxiv.org/abs/2505.03745>
- 为什么相关：
  - 重点是长上下文 LLM 的 memory / bandwidth 问题
  - 虽然不直接等价于 Coral，但有助于决定未来是否需要进一步偏 memory-centric

### 13.3 Coral 本地参考资料

以下资料不是标准 DSE 论文，但和 Coral 当前方向直接相关：

- `doc/REFERENCE/CUTEv2_zh.md`
  - 作用：
    - 提供一个“CPU + decoupled matrix unit + independent memory loader + scratchpad”的近年参考方向
- `doc/matrix_dma_spec.md`
  - 作用：
    - 给出 Coral 当前矩阵 DMA 的目标结构和术语定义
- `hdl/verilog/matrix/PE.md`
  - 作用：
    - 给出 Coral 当前 WS 计算后端的微架构 intent

---

## 14. 对另一个 AI 的明确指令

若以本文档作为 Coral DSE 的输入约束，则应遵循以下规则：

1. 不要把 `shadow_q` 当作正式硅上存储容量
2. 不要把 Chisel 侧旧 `MatrixMemDirectIO` 当作最终内存系统
3. 以 “beat 级访问 + direct-DRAM DMA” 作为 memory-path baseline
4. 以 “参数化 `M/N/K` + `WS` 数据流” 作为 compute-side baseline
5. 第一阶段重点做 `MatrixRegFile + MatrixDma` 的容量 / 带宽 / 组织 DSE
6. 如果计算后端需要参数化，优先扫：
   - PE array 规模
   - tile/acc 容量
   - one-register-one-macro vs banked register file
   - AXI outstanding depth

---

## 15. 一句话总结

当前 Coral 最值得做 DSE 的版本，不是“旧的 whole-register bring-up RTL”，也不是“尚未完全接入的最终系统”，而是：

> 一个由标量核驱动、以 tile/acc 分离的本地矩阵寄存器文件为核心、以 beat 级 AXI DMA 直接访问 DRAM、并服务于参数化 `M/N/K` 的 WS 矩阵乘加后端的矩阵子系统。
