# PE 相关设计复盘

本文档用于记录当前 `PE / PE array / PE control` 相关 RTL 的设计思路、数据流、关键信号和当前约束，方便后续回看和继续演进。

当前对应模块：

- `src/1-RTL/attention/pe_ws.sv`
- `src/1-RTL/attention/pe_array.sv`
- `src/1-RTL/attention/pe_ctrl.sv`
- `src/1-RTL/attention/matmul_tiling.sv`
- `src/1-RTL/attention/accumulaters.sv`
- `src/1-RTL/attention/fifo.sv`

配套示意图可参考：

![PE array](image.png)

## 1. 设计目标

当前这一版 PE 相关设计，目标是实现一个偏 **WS（Weight Stationary）数据流** 的脉动阵列，用于执行：

```text
C = C + A * B
```

其中：

- `B` 作为权重，尽量静止在 PE 内部
- `A` 作为激活，从阵列顶部逐拍送入
- `C` 不再从阵列顶部输入，而是在 **阵列尾部** 与阵列输出结果做累加

这样做的直接结果是：

- 阵列内部只专注于 `A * B` 的乘加传播
- 历史 `C/psum` 的读取与累加放到阵列尾部统一处理
- 对 `K=64` 这类需要分两段计算的情况，更容易做权重 ping-pong 和部分和写回控制

## 2. 总体结构

从模块职责上看，当前结构可以概括为：

```text
start_i + cfg/rs
    |
    v
matmul_tiling
    |- weight block FIFO
    |- act/psum block FIFO
    v
pe_ctrl
    |- 读权重 rs2
    |- 读激活 rs1
    |- 控制 ping/pong weight bank
    |- 驱动 pe_array
    |- 管理输出 metadata
    |- 读历史 rd 并写回结果
    v
pe_array
    v
pe_ws x (TILE_ROWS * TILE_COLS)
    v
accumulaters
    v
pe_array_o / rd_write_*
```

各模块分工如下：

- `matmul_tiling`
  - 接收一条矩阵乘法命令
  - 按 `m/n/k` 把命令展开成若干个 block 描述
  - 当前只拆 `K` 维，最多拆成两段
- `pe_ctrl`
  - 整个 PE 计算通路的控制中心
  - 负责装权重、发激活、组织计算、组织输出写回
- `pe_array`
  - 负责把大量 `pe_ws` 按阵列方式连起来
  - 主要决定权重、激活、psum valid、bank 选择信号怎么传
- `pe_ws`
  - 单个 PE
  - 内含 ping/pong 两个权重寄存器
  - 完成一次 `act * weight + psum`
- `accumulaters`
  - 阵列尾部累加器
  - 把阵列输出和历史 `C/psum` 相加

## 3. 当前设计约束

这一版代码虽然做了参数化，但**实际设计假设仍然偏 32x32 tile**，使用时要特别注意：

- `TILE_ROWS >= 3`
  - 因为当前 `pe_array` 导出了 `psum_pre_valid_o`、`psum_pre2_valid_o`
- 当前暂不支持 `n > 32`
- 当前 `K` 最大按 `64` 处理
  - 即最多拆成两段
  - 每段最多 `32`
- 当前外部寄存器文件 / SRAM 侧没有完整 ready/valid 握手
  - 默认外部能按请求节奏供数/收数
- 当前很多控制和掩码逻辑，实际上是围绕 `TILE_ROWS=32, TILE_COLS=32` 这一用法写的

## 4. 单个 PE：`pe_ws`

### 4.1 功能

`pe_ws` 是最小计算单元，完成的事情很直接：

1. 保存两份权重：`weight_ping` 和 `weight_pong`
2. 根据 `weight_bank_sel_i` 选择当前参与计算的权重 bank
3. 对激活做简单操作数隔离
4. 计算 `product = act * weight`
5. 将乘积符号扩展后加到 `psum_i`
6. 把 `act_valid / psum_valid / weight_bank_sel / weight` 继续传给下一级

### 4.2 关键点

#### 1. 双权重 bank

PE 内部有两个权重寄存器：

- `weight_ping`
- `weight_pong`

输入：

- `load_weight_ping_i` 为 1 时，把 `weight_i` 写入 `weight_ping`
- `load_weight_pong_i` 为 1 时，把 `weight_i` 写入 `weight_pong`

计算时：

