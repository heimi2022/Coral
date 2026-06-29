# Coral Matrix DMA Spec

## 1. 目标

本文档定义 Coral 当前阶段矩阵 DMA（`MatrixDma`）的职责、模块划分和实现边界。

当前路线已经明确为：

```text
MatrixRegFile <-> MatrixDma <-> DRAM
```

也就是：

- 不走标量 LSU / DTCM 路径
- 由矩阵 DMA 直接通过 AXI master 访问外部 DRAM
- 矩阵寄存器文件对 DMA 暴露 `256b beat` 级读写口

本文档重点描述当前已经定下来的版本：

- read 路径支持 **parameterized outstanding**
- **暂不支持 out-of-order 返回处理**
- DMA 命令队列深度 **参数化**
- 当前默认可缓存 **3 条命令**
- 命令完成语义 **串行**
- 当前命令进入 `draining` 尾段后，允许下一条命令的 burst **尾部预发**

## 2. 当前设计结论

### 2.1 当前优先级

当前阶段优先做对下面这几件事：

- 把 load/store 从“元素级事务”重构为“burst 级事务”
- 把 read outstanding 做成参数化
- 先支持 in-order response handling
- 先把 DMA 内部职责拆清楚，再决定哪些模块先做空壳、哪些先写实现

### 2.2 当前不做的事情

当前版本明确不做：

- out-of-order response handling
- 多 AXI ID 调度
- 基于 `RID` 的 context table 回填
- 多条命令同时并行执行
- DDR bank-aware 地址分配策略
- cache coherence
- 矩阵计算
- 指令 decode / dispatch

## 3. 顶层语义

### 3.1 DMA 命令、AXI burst、beat

为了避免术语混乱，本文档固定使用下面三层名字：

- `DMA命令`
  - 一条来自 `MatrixCore` 的矩阵 load/store 请求
- `AXI burst`
  - 一次 `AR` 或 `AW` 地址握手定义的一笔 burst 事务
- `beat`
  - burst 中的一拍数据传输

当前 DMA 的基本重构方向是：

- 一条 DMA 命令
- 被拆成若干个 AXI burst
- 每个 AXI burst 再由若干个 beat 构成

### 3.2 命令执行模型

当前版本采用：

- 命令队列深度参数化，默认 `3`
- 命令完成语义串行
- burst 发射允许局部重叠
- load 命令先进入 FIFO，再由 load 子系统按接收顺序逐条执行

因此：

- **命令完成语义串行**
- **总线传输相位允许尾部搭接**

## 4. 参数

建议当前版本至少固定下面这些参数：

```text
AXI_DATA_W               = 256
AXI_ADDR_W               = 32
CMD_QUEUE_DEPTH          = 3
READ_OUTSTANDING_DEPTH   = 4   // 默认值，后续可 sweep
WRITE_OUTSTANDING_DEPTH  = 1   // 当前保守实现
```

说明：

- `READ_OUTSTANDING_DEPTH` 只做成参数化，当前默认值先取 `4`
- 这个默认值不是理论最优值，只是第一版的工程起点
- 后续应结合真实 burst 长度和 DRAM 延迟做 sweep，再决定默认配置

## 5. 矩阵寄存器组织

基于当前参数配置：

- tile 寄存器：4 个
- acc 寄存器：4 个
- tile 单寄存器宽度：`16384b = 2048B`
- acc 单寄存器宽度：`32768b = 4096B`
- DMA 与寄存器文件之间的基本搬运粒度：`256b = 32B`

因此：

- 单个 tile = `2048B / 32B = 64 beats`
- 单个 acc = `4096B / 32B = 128 beats`

对 DMA 来说：

- tile beat 编号范围：`0..63`
- acc beat 编号范围：`0..127`

## 6. 命令接口语义

当前命令接口保持不变：

```verilog
input  logic                     mem_valid_i,
output logic                     mem_ready_o,
input  logic [31:0]              mem_pc_i,
input  logic                     mem_dir_i,
input  logic [2:0]               mem_reg_i,
input  logic                     mem_layout_i,
input  logic                     mem_whole_i,
input  logic [1:0]               mem_elem_bytes_i,
input  logic [31:0]              mem_base_i,
input  logic [31:0]              mem_stride_i,
input  logic [7:0]               mem_rows_i,
input  logic [7:0]               mem_cols_i
```

关键语义：

- `mem_dir_i`
  - `0 = load`
  - `1 = store`
- `mem_reg_i`
  - 使用 spec 同款 `3bit` 编码
  - `000..011 = tr0..tr3`
  - `100..111 = acc0..acc3`
- `mem_layout_i`
  - `0 = normal`
  - `1 = transpose`
- `mem_whole_i`
  - `1 = whole-register`
  - `0 = shaped`
- `mem_stride_i`
  - row stride，单位为字节
- `mem_rows_i / mem_cols_i`
  - shaped 模式逻辑矩阵尺寸

命令握手语义更新为：

