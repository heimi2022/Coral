# CUTEv2：面向多样化 CPU 架构、设计开销极低的统一可配置矩阵扩展

Jinpeng Ye, Chongxi Wang, Wenqing Li, Bin Yuan, Shiyi Wang, Fenglu Zhang, Junyu Yue, Jianan Xie, Yunhao Ye, Haoyu Deng, Yingkun Zhou, Xin Cheng, Fuxin Zhang, Jian Wang

中国科学院计算技术研究所处理器全国重点实验室，中国科学院大学

## 摘要

矩阵扩展已经成为现代 CPU 中应对 AI 工作负载激增需求的关键特性。然而，现有设计往往带来显著的硬件与软件设计开销。矩阵单元与 CPU 流水线的紧耦合使其难以集成到不同类型的 CPU 中，而细粒度的同步指令又妨碍了高性能内核的开发。

本文提出了一种统一且可配置的 CPU 矩阵扩展架构。通过将矩阵单元与 CPU 流水线解耦，该设计在保持与现有计算和存储资源紧密协同的同时，实现了低开销集成。该可配置矩阵单元支持混合精度运算，并能够适应多样化的算力需求和存储带宽约束。本文还提出了一种具备灵活粒度的异步矩阵乘法抽象，它屏蔽了底层硬件细节，简化了矩阵与向量的重叠执行，并支持统一的软件栈。

我们将该架构集成到四个开源 CPU RTL 平台中，并在具有代表性的 AI 模型上进行了评估。在 GEMM 工作负载下，所有平台上的矩阵单元利用率均超过 90%。当将本设计配置为与 Intel AMX 相当的计算吞吐和内存带宽时，在 ResNet、BERT 和 Llama3 上分别获得了 1.57 倍、1.57 倍和 2.31 倍的加速，其中超过 30% 的性能收益来自矩阵与向量执行的重叠。一个 4 TOPS@2GHz 的矩阵单元在 14nm CMOS 工艺下仅占用 0.53 mm²。上述结果表明，该设计具备很强的跨平台适应性和硬件—软件协同优化能力，为开源社区提供了一种实用的矩阵扩展方案。

## 1 引言

AI 技术的快速发展推动了其在自然语言处理、计算机视觉、多模态生成和具身智能等领域的广泛部署，覆盖从边缘设备到数据中心的各类平台。作为通用计算系统的基础组成部分，CPU 在执行多样化 AI 任务方面仍然发挥着关键作用。为了应对矩阵密集型计算需求的持续增长，主流 CPU 厂商已在产品中引入矩阵扩展，包括 Intel AMX、Arm SME 和 IBM MMA。RISC-V 社区也提出了若干矩阵扩展标准，例如 IME、VME 和 AME。这些扩展能够有效利用现有的计算与存储资源，尤其是向量单元和缓存子系统，以较小的面积与功耗开销显著提升 AI 性能。

然而，现有 CPU 矩阵扩展在硬件集成和软件可编程性方面仍面临挑战。从硬件角度看，矩阵单元通常与 CPU 流水线紧密耦合，需要与向量寄存器堆或 Load/Store 单元频繁交互。细粒度的同步矩阵指令会引入大量结构冒险和数据冒险，增加集成复杂度与验证成本，也限制了其在不同微架构之间的可移植性。从软件角度看，AI 工作负载通常会将矩阵乘法与大量逐元素算子结合在一起，这要求矩阵单元与向量单元进行紧密协作。在单一指令流中表达这种细粒度的交织执行，会给程序员和编译器都带来沉重负担，增加内核设计与调度的复杂性。

为了解决上述问题，本文提出了一种统一且可配置的 CPU 矩阵扩展架构，目标是在不同平台上实现敏捷集成与高效执行。矩阵单元被精心设计为与 CPU 流水线解耦，从而避免对寄存器文件和存储路径进行侵入式修改，降低协同设计和验证复杂度。为适应不同的算力与带宽约束，该架构支持由计算—带宽约束模型指导的灵活微架构配置，并可从 0.5 TOPS 扩展到 32 TOPS，以保证资源利用率和平台适配性。矩阵单元支持 FP8、INT8、FP16、BF16 和 TF32 等混合精度计算，以满足不同精度与性能需求。在 ISA 与编程模型方面，本文仅定义了一条异步矩阵乘法指令和一个同步原语，形成了一个最小但统一的接口，并支持灵活粒度。这一抽象隐藏了硬件相关细节，简化了矩阵—向量重叠执行的编程，并使可移植的软件栈成为可能。

我们将所提出的架构集成并验证于四个开源 CPU RTL 平台：Rocket、Shuttle、BOOM 和香山昆明湖。进一步地，我们将 GEMM 及 AI 推理性能与 Intel AMX、Arm SME 和 IBM MMA 进行了对比。在所有集成平台上，该矩阵单元在 GEMM 工作负载中的利用率都超过 90%。在配备 512 位 Saturn 向量单元、4 TOPS@8-bit 矩阵单元以及 48 GB/s 内存带宽的 Shuttle CPU 上，相比 Xeon 8580，本设计在 ResNet、BERT 和 Llama3 推理上分别获得了 1.57 倍、1.57 倍和 2.31 倍的加速。矩阵—向量重叠执行分别贡献了三项工作负载性能增益中的 66.7%、50.9% 和 33.6%。该设计还优于 IBM S1022 MMA 和 Apple M4 SME。一个 4 TOPS@2GHz 的矩阵单元在 14nm CMOS 中仅占用 0.53 mm²。

