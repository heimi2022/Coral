# Coral Matrix Extension 笔记

## 当前进度

- 已完成 matrix 参数初版配置
  - 已在 `hdl/chisel/src/coralnpu/Parameters.scala` 中加入 `enableMatrix / matrixElen / matrixTlen / matrixTrlen` 等参数
- 已完成 `msettile*` 的 Decode 改造
  - 已加入 `msettilemi/msettilem/msettileki/msettilek/msettileni/msettilen`
  - 已用 `matrixCfg` 通路区分 `SET_M / SET_K / SET_N`
  - 已让 immediate 形式通过 `rs1Set` 注入 `uimm10`
  - 已让 `matrixCfg` 与 CSR 一样要求 `retirement_buffer_empty` 后再发射
- 已完成 `msettile*` 从 `Decode -> SCore -> CSR` 的闭环接通
  - 已把 `dispatch.io.matrixCfg` 接入 `csr.io.matrixCfgReq`
  - 已根据 `matrixCfgReq.op + rs1.data` 更新 `xtilem / xtilek / xtilen`
  - 已去掉普通 CSR 写路径对 `xtilem / xtilek / xtilen` 的直接赋值
- 已完成 `msettile*` 的程序级验证
  - 已新增 `tests/cocotb/tutorial/matrix_cfg_program.cc`
  - 已新增 `tests/cocotb/tutorial/matrix_cfg.py`
  - 已覆盖立即数形式、寄存器形式，以及 `M / K / N` 三个维度的改写验证

## 下一步计划

1. 先冻结 Coral matrix v1 的最小范围
   - 第一版只做 `matrix CSR + 1 条 matrix 指令通路 + 1 个 MatrixUnit 占位实现`
   - 暂时不直接改 `RVV` generated Verilog
   - 暂时不先改 GCC / binutils
2. 继续完善 matrix CSR 与只读能力寄存器
   - 继续整理 `xmcsr / xmisa / xtlenb / xtrlenb / xalenb`
   - 明确 `xtilem / xtilek / xtilen` 的边界值、约束和异常策略
3. 再建立独立 matrix 执行通路
   - 新建 `hdl/chisel/src/coralnpu/matrix/MatrixInterface.scala`
   - 新建 `hdl/chisel/src/coralnpu/matrix/MatrixUnit.scala`
   - 把当前 `matadd` 从 `ALU` 过渡到 `MatrixUnit`
4. 最后补最小验证闭环
   - 补边界值 / 覆写顺序 / 异常场景测试
   - 保留 `msettile*` 的 Decode / Dispatch / Program / Waveform 四层验证
   - 再补一条真正的 matrix 指令执行测试

## `msettile*` 从 Decode 到 CSR 的闭环记录（已完成）

这次工作的重点，是把下面 6 组 matrix config 指令真正接到 CSR 状态里，并完成程序级验证：

- `msettilemi / msettilem`
- `msettileki / msettilek`
- `msettileni / msettilen`

实现依据是：

- `/home/wjj/2-NPU/riscv-matrix-extension-spec/spec`

### Matrix Configuration Instructions 编码表

下表对应 matrix configuration instructions 的编码格式。这里把当前已经实现的 `msettile*` 和暂不实现的 `mrelease` 一起列出来，便于后续对照 `Decode.scala` 检查。

| 指令 | func[31:28] | uop[27:26] | ctrl[25] | 参数域[24:15] | func3[14:12] | nop[11:7] | opcode[6:0] | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `mrelease` | `0000` | `00` | `0` | `0` | `000` | `00000` | `major opcode` | 当前暂不实现 |
| `msettileki` | `0001` | `00` | `0` | `uimm10[9:0]` | `000` | `00000` | `major opcode` | 已实现 |
| `msettilek` | `0001` | `00` | `1` | `00000 / rs1` | `000` | `00000` | `major opcode` | 已实现 |
| `msettilemi` | `0010` | `00` | `0` | `uimm10[9:0]` | `000` | `00000` | `major opcode` | 已实现 |
| `msettilem` | `0010` | `00` | `1` | `00000 / rs1` | `000` | `00000` | `major opcode` | 已实现 |
| `msettileni` | `0011` | `00` | `0` | `uimm10[9:0]` | `000` | `00000` | `major opcode` | 已实现 |
| `msettilen` | `0011` | `00` | `1` | `00000 / rs1` | `000` | `00000` | `major opcode` | 已实现 |