```text
weight_bank_sel_i = 0 -> 选 ping
weight_bank_sel_i = 1 -> 选 pong
```

这样做是为了支持：

- 当前一段 `K` 正在计算时
- 下一段 `K` 的权重可以同时预装到另一个 bank

#### 2. 激活操作数隔离

代码里有：

```text
act_masked = act_i & {ELEM_WIDTH{act_valid_i}}
```

含义是：

- `act_valid_i=1` 时，`act_masked = act_i`
- `act_valid_i=0` 时，`act_masked = 0`

这样可避免无效周期仍然让乘法器看到跳变输入。

#### 3. 内部累加位宽

PE 内部不用完整 `ACC_WIDTH`，而是使用：

```text
PE_ACC_WIDTH = 2 * ELEM_WIDTH + log2(TILE_ROWS)
```

原因是：

- 单次乘法结果宽度是 `2 * ELEM_WIDTH`
- 一个 PE 列向下最多累加 `TILE_ROWS` 个乘积
- 因此只要保留能容纳这部分和的位宽即可

这能减少阵列内部 psum 链路的位宽和成本。

## 5. PE 阵列：`pe_array`

`pe_array` 的职责不是做复杂控制，而是把 `pe_ws` 以特殊拓扑连成一个 WS 脉动阵列。

### 5.1 输入输出

主要输入：

- `weight_tile_i`
  - 一拍输入 `TILE_COLS` 个权重
- `act_top_i`
  - 一拍输入 `TILE_COLS` 个激活
- `act_top_valid_i`
  - 激活有效
- `psum_top_valid_i`
  - 用来从顶部“种下”一次 psum 有效波前
- `weight_bank_sel_i`
  - 从阵列最顶层输入，每列 1 bit

主要输出：

- `psum_bottom_o`
  - 阵列最底行每列吐出的部分和
- `psum_valid_o`
  - 最底行第 0 列吐出的 psum valid
- `psum_pre_valid_o`
  - 倒数第二行第 0 列的 psum valid
- `psum_pre2_valid_o`
  - 倒数第三行第 0 列的 psum valid

### 5.2 激活传播

激活不是简单“竖直向下传”，而是做了一个**斜向传播**：

- 第 0 行 PE 直接接顶部输入 `act_top_i`
- 第 `row>0` 行的某个 PE，从上一行“右边那个 PE”的 `act_o` 接入
- 最后一列会回绕到第 0 列

也就是：

```text
row i, col j 的 act 输入
    <- row i-1, col (j+1) 的 act 输出
```

这种连接方式会在阵列内部形成一条斜着推进的激活波前。

### 5.3 psum 传播

psum 的数据路径相对简单：

- 第 0 行 `psum_i = 0`
- `psum_valid_i` 从顶部灌入
- 后续每一行都接上一行同列的 `psum_o`

也就是：

```text
row i, col j 的 psum 输入
    <- row i-1, col j 的 psum 输出
```

注意：

- 现在顶部不再输入真正的 `psum` 数据
- 顶部只输入 `psum_top_valid_i`
- 真正的 `C/历史 psum` 在阵列尾部才参与累加

### 5.4 权重传播

当前的权重连法是这个设计里最特殊的一块。

#### 基本规则

对于每一列：

- 某一个特定行会直接接收当前拍输入的 `weight_top_vec[col]`
- 其他行的权重来自“上一行”的 `weight_o`
- 第 0 行如果不是注入点，则接收“最后一行”的 `weight_o`

也就是说，权重在每一列内部构成了一个**环形传递**。

#### 注入位置

对第 `col` 列，权重注入行是：

```text
weight_inject_row = (TILE_ROWS - (col % TILE_ROWS)) % TILE_ROWS
```

所以在 `TILE_ROWS=32` 时：

- 第 0 列从第 0 行注入
- 第 1 列从最后 1 行注入
- 第 2 列从最后 2 行注入
- ...

这样做的目的，是让不同列的权重在阵列中形成错位驻留，匹配当前这版 WS 数据流。

### 5.5 weight bank 选择传播

`weight_bank_sel_i` 不是全阵列共用 1 bit，而是**每列 1 bit 从顶部输入**，然后逐行向下传：

- 第 0 行直接接外部输入
- 后续每一行接上一行的 `weight_bank_sel_o`

这样每一列都能知道当前该使用 ping 还是 pong bank。

## 6. 分块前端：`matmul_tiling`