本文的主要贡献如下：

- 提出了一种统一且可配置的 CPU 矩阵扩展架构，可实现跨平台的敏捷集成和高效执行。
- 给出了一套软硬件协同设计方案，在具有代表性的 AI 模型上相较商用 CPU 矩阵扩展取得了显著性能提升。
- 将该矩阵扩展集成到四个开源 CPU RTL 平台中，并将全部 RTL 实现和高性能内核完整开源。

## 2 背景

### 2.1 AI 工作负载

AI 工作负载已广泛部署在从边缘设备到数据中心的各种计算平台上。典型模型通常由具有异构特征的不同层组成。计算密集型层，例如线性层、注意力层和卷积层，主要由矩阵乘法主导；而逐元素操作，例如激活、量化/反量化和归一化，则通常是内存密集型的。

论文中的图 1 展示了三个代表性模型 ResNet、BERT 与 Llama3 的结构及其内核融合策略。算子融合通过利用数据局部性、将多个算子组合成分块流水，可以减少内存访存流量并提升资源利用率。

图 1：AI 模型结构与内核融合模式。

### 2.2 相关工作

近年来，Intel、Arm、IBM 等 CPU 厂商以及 RISC-V 社区都引入了矩阵扩展，以增强通用处理器上的 AI 能力。这些扩展通常采用细粒度的同步矩阵指令，并在寄存器架构、执行模型以及集成策略方面各不相同。

IBM MMA 与 RISC-V IME 复用了向量单元的数据通路，将部分向量寄存器文件重用为累加器，并将矩阵操作限制在向量寄存器上。因此，寄存器大小和带宽会限制矩阵运算的粒度与吞吐。IBM Power10 S1022 在 4 GHz 下每核 INT8 峰值可达 2 TOPS。

Arm SME 与 RISC-V VME 引入了专用累加寄存器，使更大的矩阵单元可以从向量寄存器组织中解耦出来。Apple M4 在性能核与能效核上都实现了 SME，其中性能核每核 INT8 峰值可达 4 TOPS。

Intel AMX 与 RISC-V AME 通过引入 tile 寄存器和专用的 Load/Store 路径，将矩阵单元从向量流水线中解耦，使得更大规模的矩阵操作成为可能。Sapphire Rapids 和 Emerald Rapids 的每核 INT8 峰值达到 2 TOPS/GHz，而 Xeon 8580 在 TDP 约束下、2.3 GHz 时可达到 4.6 TOPS。

学术界也对 CPU 矩阵单元进行了研究，既有可配置形式，也有固定规模实现。然而，这些设计通常缺乏与现有 CPU 向量单元的紧密协作，并且在可扩展性和精度支持上较为有限。相比之下，本文引入了一种适配性强、可配置的 CPU 矩阵扩展，为开源社区提供了一个更具实用性的实现方案。

### 2.3 动机

尽管现有 CPU 矩阵扩展已经带来了显著吞吐提升，但在多样 CPU 与多样工作负载上的广泛适用性与执行效率，仍然受到硬件集成和软件可编程性问题的限制。

从硬件集成角度看，大多数现有设计都将矩阵单元与 CPU 流水线紧密耦合，需要在译码、派发与执行各阶段进行侵入式修改。矩阵单元通常需要与向量寄存器堆或 Load/Store 单元交互，这会带来复杂的控制路径和冗余状态管理，增加集成与验证成本。在 Arm SME、IBM MMA 和 RISC-V IME/VME 中，矩阵与向量指令会争用向量寄存器，从而产生结构冒险和数据冒险。尽管 Intel AMX 与 RISC-V AME 引入了独立的 tile 寄存器，并允许直接访问 L1D 或 L2 cache，但它们仍受限于同步语义，这要求体系结构必须通过停顿潜在冲突指令或在 Load/Store 单元内解决地址冲突，来保证矩阵操作与标量/向量内存操作之间的正确性。

从软件可编程性角度看，大多数 CPU 矩阵扩展采用细粒度的同步矩阵指令，迫使开发者手工编排矩阵操作与内存操作之间的调度。更进一步，在 AI 工作负载中，矩阵核与逐元素核往往需要重叠执行，这会显著提升编程复杂度。开发者必须在单一指令流中同时表达内存、矩阵和向量任务，并在有限的指令窗口中尽量保持所有功能单元繁忙。此外，不同矩阵扩展 ISA 与软件接口之间的差异也阻碍了统一抽象，迫使开发者进行与微架构强相关的优化，加剧软件生态的碎片化。

因此，本文提出了一种统一且可配置的 CPU 矩阵扩展架构，以在最小设计开销下实现跨平台的敏捷集成和高效执行。

## 3 架构总览

本文提出的统一可配置 CPU 矩阵扩展基于三条关键设计原则：