说明：

- immediate 形式里，`uimm10[9:0]` 横跨 `inst[24:15]`
- register 形式里，`ctrl=1`，`rs2=00000`，参数来自 `rs1`
- `mrelease` 编码已记录，但当前阶段暂不实现；原因见后文“当前暂不实现的内容”

### Decode 侧设计关键点

- `Decode.scala` 已识别 6 组 matrix config 指令：
  - `msettilemi / msettilem`
  - `msettileki / msettilek`
  - `msettileni / msettilen`
- 已加入辅助判断函数：
  - `isMatrixCfg()`
  - `isMatrixCfgImm()`
  - `isMatrixCfgReg()`
- 已将 matrix config 指令并入 `forceSlot0Only()`
  - 保证它们只从 `slot0` 发射
- 已新增：
  - `matrixCfg : Valid[MatrixCfgCmd]`
- 目前通过 `MatrixCfgCmd.op` 区分三种配置目标：
  - `SET_M`
  - `SET_K`
  - `SET_N`

### Decode 的统一数据策略

这一版最关键的设计，不是单纯“把指令识别出来”，而是把 immediate 和 register 两种形式统一成一份后端接口：

- `msettilem / msettilek / msettilen`
  - 参数来自真实 `rs1`
- `msettilemi / msettileki / msettileni`
  - 复用现有 `rs1Set`
  - 把 `uimm10` 直接注入为 `rs1.data`

这样后端只需要看：

```text
matrixCfg.op  决定修改 M / K / N
rs1.data      决定写入的新值
```

也就是说，到了 `SCore.scala` 和 `Csr.scala` 之后，就不需要再区分“这是立即数形式还是寄存器形式”。

### 顺序性约束

由于 `msettile*` 修改的是全局 tile shape 状态：

- `mtilem`
- `mtilen`
- `mtilek`

所以这一版已经让它和普通 CSR 一样，要求在 `retirement_buffer_empty` 时才能发射，避免后续矩阵 load/store/compute 看到乱序的 tile 配置。

当前约束可以概括为：

```text
普通指令：不要求 ROB 为空
CSR / MatrixCfg：要求 ROB 为空
```

### 源码落点

- `Decode.scala`
  - 负责识别 `msettile*`
  - 负责把 immediate / register 两种来源统一成 `rs1.data`
- `SCore.scala`
  - 已将 `dispatch.io.matrixCfg` 接到 `csr.io.matrixCfgReq`
  - 已把 `dispatch.io.matrixCfg.valid` 纳入 `csr.io.rs1` 的取数条件
- `Csr.scala`
  - 已根据 `matrixCfgReq.valid` 和 `matrixCfgReq.bits.op` 更新：
    - `xtilem`
    - `xtilek`
    - `xtilen`
  - 已删除普通 CSR 写路径里对这三个寄存器的直接 `wdata` 赋值

### `SCore.scala` 中关键点

- `msettile*` 没有被塞进普通 `csr.io.req` 这条通用 CSR 请求通路
  - 而是单独走：
    - `dispatch.io.matrixCfg`
    - `csr.io.matrixCfgReq`
  - 这样做的好处是，matrix 配置语义不需要伪装成“普通 CSR 编号 + CSR op”才能传到后端
- `csr.io.rs1` 的取数条件做了一个关键扩展
  - 原来只把普通 `dispatch.io.csr.valid` 当成“需要给 CSR 提供 rs1”
  - 现在改成：
    - `dispatch.io.csr.valid || dispatch.io.matrixCfg.valid`
  - 也就是把 `msettile*` 也视为一类“CSR-like”请求
- 这一点很关键，因为 `Csr.scala` 里真正写 `xtilem / xtilek / xtilen` 时，拿到的写入值就是统一的 `io.rs1.data`
  - 对寄存器形式来说，这是 regfile 读出来的真实 `rs1`
  - 对立即数形式来说，这是前面通过 `rs1Set` 注入进去的 `uimm10`