`matmul_tiling` 的作用是把一条矩阵乘法命令展开成后续控制逻辑容易消费的“块描述”。

### 6.1 为什么需要它

当前 `pe_ctrl` 已经不想在状态机里一边处理命令输入，一边现场拆 `m/n/k`。

所以把前端拆分成：

1. 命令输入
2. block 描述生成
3. block 描述入 FIFO
4. 控制状态机只消费 FIFO 队头

这样 `pe_ctrl` 的职责就更清楚了。

### 6.2 当前拆分策略

当前只拆 `K` 维：

- 若 `K <= 32`
  - 只生成 1 个 weight block
  - 只生成 1 个 act/psum block
- 若 `32 < K <= 64`
  - 生成 2 个 weight block
  - 生成 2 个 act/psum block

### 6.3 weight block FIFO

weight 队列里存的不是权重数据本身，而是**怎么去读权重**的描述：

```text
{ rs2, weight_base_addr, weight_k_rows }
```

含义：

- `rs2`
  - 从哪个权重寄存器 / buffer 读
- `weight_base_addr`
  - 这一块权重的“倒序读取起点”
- `weight_k_rows`
  - 这一块需要读多少行

这里采用了**倒序地址语义**：

- 第一块保存 `first_k_chunk_rows - 1`
- 第二块保存 `TILE_ROWS + second_k_chunk_rows - 1`

后面 `pe_ctrl` 会用：

```text
rs2_addr_o = weight_base_addr - weight_count
```

逐拍往前读。

这样如果第一块大小是 32，那么实际读地址顺序就是：

```text
31, 30, 29, ..., 0
```

### 6.4 act/psum block FIFO

当前把激活和输出相关元数据合并到一个 FIFO 里，描述为：

```text
{ rs1, rd, act_base_row, m_rows, n_cols, last }
```

含义：

- `rs1`
  - 激活来源
- `rd`
  - 最终结果写回目标
- `act_base_row`
  - 这块激活从哪一行开始读
- `m_rows`
  - 本块有效 `m`
- `n_cols`
  - 本块有效 `n`
- `last`
  - 这块是不是当前命令的最后一块

这里 `last` 非常重要，因为后面 `pe_ctrl` 用它判断：

- 当前写回是不是一个完整矩阵乘法的最终结果

### 6.5 fill busy

`fill_busy_o` 表示 `matmul_tiling` 正在把一条命令展开并写入 FIFO。

当前 `pe_ctrl` 里的 `cmd_busy_o` 逻辑也会把它考虑进去，用来限制外部继续送新命令。

## 7. 控制核心：`pe_ctrl`

`pe_ctrl` 是这一套设计里最重要的模块，负责把“命令级信息”真正变成“逐拍数据流”。

## 7.1 状态机

当前状态机有 4 个状态：

- `Idle`
- `LoadWeight`
- `StreamPreloadWeight`
- `Stream`

### `Idle`

空闲态。如果 weight FIFO 非空，就准备拉起下一块装权。

### `LoadWeight`

只做一件事：

- 按当前 weight block 的描述，逐拍从 `rs2` 读权重并装入 PE

如果装完以后：

- 发现后面还有下一块权重
  - 进入 `StreamPreloadWeight`
- 否则若还有 act/psum block
  - 进入 `Stream`

### `StreamPreloadWeight`

这是最核心的重叠态：

- 一边计算当前块
- 一边预装下一块权重

这个状态下需要同时跟踪两件事是否做完：

- 当前块的激活流是否跑完
- 下一块的权重是否装完

代码中用了：

- `stream_overlap_done`
- `weight_overlap_done`

来分别记住谁先完成。

### `Stream`

只做纯计算，不再装载新权重。

如果这一块计算完且后面还有权重块，就回到 `LoadWeight`；否则回 `Idle`。

## 7.2 block 描述的消费方式

`pe_ctrl` 不会在整个 block 执行过程中一直盯着 FIFO 队头，而是在进入一个新 block 之前，先 pop 一次，再锁存：

- `weight_rs2`
- `weight_base_addr`
- `weight_k_rows`

以及：

- `stream_rs1`
- `stream_rd`
- `stream_act_base_row`
- `stream_m_rows`
- `active_n_cols`
- `active_k_rows`

后面这个 block 的整段执行，都用这些本地寄存器。

这样可以避免：

- 一边跑 block
- 一边又被 FIFO 队头变化干扰