1. 矩阵单元在结构上与 CPU 流水线解耦，不需要对译码器、指令发射逻辑、寄存器文件或 Load/Store 单元进行侵入式修改。
2. 矩阵单元内部的微架构参数可配置，以适应不同平台的计算需求和内存系统约束。
3. 定义一种异步矩阵乘法指令抽象，使融合调度能够支持灵活粒度，从而简化编程模型并提升执行效率。

### 表 1：接口寄存器

| 字段 | 类型 | 描述 |
| --- | --- | --- |
| 矩阵尺寸 | `uint32` | `{M, N, K}` |
| 内存基地址 | `uint64` | `Base {A, B, Bias, C}` |
| 内存步长 | `uint32` | `Stride {A, B, Bias, C}` |
| 数据精度 | `enum` | `DataType` |
| Bias 类型 | `enum` | `BiasType`，包括 Zero、Row-Repeat、Full |
| 结果转置标志 | `bool` | `Transpose` |
| 异步操作状态 | `uint32` | `Status` |

### 代码示例 1：编程示例

```cpp
asyncMatMul(TILE_M, TILE_N, K, ...);  // tile 0
for (i = 1; i < (M / TILE_M) * (N / TILE_N); i++) {
    asyncMatMul(TILE_M, TILE_N, K, ...);  // tile i
    checkMatmul();                        // 等待 tile i-1 完成
    ...
    // tile i-1 的 epilogue
}
checkMatmul();  // 等待最后一个 tile
...
// 最后一个 tile 的 epilogue
```

异步矩阵乘法抽象显著降低了矩阵扩展的编程复杂度，并使矩阵—向量融合执行成为可能。上面的示例展示了一个先进行矩阵乘法、再执行逐元素 epilogue 计算的融合内核。`asyncMatMul` 宏为每个 tile 派发一个任务，tile 的尺寸由 CPU 与矩阵单元之间共享存储的容量决定。在异步执行期间，CPU 的 issue window 可以被向量单元充分利用，用于执行 epilogue 操作。在向量计算进行时，`checkMatmul` 指令确保相应 tile 的矩阵乘法已经完成，从而正确处理数据依赖。

论文中的图 3 给出了整体硬件架构。矩阵单元与 CPU 流水线解耦，由异步矩阵乘法指令驱动。根据 ISA 与微架构支持情况，CPU 可以通过类似 RoCC 或基于 CSR 的接口派发这些指令，对应寄存器如表 1 所示。矩阵单元通过适配平台的互连独立连接到缓存或内存，而不依赖 CPU 自身的 Load/Store 单元。这样的设计降低了集成复杂度，支持在多种 CPU 上快速部署，并允许针对嵌入式、边缘和高性能平台灵活配置微架构。

图 2：现有 CPU 矩阵扩展。

图 3：架构总览。

## 4 设计

### 4.1 矩阵单元微架构

如图 4 所示，矩阵单元主要由 Memory Loader、Scratchpad、Data Controller 和 PE Array 组成。

Memory Loader 负责生成访存请求，并处理矩阵计算中的所有数据读写。其中，请求生成器会将矩阵乘法指令描述的张量映射为内存地址和 Scratchpad 地址，生成并发出相应请求。Data Reorder 模块接收返回数据，按需要进行重排，并将其写入目标存储。

Scratchpad 用于临时存储矩阵分块，以提高矩阵单元中的数据复用率。累加结果可以保留在 Scratchpad 中，从而减少高精度结果写回内存的需求。多 bank 的 Scratchpad 还可以进一步支持数据加载与计算任务的重叠。

Data Controller 负责向计算阵列供数。论文中实例化了三个 Data Controller：其中两个专门服务于矩阵乘法中的源矩阵 A 和 B，另一个则服务于 bias 与累加矩阵 C。

PE Array 将外积与向量点积运算结合起来，其中操作数 A 按行广播，操作数 B 按列广播。每个 PE 执行内部乘加操作，并支持 TF32、BF16、FP16、INT8 与 FP8 等混合精度计算。在每个 PE 内，乘法结果会被对齐到统一指数、截断并累加。该 PE 被组织为六级流水，以在 14nm 工艺下达到 2 GHz 的工作频率。

图 4：矩阵单元微架构。

### 4.2 可配置矩阵扩展

为了支持生成具备不同计算能力的实现，本文提供了一组可配置的微架构参数，用以针对不同 SoC 的算力需求调节矩阵单元。

表 2 给出了矩阵单元的可配置微架构参数，以及一个与 Intel Xeon 8580 AMX 的计算吞吐与数据带宽对齐的案例配置。PE 阵列的吞吐由 `M_pe`、`N_pe` 与 `K_pe` 决定。对于一个 `n` 位数据格式，其理论吞吐为：

$$
\text{Throughput}(n\text{-bit}) = Freq \times M_{pe} \times N_{pe} \times (K_{pe} / n) \times 2
$$

参数 `M_scp`、`N_scp` 与 `K_scp` 则定义了 Scratchpad 的大小。通过调节 Scratchpad 容量，可以使矩阵单元的数据复用水平适配不同的内存带宽约束。为了避免计算资源浪费，作者指出，在输出驻留（output-stationary）调度策略下，应保证矩阵乘法循环中的计算时间不超过访存时间：