- 这样以后回头看代码时，可以抓住一个核心设计：

```text
Decode 负责把 immediate / reg 两种来源统一成 rs1.data
SCore 负责把这份统一后的 rs1.data 正确送到 CSR
Csr 只关心 op 是 SET_M / SET_K / SET_N，以及 rs1.data 是多少
```

### `Csr.scala` 中值得记录的点

- `msettile*` 在 CSR 内部不是直接组合生效，而是先进一个寄存后的 `matrixCfgReq`
  - 当前写法是：
    - `val matrixCfgReq = RegInit(MakeInvalid(new MatrixCfgCmd))`
  - 然后每拍用 `io.matrixCfg` 去更新它
  - 所以在波形里经常会看到：
    - decode 命中在前
    - `matrixCfgReq_valid` 拉高在后
    - `xtilem / xtilek / xtilen` 更新再跟着发生
- `xtilem / xtilek / xtilen` 现在和普通 matrix CSR 控制位分成了两类入口
  - 一类仍然走普通 CSR 写路径：
    - `xmcsr`
    - `xmxrm`
    - `xmsat`
    - `xmfflags`
    - `xmfrm`
    - `xmsaten`
  - 另一类只允许走 `msettile*` 专用配置路径：
    - `xtilem`
    - `xtilek`
    - `xtilen`
- 这意味着当前实现已经有一个明确分层：
  - matrix rounding / sat / flags 仍是“普通 CSR 语义”
  - tile shape 则是“专用 matrix config 指令语义”
- 现在对 `xtilem / xtilek / xtilen` 的处理是：
  - 可读：仍然能通过 CSR read path 被 `csrr` 读出来
  - 不可被普通 CSR write 直接改写
  - 可被 `msettile*` 修改
- 当前写入逻辑还是最小实现
  - `SET_M -> xtilem := rs1`
  - `SET_K -> xtilek := rs1`
  - `SET_N -> xtilen := rs1`
  - 也就是说，当前先不做数值合法化、边界裁剪或非法值异常
  - 这部分后续如果要和 spec 更严格对齐，还需要继续补
- CSR 末端已经把这 3 个状态继续向外导出：
  - `io.matrix.get.mtilem := xtilem`
  - `io.matrix.get.mtilek := xtilek`
  - `io.matrix.get.mtilen := xtilen`
  - 所以即使现在还没有完整 `MatrixUnit`，tile shape 状态的“保存 + 对外发布”接口已经先立住了

### 当前语义

- `xtilem / xtilek / xtilen` 现在只允许由 `msettile*` 修改
- 普通 CSR 写路径仍可读出这 3 个状态，但不再直接改写它们
- 这样可以让架构语义入口、硬件状态入口和验证口径保持一致

### 程序级验证

为了不只停留在单元测试，这一轮补了独立 program 测试：

- `tests/cocotb/tutorial/matrix_cfg_program.cc`
- `tests/cocotb/tutorial/matrix_cfg.py`

覆盖内容包括：

- `M`：立即数形式 + 寄存器形式
- `K`：立即数形式 + 寄存器形式
- `N`：立即数形式 + 寄存器形式

程序会把每一步 `(m, k, n)` 快照写回输出缓冲区，当前期望序列为：

```text
[0,0,0, 4,0,0, 7,0,0, 7,8,0, 7,9,0, 7,9,16, 7,9,11]
```

对应动作顺序是：

1. 初始值读取
2. `msettilemi 4`
3. `msettilem rs1=7`
4. `msettileki 8`
5. `msettilek rs1=9`
6. `msettileni 16`
7. `msettilen rs1=11`

### 波形观测建议

如果用 `VCS + Verdi` 看这一轮 `msettile*` 行为，最有用的信号是：

