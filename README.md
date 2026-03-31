# Coral 工作区

这是一个面向 Coral NPU 学习、RTL 开发、仿真验证、综合实现以及矩阵扩展探索的本地硬件开发工作区。

## 顶层目录结构

当前仓库根目录主要包含以下内容：

```text
.
├── NPU/
├── coralnpu/
├── picorv32/
├── doc/
└── riscv-matrix-extension-spec/
```

## 目录说明

- `coralnpu/`
  Coral NPU 主源码树。这里是当前最重要的上游风格工程，包含 Chisel RTL、Bazel 构建规则、软件、测试和官方文档。

- `picorv32/`
  本地 PicoRV32 源码树，可作为参考设计或集成组件使用。

- `NPU/`
  本地实现工作区，主要放生成后的 RTL、仿真脚本和综合脚本。
  当前包含：
  - `NPU/1-RTL/`：整理后的 RTL 产物或生成后的 Verilog
  - `NPU/2-SIM/`：仿真脚本、filelist、testbench 辅助文件
  - `NPU/3-SYN/`：多文件版本综合流程
  - `NPU/3-SYN-Single/`：单文件版本综合流程

- `doc/`
  本地学习笔记、计划和工作记录目录。

- `riscv-matrix-extension-spec/`
  玄铁 RISC-V 矩阵扩展提案及相关参考资料的本地副本。

## 建议先看哪里

- 当前工作计划、学习笔记、参数决策、矩阵扩展推进记录：
  [`doc/coral.md`](/home/wjj/2-NPU/doc/coral.md)

- Coral 主工程说明：
  [`coralnpu/README.md`](/home/wjj/2-NPU/coralnpu/README.md)

- 玄铁矩阵扩展规范源码：
  [`riscv-matrix-extension-spec/spec/`](/home/wjj/2-NPU/riscv-matrix-extension-spec/spec)

## 推荐阅读路径

如果要理解或修改 Coral 本体，建议从这里开始：

- [`coralnpu/hdl/`](/home/wjj/2-NPU/coralnpu/hdl)
- [`coralnpu/tests/`](/home/wjj/2-NPU/coralnpu/tests)
- [`coralnpu/sw/`](/home/wjj/2-NPU/coralnpu/sw)

如果要使用本地仿真或综合流程，建议从这里开始：

- [`NPU/2-SIM/`](/home/wjj/2-NPU/NPU/2-SIM)
- [`NPU/3-SYN/`](/home/wjj/2-NPU/NPU/3-SYN)
- [`NPU/3-SYN-Single/`](/home/wjj/2-NPU/NPU/3-SYN-Single)

如果要跟踪当前矩阵扩展实现进度，建议直接看：

- [`doc/coral.md`](/home/wjj/2-NPU/doc/coral.md)

该文件目前记录了：

- 学习笔记
- 当前进度
- 参数配置原因
- 矩阵扩展实施计划
- 下一步任务拆解

## 当前使用上的说明

- 当前真正的 Coral 源码在 [`coralnpu/`](/home/wjj/2-NPU/coralnpu)，不是 `NPU/1-RTL/`。
- `NPU/1-RTL/` 更偏向下游流程使用，主要存放整理后的 RTL 产物、拆分版 Verilog 或综合输入文件。
- 这个仓库目前仍处于持续整理和开发阶段，目录组织、脚本和生成产物会继续演进。