$$
\frac{M_{scp} \times N_{scp} \times K_{scp}}
{Freq \times M_{pe} \times N_{pe} \times K_{pe}}
\le
\frac{(M_{scp} + N_{scp}) \times K_{scp}}
{DataBandwidth}
$$

其中，`DataBandwidth` 表示低层存储层次结构能够提供的数据供给带宽，它由缓存结构、片上网络与 QoS、内存带宽以及其他系统因素共同决定。

### 表 2：可配置体系结构参数

| 参数 | 含义 | 案例配置 |
| --- | --- | --- |
| `Freq` | 时钟频率 | 2.0 GHz |
| `M_pe` | PE 阵列行数 | 4 |
| `N_pe` | PE 阵列列数 | 4 |
| `K_pe` | PE 归约宽度 | 512 Bits |
| `M_scp` | Scratchpad 中最大常驻 `M` | 64 |
| `N_scp` | Scratchpad 中最大常驻 `N` | 64 |
| `K_scp` | Scratchpad 中最大常驻 `K` | 64 Bytes |
| 数据带宽 | 数据供给带宽 | 48 GB/s |
| 8-bit 吞吐 | 峰值吞吐 | 4 TOPS |

### 4.3 向量—矩阵重叠

异步矩阵乘法抽象允许矩阵任务从 CPU 流水线中发出后便不再占用流水线，直到其完成，从而为矩阵—向量重叠创造了更多机会。

对于图 1 所示算子，作者采用代码示例 1 中的方法实现矩阵—向量融合内核：向量单元负责执行 prologue 和 epilogue，而矩阵单元负责线性层和卷积。矩阵乘法与向量操作在矩阵分块粒度上通过软件流水进行编排，从而形成图 5 所示的融合执行行为。

图 5：向量与矩阵的重叠执行。

### 4.4 低设计开销集成

作者将所提出的矩阵扩展集成到表 3 所列的四个开源 CPU RTL 平台中，覆盖了从顺序单发射到乱序六发射的不同处理器架构。对于 Rocket、Shuttle 和 BOOM，集成复用了 RoCC 接口，整个工作在数天内完成；对于香山昆明湖处理器，则新增了一个 CSR 接口，耗时数周。整体来看，在这四个处理器上，集成矩阵扩展仅需额外修改 200 到 500 行 RTL 代码，说明该设计具有很强的易集成性。

### 表 3：集成开发成本

| CPU | 微架构 | 接口 | 代码行数 | 时间 |
| --- | --- | --- | ---: | --- |
| Rocket | 顺序，1 发射 | RoCC | 254 | 3 天 |
| Shuttle | 顺序，3 发射 | RoCC | 512 | 5 天 |
| BOOM | 乱序，4 发射 | RoCC | 301 | 3 天 |
| XiangShan | 乱序，6 发射 | CSR | 361 | 3 周 |

注：代码行数指与集成相关的 RTL 修改行数。

## 5 评估

### 5.1 方法

实验环境如表 4 所示，其中 Rocket、Shuttle 和 BOOM 在 Chipyard 平台上评估，香山昆明湖在 XiangShan 平台上评估。表 4 还给出了用于验证矩阵扩展可扩展性的参数配置。作为对照，三种商用 CPU 的矩阵扩展配置则列在表 2 的案例配置一栏中。

本文选择了三种能够代表现有工作的商用矩阵扩展作为基线，并使用 8-bit 推理在 ResNet-50 v1.5、BERT-base 与 Llama3.2-1B 上进行评测。Llama3.2-1B 采用 SmoothQuant-O1 量化以维持精度。峰值性能与每核内存带宽如表 5 所示，其中内存带宽使用 MLC 与 STREAM 测得。IBM S1022 使用两个线程来充分利用 MMA 单元。Intel AMX 使用 OneDNN v3.9 与 OpenVINO 2025.2.0；Arm SME 使用 KleidiAI 1.14.0 与 ONNX Runtime 1.21；IBM MMA 使用 OpenBLAS 0.3.27 与 ONNX Runtime 1.16.3。

### 表 4：实验设置与配置

| 参数 | 配置 |
| --- | --- |
| SoC 框架 | Chipyard + Verilator + DRAMSim |
| CPU 核心 | Rocket / Shuttle / BOOM / Kunminghu |
| 向量单元 | 512-bit RVV Saturn |
| PE 阵列规模 | 2×2 / 4×4 / 8×8 / 16×16 |
| PE 归约宽度 | 256 / 512 Bits |
| 时钟频率 | 2.0 GHz |
| 数据带宽 | 8 / 16 / 32 / 48 / 64 GB/s |

注：Kunminghu 在 XiangShan SoC 平台上评估。

### 表 5：基线配置

| 平台 | 框架 | ISA/扩展 | 带宽 | INT8 峰值 |
| --- | --- | --- | --- | --- |
| IBM S1022 | ONNX Runtime | MMA | 52.37 GB/s | 2 TOPS |
| Apple M4 | ONNX Runtime | SME | 131.31 GB/s | 4 TOPS |
| Xeon 8580 | OpenVINO | AMX | 49.48 GB/s | 4.6 TOPS |