- `CoreMiniAxi.dispatch.decodedInsts_0_msettilemi`
- `CoreMiniAxi.dispatch.decodedInsts_0_msettilem`
- `CoreMiniAxi.dispatch.decodedInsts_0_msettileki`
- `CoreMiniAxi.dispatch.decodedInsts_0_msettilek`
- `CoreMiniAxi.dispatch.decodedInsts_0_msettileni`
- `CoreMiniAxi.dispatch.decodedInsts_0_msettilen`
- `CoreMiniAxi.csr.matrixCfgReq_valid`
- `CoreMiniAxi.csr.matrixCfgReq_bits_op`
- `CoreMiniAxi.csr.io_rs1_data`
- `CoreMiniAxi.csr.xtilem`
- `CoreMiniAxi.csr.xtilek`
- `CoreMiniAxi.csr.xtilen`

可以按下面这条链路观察：

```text
指令 decode 命中
-> dispatch 发出 matrixCfg
-> CSR 收到 matrixCfgReq_valid
-> xtilem / xtilek / xtilen 在对应周期更新
```

## 相关代码结构

### SCore 总体框图

如果你接下来要改的是 `hdl/chisel/src/coralnpu/scalar/SCore.scala`，最先要建立的认识是：

- `SCore` 不是单个执行单元
- `SCore` 是标量核这一侧的“总装层”
- 它负责把 `Fetch / Dispatch / Regfile / CSR / LSU / BRU / ALU / MLU / DVU / RetirementBuffer / FaultManager / Debug`
  全部接起来

下面这张图适合先建立“模块之间谁连谁”的整体感觉：

```text
                           +---------------------- SCore ----------------------+
                           |                                                   |
                           |   +--------+      +-----------+                   |
      ibus --------------->|   | Fetch  |----->| Dispatch  |------------------+----+
                           |   +--------+      +-----------+                  |    |
                           |        ^                 |                        |    |
                           |        |                 | rs1/rs2 addr/set       |    |
                           |        |                 v                        |    |
                           |        |            +-----------+                 |    |
                           |        |            | Regfile   |<----------------+    |
                           |        |            +-----------+      writeback        |
                           |        |                 ^                              |
                           |        |                 |                              |
                           |        |                 |                              |
                           |   flush/jump        +---------+                         |
                           |<--------------------| BRU     |                         |
                           |                     +---------+                         |
                           |                                                   +-----v------+
                           |                     +---------+                    | Retirement |
                           |-------------------->| ALU xN  |                    | Buffer     |
                           |                     +---------+                    +------------+
                           |                     +---------+
                           |-------------------->| MLU     |
                           |                     +---------+
                           |                     +---------+
                           |-------------------->| DVU     |
                           |                     +---------+
                           |                     +---------+
      dbus / ebus <------->|<------------------->| LSU     |
                           |                     +---------+
                           |                                                   +------------+
                           |   CSR req / debug req      trap / state / frm --->| CSR        |
                           |--------------------------->+------------+          +------------+
                           |                            |            |<--- BRU / Float / RVV
                           |                            +------------+
                           |
                           |   dispatch fault / fetch fault / lsu fault / rvv trap
                           |---------------------------> +--------------+
                           |                             | FaultManager |
                           |                             +--------------+
                           |
                           |   optional:
                           |   FloatCore / FRegfile
                           |   RvvCore
                           |   Debug tap
                           +-----------------------------------------------------------+
```

可以把 `SCore` 粗略分成 6 件事：

- `Fetch`
  从 `ibus` 取指，把指令和 PC 送进 `Dispatch`
- `Dispatch`
  做前端分发，决定一条指令进入 `ALU / BRU / LSU / CSR / MLU / DVU / Float / RVV` 的哪一路
- `Regfile`
  提供 `rs1/rs2` 数据，并接收执行单元写回
- `CSR`
  保存架构状态，例如 `mepc/mcause/mstatus`，也负责和 `BRU / Float / RVV / Debug` 交互
- `执行单元`
  包括 `ALU / BRU / LSU / MLU / DVU`，可选再接 `FloatCore / RvvCore`
- `RetirementBuffer + FaultManager`
  负责退休顺序、精确异常、trap 汇总和状态一致性

### CSR 连接关系速览