- DMA 内部命令队列深度参数化，当前默认 `3`
- 当命令队列未满时，`mem_ready_o = 1`
- 当前只保证命令**按接收顺序完成**

## 7. shaped 访问语义

### 7.1 normal 布局

normal 布局下：

```text
dram_addr(row, col) = base + row * stride + col * elem_bytes
```

### 7.2 transpose 布局

transpose 布局下：

```text
dram_addr(row, col) = base + col * stride + row * elem_bytes
```

### 7.3 对 stride 的当前理解

当前文档里的 `stride` 指的是：

- **row stride**
- 即相邻两逻辑行在 DRAM 中的地址跨度

它不等价于“每隔几个元素取一次”的稀疏 gather。

因此对 shaped load/store 的正确实现方式应该是：

- 一行内尽量合并成连续 burst
- 行与行之间再按 `stride` 跳转

而不是：

- 每个元素都单独发一笔小事务

## 8. outstanding 模型

### 8.1 计数单位

当前文档固定：

- `1 outstanding entry = 1 AXI read burst`

不是：

- 1 个元素
- 1 条 DMA 命令
- 1 个 beat

### 8.2 当前版本的 read outstanding 规则

当前版本明确采用：

- read 支持 `READ_OUTSTANDING_DEPTH` 个 burst 在途
- write 先保守为 `1` outstanding
- 暂不支持 out-of-order response handling
- read 返回按发出顺序处理

也就是：

- multiple outstanding
- single ID
- inflight FIFO
- in-order response only

### 8.3 为什么当前不做 out-of-order

当前版本的主要目标是先解决：

- 单元素事务过于低效
- DRAM latency 无法被覆盖
- shaped / whole 统一到 burst 级搬运

因此当前阶段：

- 先把 request 并发做出来
- 不急着把 response 乱序接收/乱序提交做满

未来如果需要升级为：

- multiple ID
- `RID -> context` 查表
- out-of-order response handling

那时再把 inflight FIFO 升级成 context table。

## 9. DMA 内部模块划分

当前建议把 `MatrixDma` 内部先拆成下面几个模块。

### 9.1 `MatrixDmaPkg.sv`

职责：

- 存共用 `typedef`
- 存共用 helper function

建议放入：

- `MatrixDmaCmd`
- `MatrixDmaBurstDesc`
- `MatrixDmaInflightEntry`
- `MatrixDmaBeatInfo`
- `elem_bytes_from_width`
- `row_bytes_for_kind`
- 首尾 mask 生成函数

### 9.2 `MatrixDmaCmdQueue.sv`

职责：

- 缓存 DMA 命令
- `CMD_QUEUE_DEPTH` 参数化，当前默认 `3`
- 向后级暴露按接收顺序出队的命令流

它只负责：

- 接命令
- 排命令
- 弹命令

它不负责：

- AXI 调度
- burst 切分
- 矩阵寄存器访问

### 9.3 `MatrixDmaBurstGen.sv`

职责：

- 把一条 DMA 命令拆成若干个 burst descriptor
- 处理：
  - whole/shaped 统一规划
  - row stride
  - layout
  - 4KB 边界切分
  - 首尾 mask 生成

当前版本里，它是最核心的“命令 -> burst”转换层。

它还需要维护：

- `issued_bursts`
- `total_bursts`
- `all_bursts_issued`
- `draining`

以及：

- 何时允许在当前命令尾段预发后续命令的 burst

### 9.4 `MatrixDmaReadEngine.sv`

职责：

- 接收 burst descriptor
- 驱动 AXI read address/data 通道
- 实现 `READ_OUTSTANDING_DEPTH`
- 用 inflight FIFO 跟踪在途 burst
- 输出按顺序返回的 beat 流

当前版本中它的行为应该是：

- single ID
- in-order response only
- response 完成条件为：
  - `RVALID && RREADY && RLAST`

### 9.5 `MatrixDmaLoadCommit.sv`

职责：

- 把 `ReadEngine` 返回的 beat 流，落到矩阵寄存器
- 负责：
  - `reg_wr_kind_o`
  - `reg_wr_idx_o`
  - `reg_wr_beat_o`
  - `reg_wr_data_o`
  - `reg_wr_strb_o`

如果后续要加：

- staging buffer
- line buffer
- tile buffer

它们也应优先落在这一层附近，而不是继续堆到 DMA 顶层。

### 9.6 `MatrixDmaWriteEngine.sv`

职责：

- 负责 store / 结果写回的 burst 级 AXI 写行为
- 当前版本可以先保持简单
- 先不急着把 write outstanding 做深

### 9.7 `MatrixDma.sv`

顶层只负责：

- 例化上述模块
- 汇总 `busy/done/fault`
- 接 `MatrixRegFile`
- 接 AXI

顶层尽量不再承载大段具体控制逻辑。

## 10. 推荐的数据通路

### 10.1 load 路径