### 5.2 在多种 CPU 平台上的集成效果

在 Rocket、Shuttle、BOOM 和昆明湖四个平台上，作者均将矩阵扩展配置为 2 TOPS 的峰值吞吐，并使用 `M = 512`、`N = 512`、`K` 从 256 到 8192 变化的 GEMM 工作负载进行测试。图 6 表明，所有平台上的矩阵单元利用率均超过 90%。这说明所提出的矩阵扩展能够很好地适配不同 CPU 架构。

图 6：不同 CPU 平台上的 GEMM 性能。

### 5.3 不同规模下的矩阵单元配置

作者在 Shuttle CPU 上、在四种带宽设置下实例化了面向不同峰值算力目标的矩阵扩展配置。如图 7 所示，Scratchpad 的大小依据公式（2）进行配置。GEMM 工作负载设置与第 5.2 节相同。结果显示，在所有配置中，矩阵单元利用率大约都能达到 80%。这表明该矩阵扩展既能适配受带宽约束的嵌入式场景，也能适配高性能 CPU，具有良好的可扩展性。

图 7：不同配置下的 GEMM 性能。

### 5.4 多种工作负载下的性能

在这一部分中，作者将 Shuttle CPU 上的矩阵扩展配置为表 2 的案例参数，并与 512-bit Saturn 向量单元配对，使其作为 Xeon 8580 上 AMX 扩展的对应实现。随后将其与表 5 中三种商用处理器在四个代表性工作负载上进行比较。

对于 GEMM，如图 8 所示，所提出的矩阵扩展优于 Xeon 8580（OneDNN）和 IBM S1022（OpenBLAS），并接近 Apple M4（KleidiAI）。性能波动主要来自 DRAMSim 在不同 stride 访存模式下可提供带宽的变化。

对于 ResNet-50，如图 9 所示，AMX（OpenVINO）在算子支持方面优于 MMA（ORT）和 SME（ORT）。得益于 Xeon 8580 的 300 MiB L3 cache，所有权重和激活都可以被缓存，从而获得更高的有效内存带宽。目前 SME 还缺乏对卷积算子的支持。在不使用向量—矩阵融合内核时，本文实现的性能与 AMX 相当；启用融合内核后，相比 Xeon 8580、IBM S1022 和 Apple M4，总体性能分别达到 1.57 倍、8.87 倍和 5.04 倍。

对于 BERT，如图 10 所示，以小规模矩阵乘法为主的 Transformer 模型对矩阵单元利用率提出了挑战。现有厂商扩展由于矩阵规模较小，只能实现有限的利用率。借助对小规模矩阵更好的支持，本文实现相较 Xeon 8580（OpenVINO）、IBM S1022（ORT）和 Apple M4（ORT）分别实现了 1.57 倍、3.33 倍和 2.11 倍加速。

对于 Llama3，如图 11 所示，Llama3 的 Transformer 结构比 BERT 更复杂，并且需要 SmoothQuant 等较新的量化方法来控制精度损失，这要求硬件与软件之间具备更敏捷的协同优化能力。与 BERT 相比，Llama3 包含更大规模的矩阵乘法，因此本设计中的矩阵单元能够达到更高利用率。这同时也使得向量操作的执行时间与矩阵操作更加接近，因而内核融合能够带来更显著收益。相较 Xeon 8580（OpenVINO）、IBM S1022（ORT）和 Apple M4（ORT），本文矩阵扩展分别实现了 2.31 倍、3.08 倍和 3.16 倍加速，高于在 BERT 上观察到的结果。这说明在新兴工作负载上，CPU 矩阵扩展仍然存在大量软硬件协同优化空间。

作者指出，其实现中的 Score（S*）操作性能较低，原因是 Softmax 占主导且 Saturn 的向量吞吐有限；而 Gate 和 Up 之间的明显差距则来自 SiLU 中的浮点除法。在 Saturn 上，向量除法是逐元素实现的，并受到向量吞吐限制。这也说明当前开源 RVV 向量单元仍然具有较大优化潜力。

图 8：与现有扩展相比的 GEMM 性能。

图 9：与现有扩展相比的 ResNet-50 性能。

图 10：与现有扩展相比的 BERT 性能。

图 11：与现有扩展相比的 Llama3 性能。

### 表 6：加速比

| 实现 | Xeon 8580 ResNet | Xeon 8580 BERT | Xeon 8580 Llama3 | IBM S1022 ResNet | IBM S1022 BERT | IBM S1022 Llama3 | Apple M4 ResNet | Apple M4 BERT | Apple M4 Llama3 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 我们的方法（未融合） | 1.19 | 1.28 | 1.87 | 7.16 | 2.72 | 2.39 | 3.82 | 1.72 | 2.55 |
| 我们的方法（融合） | 1.57 | 1.57 | 2.31 | 8.87 | 3.33 | 3.08 | 5.04 | 2.11 | 3.16 |

注：R、B、L 分别表示 ResNet-50、BERT-base 和 Llama3.2-1B。

作者进一步指出，相较三种商用处理器扩展，当前商用平台上的内核实现尚未充分发挥矩阵硬件潜力。本文融合实现相较未融合实现所展现出的显著提升，说明所提出的编程模型更容易挖掘矩阵硬件的全部能力。

