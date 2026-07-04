# Coral Matrix / RVV Workspace

这是一个围绕 Google Coral NPU 展开的本地研发仓库，目标不是做上游镜像，而是在 Coral 基础上持续推进矩阵扩展、DMA 重构、RVV 算子实验，以及后续的架构与 DSE 探索。

仓库当前的共享主线有三部分：

- `coralnpu/`：Coral 主源码树，以及在其上进行的本地开发
- `doc/`：架构说明、设计小 spec、实验记录与阶段性结论
- `riscv-matrix-extension-spec/`：矩阵扩展语义和体系结构边界的参考资料

## 仓库定位

这份仓库更像一个“Coral 矩阵化研发工作区”，而不是单纯的软件工程仓库。

它主要承担四类工作：

- 追踪和修改 Coral 主工程
- 承载矩阵寄存器、DMA、Load/Store 等 RTL 方向的本地实现
- 记录架构决策、接口约束、误差分析和验证路径
- 为后续 DSE 工具或其他 AI 分析器提供结构化输入

## 与上游的关系

`coralnpu/` 目录来源于 Google Coral NPU 工程，是当前所有实现、构建和仿真的主要入口。这个根仓库在其外层补充了本地文档、矩阵扩展参考资料，以及一部分不准备直接放进上游仓库的研发内容。

如果要找“真正执行的代码”和“真正参与构建的 RTL”，优先看 `coralnpu/`。如果要理解为什么这样改、接口边界怎么定、下一步往哪里走，优先看 `doc/`。

## 目录说明

### `coralnpu/`

主工程目录，包含 Chisel、Verilog、Bazel 构建规则、示例程序、测试和仿真基础设施。

建议优先关注这些路径：

- `coralnpu/hdl/chisel/src/coralnpu/`
- `coralnpu/hdl/verilog/matrix/`
- `coralnpu/examples/`
- `coralnpu/tests/`
- `coralnpu/sw/`

### `doc/`

本地设计文档目录，推荐先看下面这些文件：

- [`doc/coral_intro.md`](doc/coral_intro.md)
- [`doc/coral.md`](doc/coral.md)
- [`doc/matrix_dma_spec.md`](doc/matrix_dma_spec.md)
- [`doc/coral_matrix_dse_target.md`](doc/coral_matrix_dse_target.md)
- [`doc/coral_matrix_dse_prompt.md`](doc/coral_matrix_dse_prompt.md)
- [`doc/silu_piecewise_quadratic_spec.md`](doc/silu_piecewise_quadratic_spec.md)
- [`doc/coral_axi_silu_service_spec.md`](doc/coral_axi_silu_service_spec.md)

这些文档分别覆盖工程介绍、当前推进记录、DMA 设计、DSE 输入建模、RVV 上的 SiLU 实验，以及外部 AXI 调用 Coral 服务的方案。

### `riscv-matrix-extension-spec/`

该目录主要用于对照矩阵扩展语义、寄存器组织和指令行为。阅读矩阵寄存器、矩阵 load/store、累加寄存器或命令语义时，建议与 `doc/` 中的小 spec 一起看。

## 快速开始

下面的命令默认在 `coralnpu/` 目录中执行。

### 生成 RVV Core Verilog

```bash
cd coralnpu
bazel build //hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_emit_verilog
```

常用输出文件：

- `bazel-bin/hdl/chisel/src/coralnpu/RvvCoreMiniAxi.sv`
- `bazel-bin/hdl/chisel/src/coralnpu/VRvvCoreMiniAxi_parameters.h`

### 构建 RVV 示例程序

```bash
cd coralnpu
bazel build //examples:coralnpu_v2_rvv_add_intrinsic
```

### 运行 RVV Verilator 仿真

```bash
cd coralnpu
bazel build //tests/verilator_sim:rvv_core_mini_axi_sim //examples:coralnpu_v2_rvv_add_intrinsic
ELF=$(bazel cquery --output=files //examples:coralnpu_v2_rvv_add_intrinsic.elf | tail -n 1)
./bazel-bin/tests/verilator_sim/rvv_core_mini_axi_sim --binary "./${ELF}"
```

如果要跑带输出的 demo，可以把 ELF 换成 `examples/` 中启用了 semihosting 的目标。

## 建议阅读顺序

第一次进入这个仓库，建议按下面的顺序建立上下文：

1. [`doc/coral_intro.md`](doc/coral_intro.md)
2. [`doc/coral.md`](doc/coral.md)
3. [`coralnpu/README.md`](coralnpu/README.md)
4. [`doc/matrix_dma_spec.md`](doc/matrix_dma_spec.md)
5. [`doc/coral_matrix_dse_target.md`](doc/coral_matrix_dse_target.md)
6. [`doc/silu_piecewise_quadratic_spec.md`](doc/silu_piecewise_quadratic_spec.md)

## 当前研发重点

目前仓库内的主要研发方向包括：

- Coral 上的矩阵扩展集成
- 矩阵寄存器组织与 bank 化设计
- 统一 2D DMA，尤其是 load 路径的 burst 拆分与 outstanding 支持
- RVV 非线性算子实验，例如 SiLU
- 面向片上存储和数据通路的 DSE 输入整理

## 本地文件与共享文件的边界

这个仓库会主动把一部分本地工作目录排除在版本管理之外，例如：

- 本地仿真与综合目录
- IDE、BSP 与索引数据库
- 波形、日志、缓存和临时生成物

例如 `NPU/`、`.bsp/`、波形文件等内容目前都只保留在本地，不作为共享源码的一部分上传。理解或修改公开内容时，应优先以 `coralnpu/` 和 `doc/` 为准。

## 备注

- 这是一个持续演进中的研发工作区，目录组织和文档会随着实现推进继续调整。
- 如果要理解当前矩阵实现，通常不能只看单个 RTL 文件，最好同时结合 `doc/` 中的小 spec 和 `riscv-matrix-extension-spec/` 中的参考语义。