## 7.3 权重路径

权重读取的核心逻辑是：

```text
rs2_addr_o = weight_base_addr - weight_count
```

其中：

- `weight_base_addr` 由 `matmul_tiling` 给出
- `weight_count` 每装入一行权重就加 1

所以权重读取是倒序的。

当 `rs2_data_valid_i` 有效时：

- 如果当前装的是 ping bank，就拉 `load_weight_ping`
- 如果当前装的是 pong bank，就拉 `load_weight_pong`

### 权重装入 bank 的选择

`weight_load_bank_sel` 表示当前正在往哪个 bank 装权重：

- `0` -> 装 ping
- `1` -> 装 pong

它在每次一整块权重装完后翻转一次。

## 7.4 计算 bank 的选择

`weight_bank_sel` 表示当前计算阶段使用哪个 bank：

- `0` -> 计算读 ping
- `1` -> 计算读 pong

它在每次一个计算块真正完成后翻转一次。

这两个信号分离的好处是：

- “往哪装” 和 “当前算哪边” 解耦
- 更容易做无缝乒乓切换

## 7.5 激活与有效掩码

当前顶部输入：

- `act_top = rs1_data_i`
- `act_top_valid` 根据 `rs1_data_valid_i` 和 `row_valid_mask` 生成
- `psum_top_valid` 根据 `rs1_data_valid_i` 和 `col_valid_mask` 生成

这里要理解两个掩码：

### `col_valid_mask`

按 `active_n_cols` 生成：

- 哪些列参与本轮输出

### `row_valid_mask`

按 `active_k_rows` 生成：

- 哪些行参与本轮 K 段计算

也就是说：

- `n` 决定有效列数
- `k` 当前块大小决定有效行数

## 7.6 为什么 `C` 不从顶部输入

当前设计已经把“历史 `C`”从阵列顶部拿掉了，改为在尾部累加，原因主要有三点：

1. 阵列内部 psum 链只需要承载 `A * B` 的部分和
2. `K=64` 拆两段时，部分结果写回和最终结果写回更容易区分
3. 尾部统一累加更清晰，读 `rd` 与写 `rd` 的控制也更集中

因此现在的计算流程是：

```text
阵列内部：先算 A * B
阵列尾部：再做 (A * B) + C
```

## 8. 输出路径与尾部累加

这一部分是当前设计里第二个最容易忘的地方。

## 8.1 先读旧值，再与阵列输出相加

`pe_array` 吐出的是每列当前拍的部分和 `psum_bottom`，但最终输出不是它本身，而是：

```text
accum_sum = psum_bottom_ext + rd_data_i
```

其中：

- `psum_bottom_ext`
  - 是把阵列内部较窄的 `PE_ACC_WIDTH` 部分和，符号扩展到 `ACC_WIDTH`
- `rd_data_i`
  - 是从外部读回的历史 `C/psum`

最后由 `accumulaters` 完成逐列相加。

## 8.2 为什么需要 `psum_pre_valid`

阵列底部数据真正有效时，对应信号是 `psum_valid_o`。但这时再去读 `rd` 已经晚了，所以提前导出了：

- `psum_pre_valid_o`
- `psum_pre2_valid_o`

当前 `pe_ctrl` 用 `psum_pre_valid` 做：

- `rd_read_valid_o = psum_pre_valid`

含义是：

- 在阵列输出到达前一拍，先把历史 `rd` 数据读出来
- 等到 `psum_valid` 到达时，就能直接送入尾部累加器

## 8.3 output metadata FIFO

由于当前支持 block 之间无缝衔接，`psum_valid` 可能持续不断，中间没有明显空档，因此不能再依赖边沿判断“新 block 开始”。

当前做法是：

1. act/psum block 每 pop 一次，就往输出 metadata FIFO 里压一条记录
2. 当输入侧送出某个 block 的第一个激活 beat 时，打一发 `output_block_head_in`
3. 经过 `TILE_ROWS` 级移位寄存器延迟后，这个 token 会和输出端的 block 头对齐
4. 用这个对齐后的 token 去 pop output metadata FIFO

这样就能在输出端知道：

- 当前写回属于哪个 `rd`
- 当前块的 `m/n` 是多少
- 当前块是不是命令最后一块

## 8.4 `matmul_finish_o` 的含义

`matmul_finish_o` 不是简单表示“现在有写回”，而是表示：