### 5.5 面积与功耗

作者将第 5.4 节中的矩阵扩展配置在 14nm 工艺下进行了综合，工作频率可达 2 GHz。表 7 报告了其面积与功耗。对于一个 4 TOPS@2GHz 的配置，总面积为 0.531 mm²，总功耗为 1.506 W。

### 表 7：面积与功耗评估（4 TOPS@2GHz）

| 项目 | 面积（mm²） | 功耗（W） |
| --- | ---: | ---: |
| RAM | 0.164 | 0.784 |
| Logic | 0.367 | 0.722 |
| Total | 0.531 | 1.506 |

## 6 结论

总体而言，本文提出了一种统一且可配置的 CPU 矩阵扩展架构，能够促进跨平台的敏捷集成与高效执行。该架构已经部署到多个开源 CPU 平台上，并在不同配置和多种工作负载下持续展现出高性能，从而验证了其适应性与可扩展性。这一工作为开源社区提供了一个实用的 CPU 矩阵扩展方案。未来工作将继续探索 CPU 矩阵扩展的潜力。

## 7 致谢

本工作得到 ICT Innovation Grant E461100 的支持。

## 参考文献

以下参考文献保留原文条目格式：

[1] Alon Amid, David Biancolin, Abraham Gonzalez, Daniel Grubb, Sagar Karandikar, Harrison Liew, Albert Magyar, Howard Mao, Albert Ou, Nathan Pemberton, Paul Rigge, Colin Schmidt, John Wright, Jerry Zhao, Yakun Sophia Shao, Krste Asanović, and Borivoje Nikolić. 2020. Chipyard: Integrated Design, Simulation, and Implementation Framework for Custom SoCs. IEEE Micro 40, 4 (2020), 10–21.

[2] Guido Araujo, Jose Moreira, Rafael Sene, and Erich Focht. 2025. Integrated Matrix Extension. https://github.com/riscv-admin/integrated-matrix-extension.

[3] Arm. 2025. KleidiAI. https://gitlab.arm.com/kleidi/kleidiai.

[4] Krste Asanović, Rimas Avizienis, Jonathan Bachrach, Scott Beamer, David Biancolin, Christopher Celio, Henry Cook, Daniel Dabbelt, John Hauser, Adam Izraelevitz, Sagar Karandikar, Ben Keller, Donggyu Kim, John Koenig, Yunsup Lee, Eric Love, Martin Maas, Albert Magyar, Howard Mao, Miquel Moreto, Albert Ou, David A. Patterson, Brian Richards, Colin Schmidt, Stephen Twigg, Huy Vo, and Andrew Waterman. 2016. The Rocket Chip Generator. Technical Report. http://www2.eecs.berkeley.edu/Pubs/TechRpts/2016/EECS-2016-17.html

[5] Hongtao Chen, Weiyu Xie, Boxin Zhang, Jingqi Tang, Jiahao Wang, Jianwei Dong, Shaoyuan Chen, Ziwei Yuan, Chen Lin, Chengyu Qiu, Yuening Zhu, Qingliang Ou, Jiaqi Liao, Xianglin Chen, Zhiyuan Ai, Yongwei Wu, and Mingxing Zhang. 2025. KTransformers: Unleashing the Full Potential of CPU/GPU Hybrid Inference for MoE Models. In Proceedings of the ACM SIGOPS 31st Symposium on Operating Systems Principles (SOSP) (Lotte Hotel World, Seoul, Republic of Korea). ACM, 1014–1029.

[6] Francesco Conti, Gianna Paulin, Angelo Garofalo, Davide Rossi, Alfio Di Mauro, Georg Rutishauser, Gianmarco Ottavi, Manuel Eggiman, Hayate Okuhara, and Luca Benini. 2024. Marsellus: A Heterogeneous RISC-V AI-IoT End-Node SoC With 2–8 b DNN Acceleration and 30%-Boost Adaptive Body Biasing. IEEE Journal of Solid-State Circuits 59, 1 (2024), 128–142.

[7] Tri Dao. 2023. Flashattention-2: Faster attention with better parallelism and work partitioning. arXiv preprint arXiv:2307.08691 (2023).

[8] Tri Dao, Daniel Y. Fu, Stefano Ermon, Atri Rudra, and Christopher Ré. 2022. FLASHATTENTION: fast and memory-efficient exact attention with IO-awareness. In Proceedings of the 36th International Conference on Neural Information Processing Systems (NIPS) (New Orleans, LA, USA). Curran Associates Inc., Article 1189, 16 pages.

[9] OpenVINO developers. 2025. Intel Distribution of OpenVINO Toolkit. https://github.com/openvinotoolkit/openvino.

[10] ONNX Runtime developers. 2021. ONNX Runtime. https://onnxruntime.ai/.

[11] Jacob Devlin, Ming-Wei Chang, Kenton Lee, and Kristina Toutanova. 2019. BERT: Pre-training of Deep Bidirectional Transformers for Language Understanding. In Proceedings of the 2019 Conference of the North American Chapter of the Association for Computational Linguistics: Human Language Technologies (NAACL-HLT) (Minneapolis, MN, USA). Association for Computational Linguistics, 4171–4186.