```text
MatrixCore cmd
    -> MatrixDmaCmdQueue
        -> MatrixDmaBurstGen
            -> MatrixDmaReadEngine
                -> MatrixDmaLoadCommit
                    -> MatrixRegFile
```

当前推荐策略：

- 命令级串行
- burst 级并发
- 返回按顺序处理

### 10.2 store 路径

```text
MatrixRegFile
    -> MatrixDmaWriteEngine
        -> AXI write
            -> DRAM
```

当前 write 路径可以先简单实现，不必和 read 路径同步升级复杂度。

## 11. burst descriptor 建议字段

当前建议的 burst descriptor 至少包含：

- `cmd_tag`
  - 用来标识该 burst 属于哪一条在途命令
- `dir`
  - load / store
- `dram_addr`
  - burst 起始地址
- `burst_bytes`
  - 该 burst 总字节数
- `first_mask`
  - 首 beat 字节有效掩码
- `last_mask`
  - 尾 beat 字节有效掩码
- `dst_base_byte_off`
  - 对矩阵寄存器的目标字节偏移
- `pc`
  - 该 burst 所属原始命令 PC

如果后续要支持 out-of-order，再考虑补充：

- `id`
- `context_idx`

## 12. inflight FIFO 建议字段

因为当前不做 out-of-order，inflight 先按 FIFO 组织即可。

每个 inflight entry 建议包含：

- `valid`
- `cmd_tag`
- `dir`
- `burst_bytes`
- `first_mask`
- `last_mask`
- `dst_base_byte_off`
- `pc`
- `error_seen`

当前版本不需要：

- `RID -> entry` 查找
- 多 ID allocator

## 13. 矩阵寄存器接口

当前接口保持：

```verilog
output logic                     reg_rd_en_o,
output logic                     reg_rd_kind_o,
output logic [REG_IDX_W-1:0]     reg_rd_idx_o,
output logic [REG_BEAT_W-1:0]    reg_rd_beat_o,
input  logic [AXI_DATA_W-1:0]    reg_rd_data_i

output logic                     reg_wr_en_o,
output logic                     reg_wr_kind_o,
output logic [REG_IDX_W-1:0]     reg_wr_idx_o,
output logic [REG_BEAT_W-1:0]    reg_wr_beat_o,
output logic [AXI_DATA_W-1:0]    reg_wr_data_o,
output logic [AXI_DATA_W/8-1:0]  reg_wr_strb_o
```

约束：

- DMA 和 `MatrixRegFile` 的基本交互粒度始终是 `256b beat`
- whole 模式通常整 beat 有效
- shaped 模式下首尾 beat 可能是部分掩码

## 14. AXI backend 的当前位置

当前工程里已有：

- `MatrixDmaLoad.sv`
- `AxiReadBurstCtrl.v`
- `AXI4_write_ctrl.v`

当前代码边界进一步更新为：

- `MatrixDmaLoad.sv`
  - 已经开始承接完整 load 子系统职责
  - 内部自己接收 load 命令、做命令排队、二维遍历、单元素 burst 发射与寄存器写回
- `MatrixDma.sv`
  - 对 load 侧尽量只保留连接与结果汇总
  - store 侧暂时仍留在顶层

但文档口径更新为：

- `MatrixDmaLoad / AxiReadBurstCtrl / AXI4_write_ctrl`
  - 更像底层 AXI burst 时序执行器与 load 子路径执行器
- DMA 自己才负责：
  - 命令级控制
  - burst 规划
  - outstanding 调度
  - 矩阵寄存器映射

因此后续不建议继续把“多 burst 大事务拆分逻辑”压在 `AXI4_read_ctrl` 里，而应上移到 `MatrixDmaBurstGen`。

## 15. 非目标

当前版本明确不是下面这些设计：

- 单元素一事务 DMA
- 命令级完全并行执行
- 多 ID + out-of-order response
- DDR bank-aware allocator
- 完整 cache / coherence aware DMA

## 16. 当前实现顺序建议

建议按下面顺序推进：

1. 先把 `matrix_dma_spec.md` 对齐到当前架构
2. 定义 `MatrixDmaPkg.sv`
3. 定义 `MatrixDmaCmdQueue.sv`
4. 定义 `MatrixDmaBurstGen.sv`
5. 定义 `MatrixDmaReadEngine.sv`
6. 跑通：
   - `3` 条命令默认缓存
   - `READ_OUTSTANDING_DEPTH=4`
   - single ID
   - in-order read return
7. 再补 `MatrixDmaLoadCommit.sv`
8. 最后再重构 write 路径

## 17. 当前版本总结

当前版本的 `MatrixDma` 可以概括为一句话：

```text
先把矩阵 DMA 做成“命令级串行、burst 级并发、read outstanding 参数化、返回按顺序处理”的 DRAM 搬运引擎。
```

它不是最终高性能版本，但它会是一个非常适合继续演进的中间架构：

- 比当前单元素事务强很多
- 比直接上多 ID / out-of-order 简单很多
- 模块边界清晰
- 后续升级路径明确