下面这张 ASCII 图适合在开始改 `hdl/chisel/src/coralnpu/scalar/Csr.scala` 前先记住。它表达的是当前 Coral 里 `Csr` 模块的主要输入、输出和上下游关系。

```text
                           +----------------------------------+
                           |           CoreAxiCSR             |
                           |  csr.in[0]  <- pcStart           |
                           |  csr.out[0..8] -> 外部可读寄存器 |
                           +----------------+-----------------+
                                            |
                                            | CsrInOutIO
                                            v
 +----------------+   csr.valid/bits   +----+-----------------------------------+   trace   +-----------+
 |   DispatchV2   | -----------------> |                CSR                      | --------> | RvviTrace |
 +----------------+                    |                                            |           +-----------+
                                       |  req   : CSR 访问请求                     |
 +----------------+   csr cmd / rs1    |  rs1   : 写 CSR 的源操作数               |  rd.data
 |  Debug Module  | -----------------> |  rd    : CSR 读结果                      | --------> +--------------+
 |    (DM)        | <----------------- |  dm    : debug_req / resume_req / step   | <-------- | Debug Module |
 +----------------+      csr_rd        |                                            |           +--------------+
                                       |  bru   : 异常、陷入、mepc/mtvec/mode      |
 +----------------+        rs1         |  float : frm / fflags   (可选)            |
 |    Regfile     | -----------------> |  rvv   : vstart/vl/vtype/... (可选)       |
 |                | <----------------- |  irq   : 外部中断输入                     |
 +----------------+      rd回写        |  counters : nRetired                      |
                                       +----+------------------+-------------------+
                                            ^                  ^
                                            |                  |
                                            | bru              | counters.nRetired
                                            |                  |
                                      +-----+-----+      +-----+---------------+
                                      |   BRU(0)  |      |  RetirementBuffer   |
                                      +-----------+      +---------------------+

      +------------------+                                     +----------------------+
      | Fetch/Uncached   | -- fetch.pc -----------------------> | csr.in[12]           |
      | FetchControl     |                                      | 当前取指 PC sideband |
      +------------------+                                     +----------------------+

      +------------------+                                     +----------------------+
      |    FloatCore     | <---------- float ----------------> | CSR.float            |
      |   (enableFloat)  |                                     +----------------------+
      +------------------+

      +------------------+                                     +----------------------+
      |     RvvCore      | <----------- rvv -----------------> | CSR.rvv              |
      |    (enableRvv)   |                                     +----------------------+
      +------------------+

      +------------------+
      |   Top / SCore    |
      | halted/fault/wfi |
      | irq              |
      +--------+---------+
               ^
               |
               +---------------------- CSR 输出流水线状态
```

读这张图时可以先抓住 4 条主线：

- `DispatchV2 / Debug Module` 负责发起 CSR 访问请求，最终都汇入 `CSR.req`
- `Regfile` 给 `CSR.rs1` 提供写操作数，`CSR.rd` 再把读结果回写回去
- `BRU(0)` 负责和 `CSR` 交换异常、陷入和跳转控制相关状态
- `FloatCore / RvvCore / RetirementBuffer / Fetch / CoreAxiCSR` 都是给 `CSR` 提供“状态”或消费“配置”的外围模块

### CoreAxi / 总线速览

下面这张图可以把 `Fetch / LSU / ITCM / DTCM / AXI` 的主连接关系先记住。它对应的是当前仓库里最常见的 `CoreAxi` 路径。

```mermaid
flowchart LR
    subgraph Core["Core / SCore"]
        Fetch["Fetch / UncachedFetch"]
        LSU["LSU"]
        CSR["CSR / Debug CSR"]
    end

    Fetch -->|IBus| IPath{"地址是否命中 ITCM"}
    IPath -->|是| ITCM["ITCM"]
    IPath -->|否| IBus2Axi["IBus2Axi"]
    IBus2Axi -->|axi_master 读通道| AXIM["外部 AXI Master"]

    LSU -->|DBus| DTCM["DTCM fast path"]
    LSU -->|EBus.internal = 1| Fabric["FabricMux / AxiSlave"]
    LSU -->|EBus.internal = 0| DBus2Axi["DBus2Axi"]
    DBus2Axi -->|axi_master 读写通道| AXIM

    Fabric -->|MemoryRegionType.IMEM| ITCM
    Fabric -->|MemoryRegionType.DMEM| DTCM
    Fabric -->|MemoryRegionType.Peripheral| CSR
    AXIS["外部 AXI Slave"] <-->|访问片上地址空间| Fabric

    DM["Debug Module"] --> ITCM
    DM --> DTCM
```