[12] Greg Favor. 2025. Vector-Matrix Extension. https://riscv.atlassian.net/wiki/spaces/VMEX/pages/554991628/Vector-Matrix+Extension+VME+-+PoW.

[13] Peng Gao, Yang Liu, Haonan Sun, Jiang Jiang, Jun Wang, Zonghui Hong, and Jiali Qu. 2025. OASIS: A Commercial High Performance Terminal AI Processor Supporting RISC-V Tensor Extension Instructions. In Proceedings of the 58th IEEE/ACM International Symposium on Microarchitecture (MICRO) (New York, NY, USA). ACM, 1264–1283.

[14] Hasan Genc, Seah Kim, Alon Amid, Ameer Haj-Ali, Vighnesh Iyer, Pranav Prakash, Jerry Zhao, Daniel Grubb, Harrison Liew, Howard Mao, Albert Ou, Colin Schmidt, Samuel Steffl, John Wright, Ion Stoica, Jonathan Ragan-Kelley, Krste Asanovic, Borivoje Nikolic, and Yakun Sophia Shao. 2021. Gemmini: Enabling Systematic Deep-Learning Architecture Evaluation via Full-Stack Integration. In 2021 58th ACM/IEEE Design Automation Conference (DAC) (San Francisco, CA, USA). 769–774.

[15] Aaron Grattafiori, Abhimanyu Dubey, Abhinav Jauhri, Abhinav Pandey, Abhishek Kadian, Ahmad Al-Dahle, Aiesha Letman, Akhil Mathur, Alan Schelten, Alex Vaughan, et al. 2024. The llama 3 herd of models.

[16] Kaiming He, Xiangyu Zhang, Shaoqing Ren, and Jian Sun. 2016. Deep Residual Learning for Image Recognition. In 2016 IEEE Conference on Computer Vision and Pattern Recognition (CVPR) (Las Vegas, NV, USA). IEEE, 770–778.

[17] Pouya Houshmand, Giuseppe M. Sarda, Vikram Jain, Kodai Ueyoshi, Ioannis A. Papistas, Man Shi, Qilin Zheng, Debjyoti Bhattacharjee, Arindam Mallik, Peter Debacker, Diederik Verkest, and Marian Verhelst. 2023. DIANA: An End-to-End Hybrid DIgital and ANAlog Neural Network SoC for the Edge. IEEE Journal of Solid-State Circuits 58, 1 (2023), 203–215.

[18] Intel. 2024. Intel 64 and IA-32 Architectures Optimization Reference Manual. https://cdrdv2-public.intel.com/814201/355308-Optimization-ReferenceManual-049-Changes-Doc.pdf.

[19] Intel. 2025. Intel Memory Latency Checker v3.12. https://www.intel.com/content/www/us/en/developer/articles/tool/intelr-memory-latency-checker.html.

[20] Benjamin Lefaudeux, Francisco Massa, Diana Liskovich, Wenhan Xiong, Vittorio Caggiano, Sean Naren, Min Xu, Jieru Hu, Marta Tintore, Susan Zhang, Patrick Labatut, Daniel Haziza, Luca Wehrstedt, Jeremy Reizenstein, and Grigory Sizov. 2022. xFormers: A modular and hackable Transformer modelling library. https://github.com/facebookresearch/xformers.

[21] Héctor Martínez, Adrián Castelló, Francisco D. Igual, and Enrique S. Quintana-Ortí. 2026. The cambrian explosion of mixed-precision matrix multiplication for quantized deep learning inference. Future Generation Computer Systems (2026).

[22] John D. McCalpin. 1995. Memory Bandwidth and Machine Balance in Current High Performance Computers. IEEE Computer Society Technical Committee on Computer Architecture (TCCA) Newsletter (Dec. 1995).

[23] José E Moreira, Kit Barton, Steven Battle, Peter Bergner, Ramon Bertran, Puneeth Bhat, Pedro Caldeira, David Edelsohn, Gordon Fossum, Brad Frey, et al. 2021. A matrix math facility for Power ISA (TM) processors. arXiv preprint arXiv:2104.03142 (2021).

[24] oneDNN Contributor. 2025. oneAPI Deep Neural Network Library (oneDNN). https://github.com/uxlfoundation/oneDNN.

[25] Eric Qin, Ananda Samajdar, Hyoukjun Kwon, Vineet Nadella, Sudarshan Srinivasan, Dipankar Das, Bharat Kaul, and Tushar Krishna. 2020. SIGMA: A Sparse and Irregular GEMM Accelerator with Flexible Interconnects for DNN Training. In 2020 IEEE International Symposium on High Performance Computer Architecture (HPCA) (San Diego, CA, USA). 58–70.