```text
当前这一拍开始写回的 block，
是否对应一条矩阵乘法命令的最终完成结果
```

例如：

- `k=64` 时会拆成两段
- 第一段写回只是中间结果
- 第二段写回才是最终结果

因此：

- 第一段写回时 `matmul_finish_o = 0`
- 第二段写回时 `matmul_finish_o = 1`

这正是 `act_psum_last_o` 和 output metadata FIFO 里那一位 `last` 的意义。

## 9. `accumulaters`

`accumulaters` 的实现比较直接：

- 每一列实例化一个 `DW01_add`
- 默认共 `32` 路
- 每路位宽默认 `48`

输入：

- `add_pe_i`
  - 阵列底部输出，已经做过符号扩展
- `add_rd_i`
  - 历史 `C/psum`

输出：

- `sum_o`
  - 逐列累加结果
- `carry_o`
  - `DW01_add` 的进位输出

这里要注意：

- `carry_o` 只是加法器进位，不等价于有符号溢出标志
- 当前系统主要使用 `sum_o`

## 10. 命令余额与 busy

当前 `pe_ctrl` 用 `cmd_pending_count` 统计：

- 模块内部还有多少条命令尚未完全执行结束

统计方式：

- 接收一条命令：`+1`
- 当 act/psum block FIFO 弹出的是该命令的最后一块：`-1`

当前最多允许同时挂两条命令，因此：

```text
cmd_busy_o = (cmd_pending_count == 2) || cmd_decode_busy
```

也就是说：

- 命令槽位已满，不能再送新命令
- 或者 `matmul_tiling` 还在展开当前命令，也不要再送新命令

## 11. K=64 时的典型执行过程

当 `m=32, n=32, k=64` 时，当前设计的典型流程如下：

1. `matmul_tiling` 把命令拆成两块
   - weight block 0: `k_rows=32`
   - weight block 1: `k_rows=32`
   - act/psum block 0: `act_base_row=0, last=0`
   - act/psum block 1: `act_base_row=32, last=1`
2. `pe_ctrl` 进入 `LoadWeight`
   - 将第一块权重装入某个 bank
3. 进入 `StreamPreloadWeight`
   - 当前 bank 开始计算第一块
   - 另一 bank 同时预装第二块权重
4. 第一块计算完成后
   - `weight_bank_sel` 翻转
   - 开始用另一 bank 计算第二块
5. 第一块输出写回
   - `matmul_finish_o = 0`
6. 第二块输出写回
   - `matmul_finish_o = 1`

这个流程正是当前“权重乒乓 + 尾部累加 + 最终完成标记”设计的核心。

## 12. 当前设计里最值得记住的几个点

后面复盘时，最容易忘的通常是下面这些：

1. 现在 `C` 不从阵列顶部走了，而是在尾部通过 `accumulaters` 参与累加。
2. `matmul_tiling` 的 FIFO 里存的是“块描述”，不是实际矩阵数据。
3. 权重地址是倒序读的，不是从 0 往上读。
4. `weight_load_bank_sel` 和 `weight_bank_sel` 是两件事。
5. 输出 metadata 不是靠 `psum_valid` 边沿抓的，而是靠一个延迟对齐的 block-head token。
6. `matmul_finish_o` 表示“这一段写回是不是整条命令的最终结果”，不是普通写回 valid。

## 13. 当前不足与后续可改进项

如果后面继续演进，这几个点大概率是下一步：

1. 完整支持 `n > 32`，把 `N` 维也 tile 化。
2. 把外部 `rs1 / rs2 / rd` 访问改成完整 ready/valid 握手。
3. 进一步确认当前 `act_valid / psum_valid` 与阵列拓扑的严格时序关系。
4. 若后续 `TILE_ROWS != TILE_COLS` 真的要支持，需要重新检查掩码和部分位宽写法。
5. 给 `output metadata` 和 `rd` 通路补更系统的时序图。
6. 若要接更大系统，可继续把命令调度、DMA、PE 控制之间的接口契约文档化。

## 14. 一句话总结

当前这一版可以把它理解成：

> `matmul_tiling` 负责把命令拆成块，`pe_ctrl` 负责按块驱动 WS 脉动阵列，`pe_array/pe_ws` 负责完成 `A*B`，`accumulaters` 在阵列尾部完成 `C + A*B`，并通过 metadata 机制区分“中间块写回”和“最终结果写回”。