读这张图时，可以顺手把参数分成 3 类：

- `axi0*`
  主要对应 `L1ICache.scala` 这一类 instruction-side cache 接口参数。
- `axi1*`
  主要对应 `L1DCache.scala` 这一类 data-side cache 接口参数。
- `axi2*`
  是当前 `CoreAxi` 主路径里最活跃的一组参数，贯穿 `ITCM / DTCM / SRAM wrapper / Fabric / AxiSlave / IBus2Axi / DBus2Axi / axi_{slave,master}`。

也就是说，当前默认 `CoreAxi` 路径更适合先记成：

- `Fetch -> IBus -> ITCM 命中直读，未命中走 IBus2Axi -> axi_master`
- `LSU -> DBus -> DTCM`
- `LSU -> EBus -> (Peripheral 走 Fabric/AxiSlave, External 走 DBus2Axi -> axi_master)`

## matadd 实验记录

`matadd` 自定义指令第一版实现的详细记录，已经从这里拆分到独立文档：

- [matadd.md](./matadd.md)

这里保留主线结论：

- `matadd` 第一版已经完成最小闭环验证
- 后续不再继续把矩阵语义堆在普通 `ALU` 里
- 下一阶段转入独立 `MatrixUnit + CSR + Decode/Dispatch` 主线

## 在 Coral 中实现矩阵扩展的总体路线

当前最适合的思路不是一开始就改 RVV 大核，也不是先并编译器，而是先在 Coral 标量前端里增加一套独立的 `matrix extension` 通路，再逐步向玄铁矩阵扩展靠拢。

### 实施原则

- 先做 `subset`，不要第一版就追完整 Xuantie matrix spec
- 先做 RTL + CSR + 最小指令闭环，再考虑 toolchain / intrinsic
- 不修改 generated RVV 大文件，优先改 Chisel 源码
- 不把矩阵操作长期塞在普通 `ALU` 里，要单独建 `MatrixUnit`

### 当前目标

当前版本的目标已经收敛为一个最小、可验证、可扩展的子集：

- 固定参数：
  - `ELEN = 32`
  - `TLEN = 256`
  - `TRLEN = 64`
- 已完成：
  - `msettilemi/msettilem`
  - `msettileki/msettilek`
  - `msettileni/msettilen`
  - `xtilem / xtilek / xtilen` 的 CSR 保存与程序级验证

### 当前暂不实现的内容

- `MS / mrelease` 当前阶段暂不实现
- 原因是当前 Coral matrix v1 还没有引入完整的 matrix context status 语义，也还没有真正依赖 `MS` 的上下文切换、dirty tracking 和 `MS=Off` 非法指令检查
- 现阶段优先级更高的是：
  - `xtilem / xtilek / xtilen` 的边界与异常策略
  - `xmcsr / xmisa / xtlenb / xtrlenb / xalenb`
  - `MatrixUnit`
  - `mld / mst / mmacc`
- 等下面这些能力开始进入实现时，再回头补 `MS / mrelease` 会更合适：
  - 需要完整对齐 matrix spec 的 context status 语义
  - 需要支持 `mrelease`
  - 需要实现 `MS=Off` 时对 matrix 指令和 matrix CSR 的非法访问检查
  - 需要做真正的 matrix context save/restore 或上下文切换优化

### 当前参数配置为什么这样选

当前 Coral matrix v1 准备采用下面这组实现参数：

```scala
var enableMatrix = false
val matrixElen = 32
val matrixTlen = 256
val matrixTrlen = 64

def matrixRowNum: Int = { matrixTlen / matrixTrlen }
def matrixArlen: Int = { matrixRowNum * matrixElen }
def matrixAlen: Int = { matrixArlen * matrixRowNum }

val matrixTileRegCount = 4
val matrixAccRegCount = 4

def matrixTlenBytes: Int = { matrixTlen / 8 }
def matrixTrlenBytes: Int = { matrixTrlen / 8 }
def matrixAlenBytes: Int = { matrixAlen / 8 }
```