[26] Vijay Janapa Reddi, Christine Cheng, David Kanter, Peter Mattson, Guenther Schmuelling, Carole-Jean Wu, Brian Anderson, Maximilien Breughe, Mark Charlebois, William Chou, Ramesh Chukka, Cody Coleman, Sam Davis, Pan Deng, Greg Diamos, Jared Duke, Dave Fick, J. Scott Gardner, Itay Hubara, Sachin Idgunji, Thomas B. Jablin, Jeff Jiao, Tom St. John, Pankaj Kanwar, David Lee, Jeffery Liao, Anton Lokhmotov, Francisco Massa, Peng Meng, Paulius Micikevicius, Colin Osborne, Gennady Pekhimenko, Arun Tejusve Raghunath Rajan, Dilip Sequeira, Ashish Sirasao, Fei Sun, Hanlin Tang, Michael Thomson, Frank Wei, Ephrem Wu, Lingjie Xu, Koichi Yamada, Bing Yu, George Yuan, Aaron Zhong, Peizhao Zhang, and Yuchen Zhou. 2020. MLPerf inference benchmark. In Proceedings of the ACM/IEEE 47th Annual International Symposium on Computer Architecture (ISCA) (Virtual Event). IEEE Press, 446–459.

[27] Stefan Remke and Alexander Breuer. 2024. Hello SME! Generating Fast Matrix Multiplication Kernels Using the Scalable Matrix Extension. In Workshops of the International Conference for High Performance Computing, Networking, Storage and Analysis (SC24-W) (Atlanta, GA, USA). IEEE Press, 1443–1454.

[28] Paul Rosenfeld, Elliott Cooper-Balis, and Bruce Jacob. 2011. DRAMSim2: A Cycle Accurate Memory System Simulator. IEEE Computer Architecture Letters 10, 1 (2011), 16–19.

[29] Rafael Sene and Philipp Tomsich. 2023. Attached Matrix Extension. https://github.com/riscv-admin/attached-matrix-extension.

[30] William J. Starke and Brian W. Thompto. 2020. IBM’s POWER10 Processor. In IEEE Hot Chips 32 Symposium, HCS 2020, Palo Alto, CA, USA, August 16-18, 2020 (Palo Alto, CA, USA). IEEE, 1–43.

[31] Josse Van Delm, Anton Lydike, Joren Dumoulin, Jonas Crols, Xiaoling Yi, Ryan Antonio, Jackson Woodruff, Tobias Grosser, and Marian Verhelst. 2025. The Configuration Wall: Characterization and Elimination of Accelerator Configuration Overhead. To appear in Proceedings of ASPLOS 2026.

[32] Guangxuan Xiao, Ji Lin, Mickaël Seznec, Hao Wu, Julien Demouth, and Song Han. 2023. SmoothQuant: Accurate and Efficient Post-Training Quantization for Large Language Models. In International Conference on Machine Learning (ICML) (Honolulu, Hawaii, USA) (Proceedings of Machine Learning Research, Vol. 202). PMLR, 38087–38099.

[33] Yinan Xu, Zihao Yu, Dan Tang, Guokai Chen, Lu Chen, Lingrui Gou, Yue Jin, Qianruo Li, Xin Li, Zuojun Li, Jiawei Lin, Tong Liu, Zhigang Liu, Jiazhan Tan, Huaqiang Wang, Huizhe Wang, Kaifan Wang, Chuanqi Zhang, Fawang Zhang, Linjuan Zhang, Zifei Zhang, Yangyang Zhao, Yaoyang Zhou, Yike Zhou, Jiangrui Zou, Ye Cai, Dandan Huan, Zusong Li, Jiye Zhao, Zihao Chen, Wei He, Qiyuan Quan, Xingwu Liu, Sa Wang, Kan Shi, Ninghui Sun, and Yungang Bao. 2023. Towards Developing High Performance RISC-V Processors Using Agile Methodology. In Proceedings of the 55th Annual IEEE/ACM International Symposium on Microarchitecture (MICRO) (Chicago, Illinois, USA). IEEE Press, 1178–1199.

[34] Xiaoling Yi, Ryan Antonio, Joren Dumoulin, Jiacong Sun, Josse Van Delm, Guilherme Pereira Paim, and Marian Verhelst. 2025. OpenGeMM: A Highly-Efficient GeMM Accelerator Generator with Lightweight RISC-V Control and Tight Memory Coupling. In Proceedings of the 30th Asia and South Pacific Design Automation Conference (Tokyo, Japan). ACM, 1055–1061.

[35] Martin Kroeker Zhang Xianyi. 2025. OpenBLAS. https://github.com/OpenMathLib/OpenBLAS.

[36] Jerry Zhao, Daniel Grubb, Miles Rusch, Tianrui Wei, Kevin Anderson, Borivoje Nikolic, and Krste Asanović. 2024. The Saturn Microarchitecture Manual. Technical Report. EECS Department, University of California, Berkeley. http://www2.eecs.berkeley.edu/Pubs/TechRpts/2024/EECS-2024-215.html

[37] Jerry Zhao, Ben Korpan, Abraham Gonzalez, and Krste Asanovic. 2020. SonicBOOM: The 3rd Generation Berkeley Out-of-Order Machine. In Fourth Workshop on Computer Architecture Research with RISC-V (CARRV).

[38] Jerry Zhao, Jennifer Zhou, Albert Ou, Abraham Gonzalez, and Lux Zhang. 2023. Shuttle: A Rocket-based Superscalar In-order RISC-V Core. https://github.com/ucb-bar/shuttle/tree/master.