根据 spec，矩阵扩展的三个基础实现参数是：

- `ELEN` 表示矩阵操作可生产或消费的最大元素位宽
- `TLEN` 表示单个 tile register 的总位宽
- `TRLEN` 表示 tile register 单行位宽

spec 还定义了三个由它们推导出来的量：

- `ROWNUM = TLEN / TRLEN = 256 / 64 = 4`
- `ARLEN = (TLEN / TRLEN) * ELEN = 4 * 32 = 128`
- `ALEN = ARLEN * ROWNUM = 128 * 4 = 512`

因此当前硬件含义就是：

- tile register 总宽度 `256bit`
- tile register 每行 `64bit`
- tile register 一共 `4` 行
- accumulation register 每行 `128bit`
- accumulation register 总宽度 `512bit`

这组参数和计划中的 `4x4` 脉动阵列正好能自然对齐。

如果输入元素最大是 `16bit`：

- tile 每一行可放 `64 / 16 = 4` 个元素
- 一共有 `4` 行
- 所以一个 source tile 正好就是 `4 x 4`

如果输出累加元素按 `32bit`：

- accumulation 每一行可放 `128 / 32 = 4` 个元素
- 一共有 `4` 行
- 所以一个 accumulation tile 也正好就是 `4 x 4`

也就是说，这套参数可以直接支撑下面这个映射：

- `4 x 4` tile 输入块进入脉动阵列
- `4 x 4` accumulation tile 保存输出块
- `mtilem / mtilen / mtilek` 的第一版最大目标值都可以先收敛到 `4`

为什么 `matrixTileRegCount` 和 `matrixAccRegCount` 都先定成 `4`：

- spec 的程序模型就是 `4` 个 tile registers `tr0-tr3`
- 以及 `4` 个 accumulation registers `acc0-acc3`
- load/store 语义里也默认 tile index 是 `0-3`，acc index 是 `4-7`

这组参数还能直接映射到只读 CSR：

- `xtlenb = 256 / 8 = 32`
- `xtrlenb = 64 / 8 = 8`
- `xalenb = 512 / 8 = 64`

所以，当前这套配置的本质不是“完全照搬 Xuantie 某个现成实现”，而是在遵守其参数模型的前提下，为 Coral 第一版 `4x4`、`16bit` 输入、`32bit` 累加的脉动阵列原型做的最小收敛选择。

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

这些入口当前分别对应：

- 参数开关与实现规模
- CSR 状态与 matrix 配置
- 指令前端识别与分发
- `matadd` 的过渡实现
- 标量核与顶层接线

### 后续主线

后续只保留 4 条主线，避免计划表过细后很快过时：

1. 完善 matrix CSR
   - 整理 `xmcsr / xmisa / xtlenb / xtrlenb / xalenb`
   - 明确 `xtilem / xtilek / xtilen` 的边界值与异常策略
2. 建立独立 matrix 通路
   - 新建 `matrix/MatrixInterface.scala`
   - 新建 `matrix/MatrixUnit.scala`
   - 在 `SCore.scala / Core.scala` 中完成接线
3. 补齐数据与计算路径
   - tile / accumulator regfile
   - `mld / mst`
   - 最小 `mmacc`
4. 完善验证与导出
   - 保留 `.insn` 和 bare-metal program 的 bring-up 路线
   - 补程序级与波形验证
   - 最后再整理 RTL 导出和综合流程

### 不建议的路线

- 不建议第一步直接改 generated RVV `.sv`
- 不建议第一步就并入完整玄铁 GCC
- 不建议长期把 matrix 逻辑继续塞在 `Alu.scala`
- 不建议第一版就追 full Xuantie ISA

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

## 附：Coral 工程入门

Coral 工程入门、结构定位和通用使用说明已移到：

- [coral_intro.md](./coral_intro.md)
