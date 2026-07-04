# Coral AXI SiLU Service Spec

## 1. 目标

本文档定义一种基于 Coral 现有 AXI 接口的 SiLU 服务化执行方案。

目标形态不是：

- 外部主控直接向 Coral 注入一条临时 RISC-V 指令

而是：

- 在 Coral 的 ITCM 中常驻一段固定的 `SiLU service` 程序
- 外部主控通过 AXI 写入任务描述符与 doorbell
- Coral 被触发后，自行从指定地址取数、执行 SiLU、写回结果
- 任务完成后，Coral 通过共享状态区和可选的外部 MMIO 写回通知主控

本文档优先描述当前最小可落地版本：

- 不修改 Coral RTL
- 不新增专用 CSR
- 不新增专用 SiLU 硬件单元
- 仅依赖现有 `s_axi`、`m_axi`、ITCM、DTCM 与软件常驻程序

## 2. 设计结论

### 2.1 当前结论

当前 Coral 现有硬件已经足以支持这条服务路径：

- 外部主控可通过 `s_axi` 写 Coral 的 `ITCM / DTCM / CSR`
- Coral 内核可通过 `m_axi` 主动访问外部 memory / peripheral
- Coral 程序可常驻在 ITCM 内循环等待任务

因此，最小版本的 AXI 驱动 SiLU 服务：

- **不需要修改硬件**
- **只需要新增常驻软件协议与服务程序**

### 2.2 当前不做的事情

当前版本明确不做：

- 向 Coral 动态注入“单条临时指令”
- 为 SiLU 新增专用 opcode
- 新增专用 SiLU RTL datapath
- 新增独立 DMA 引擎
- 中断驱动的自动 doorbell 拉起逻辑
- 多任务乱序执行
- cache coherence 协议扩展

## 3. 总体结构

系统中的角色划分如下：

- 外部主控
  - 通过 `s_axi` 写 Coral 的 ITCM、DTCM、CSR
  - 负责下发 SiLU 任务
- Coral 常驻程序
  - 常驻在 ITCM
  - 轮询或等待 doorbell
  - 执行取数、计算、写回、状态更新
- Coral `m_axi`
  - 作为 Coral 发起的主口
  - 用于访问外部数据区和外部 MMIO 通知寄存器

可抽象为：

```text
Host AXI master --s_axi--> Coral { ITCM / DTCM / CSR }
Coral SiLU service --m_axi--> External DDR / SRAM / MMIO
```

## 4. 执行模型

### 4.1 常驻程序模型

Coral 上运行的不是“一次执行后退出”的普通 demo，而是常驻服务程序。

其基本控制流如下：

```text
boot
  -> 初始化 service 上下文
  -> 进入常驻循环
       -> 检查 doorbell
       -> 若无任务，则继续等待
       -> 若有任务，则读取 descriptor
       -> 执行 SiLU
       -> 更新状态
       -> 可选写回外部 notify 寄存器
       -> 返回等待态
```

### 4.2 当前推荐等待方式

当前最小版本推荐采用：

- DTCM mailbox 轮询

即：

- 主控写 DTCM 中的 command / descriptor
- Coral 软件循环检查该区域是否有新任务

这样做的原因是：

- 完全不需要改硬件
- 不依赖外部 `irq` 接线是否已经打通
- bring-up 最简单

后续若需要进一步降低空转功耗，可升级为：

- `wfi + irq` 唤醒

但这不属于当前最小版本必须项。

## 5. 内存与控制平面划分

当前方案中，控制平面和数据平面分离。

### 5.1 控制平面

控制平面通过 `s_axi` 完成，主要用于：

- 首次写入 `SiLU service` 程序到 ITCM
- 写 descriptor 到 DTCM mailbox
- 写 doorbell 启动任务
- 读取状态与错误码

### 5.2 数据平面

数据平面通过 Coral 发起的 `m_axi` 完成，主要用于：

- 从外部源地址读取输入数据
- 将输出结果写回外部目标地址
- 可选写外部 completion 寄存器

因此：

- 外部主控不必先把整块输入数据搬进 DTCM
- Coral 可直接对系统内存中的源数据做 SiLU

## 6. 启动流程

### 6.1 首次启动

首次启动服务时，主控执行如下步骤：

1. 通过 `s_axi` 将 `silu_service.elf` 写入 Coral ITCM
2. 配置 Coral 的 `PC_START`
3. 释放 Coral reset / clock gate
4. 让 Coral 开始执行常驻服务程序

完成上述步骤后，Coral 不应退出，而应停留在服务循环内。

### 6.2 后续任务下发

后续每次任务下发时，主控仅需：

1. 准备输入数据所在的外部地址
2. 向 DTCM mailbox 写 descriptor
3. 写 doorbell
4. 轮询状态或等待通知

即：

- 程序只装载一次
- 后续每次任务不再重新加载程序

## 7. Mailbox 布局

当前推荐在 DTCM 中预留一块固定 mailbox 区域，供主控与 Coral 常驻程序共享。

当前版本推荐 mailbox 至少包含以下信息：

```c
struct SiluDesc {
  uint32_t src_addr;
  uint32_t dst_addr;
  uint32_t elem_count;
  uint32_t flags;
  uint32_t notify_addr;
  uint32_t notify_value;
};

struct SiluMailbox {
  volatile uint32_t doorbell;
  volatile uint32_t status;
  volatile uint32_t done_count;
  volatile uint32_t error_code;
  volatile struct SiluDesc desc[4];
};
```

说明：

- `doorbell`
  - 主控写入，触发 Coral 接收新任务
- `status`
  - Coral 写入，表示当前 service 状态
- `done_count`
  - Coral 每完成一个任务加一
- `error_code`
  - Coral 在失败时记录错误码
- `desc[]`
  - 描述具体任务参数

### 7.1 为什么 doorbell 与 descriptor 分离

不建议把所有任务信息都挤进一个 `32 bit` 指令字，原因很直接：

- 仅 `src_addr + dst_addr` 就至少需要 `64 bit`
- 还需要 `elem_count`、格式信息和可选通知地址

因此当前方案固定为：

- `descriptor` 存放完整任务参数
- `doorbell` 只负责“通知开始执行哪个 descriptor”

## 8. Doorbell 语义

当前推荐 `doorbell` 使用如下 32 位格式：

```text
bit[0]      start
bit[3:1]    opcode
bit[7:4]    slot_id
bit[15:8]   reserved
bit[31:16]  seq
```

字段说明：

- `start`
  - 置 `1` 表示提交一个新任务
- `opcode`
  - 指定服务类型
  - 当前版本仅定义 `SiLU`
- `slot_id`
  - 指定使用 `desc[slot_id]`
- `seq`
  - 由主控填写的序号，用于软件侧做新旧任务区分

当前版本建议：

- `opcode = 1` 表示 `SiLU_Q6_10`

未定义的 `opcode` 应返回错误。

当前建议 doorbell 的清除语义为：

- 主控负责写入 `start = 1`
- Coral 在成功接收并锁存该任务后清零 `start`

这样可以避免：

- 主控重复提交同一任务时与 Coral 轮询逻辑产生歧义
- 软件侧无法判断任务是否已被 service 接收

## 9. Descriptor 语义

### 9.1 `src_addr`

- 输入向量起始地址
- 由 Coral 通过 `m_axi` 读取

### 9.2 `dst_addr`

- 输出向量起始地址
- 由 Coral 通过 `m_axi` 写回

### 9.3 `elem_count`

- 以“元素个数”为单位
- 不是字节数

当前 SiLU service 推荐先固定支持：

- `int16 Q6.10`

因此字节数计算为：

```text
byte_count = elem_count * 2
```

### 9.4 `flags`

`flags` 用于描述任务格式与控制选项。

当前最小版本可先只约定：

- 数据类型
- 是否允许原地覆盖

例如：

```text
bit[3:0]   dtype
bit[4]     in_place
bit[31:5]  reserved
```

### 9.5 `notify_addr`

- 当 `notify_addr == 0` 时，不做外部 MMIO 通知
- 当 `notify_addr != 0` 时，任务完成后 Coral 需通过 `m_axi` 对该地址发起一次 `32 bit` 写事务

### 9.6 `notify_value`

- Coral 在任务成功完成后写入 `notify_addr` 的值

可选地，也可约定：

- 成功写 `notify_value`
- 失败写特殊错误值

但当前最小版本建议先不在这里复用复杂编码，而是把失败原因仍放在 mailbox `status / error_code` 中。

## 10. 状态机语义

当前推荐 software-visible service 状态如下：

```text
Idle
Busy
Done
Error
```

可编码到 `status` 中：

```text
bit[0]  busy
bit[1]  done
bit[2]  error
```

基本语义如下：

- `busy = 1`
  - 当前正在执行任务
- `done = 1`
  - 最近一次任务已完成
- `error = 1`
  - 最近一次任务执行失败

推荐约定：

- 新任务开始时，Coral 先清 `done/error`
- 任务成功结束时，Coral 置 `done`
- 任务失败结束时，Coral 置 `error`

## 11. Coral 侧执行流程

对一个 `SiLU` 任务，Coral 侧执行流程建议固定为：

1. 读取 `doorbell`
2. 检查 `start`、`opcode` 与 `slot_id`
3. 读取对应 `descriptor`
4. 检查参数合法性
5. 置 `status.busy = 1`
6. 通过 `m_axi` 从 `src_addr` 逐块读取输入
7. 调用 RVV SiLU kernel 执行计算
8. 通过 `m_axi` 将结果写回 `dst_addr`
9. 更新 `done_count`
10. 更新 `status`
11. 若 `notify_addr != 0`，执行外部 completion write
12. 返回等待态

## 12. RVV SiLU 执行粒度

当前 SiLU kernel 对应定点实现见：

- [silu_piecewise_quadratic_spec.md](/home/wjj/2-NPU/doc/silu_piecewise_quadratic_spec.md)

当前约束下：

- 输入格式：`int16 Q6.10`
- 当前 Coral `VLEN = 128`
- `SEW = 16`
- widening multiply 路径限制输入向量组最大到 `e16,m4`

因此：

- 单次完整 RVV 迭代最多处理 `32` 个元素

service 程序应按 chunk 方式循环处理整个向量：

```text
while (remaining > 0) {
  vl = min(remaining, 32)
  load vl elements
  run RVV SiLU
  store vl elements
  advance pointers
}
```

## 13. 完成通知机制

当前方案推荐支持两种完成通知方式。

### 13.1 共享状态区通知

这是当前最基础、最稳妥的通知方式。

Coral 在任务结束后更新：

- `status`
- `done_count`
- `error_code`

外部主控通过 `s_axi` 读取 mailbox 完成轮询判断。

优点：

- 最简单
- 不依赖外部 MMIO 侧带逻辑
- 是最终真值来源

### 13.2 外部 MMIO 通知

若 `descriptor.notify_addr != 0`，则 Coral 在任务完成后，可通过 `m_axi` 向外部指定地址发起一次 `32 bit` 写事务：

```c
*(volatile uint32_t *)notify_addr = notify_value;
```

这条写事务可用于：

- doorbell
- completion register
- interrupt controller
- host-side mailbox

### 13.3 当前推荐语义

当前建议将两者区分为：

- mailbox 状态区：最终状态依据
- 外部 MMIO 写：快速通知手段

因此：

- 外部系统不应只依赖 `notify_addr` 写事务来判断结果正确性
- 最终状态应以 mailbox 中的 `status / done_count / error_code` 为准

## 14. Coral 是否可以写外部 32 位寄存器

可以。

当前 Coral 现有结构已经支持：

- 程序中的普通 load/store 访问 external / peripheral 地址
- LSU 将这些访问导向 `ebus`
- `ebus` 经 `DBus2Axi` 转成 `m_axi` 读写事务

因此，对外部主控预留的 `32 bit` 完成寄存器，例如：

```text
HOST_DONE_REG = 0x50000000
```

Coral 程序可以直接执行：

```c
*(volatile uint32_t *)HOST_DONE_REG = value;
```

前提是：

- 该地址在 Coral 的 `m_axi` 可达范围内
- 外部从设备支持该地址上的 `32 bit` 写访问

## 15. 主控侧使用流程

### 15.1 初始化阶段

主控：

1. 将 `SiLU service` 装入 ITCM
2. 配置 `PC_START`
3. 释放 Coral reset / clock gate
4. 等 Coral 进入常驻等待态

### 15.2 任务执行阶段

主控：

1. 在系统内存中准备输入数据
2. 填写 mailbox `desc[slot]`
3. 可选清理旧状态
4. 写 `doorbell`
5. 等待完成：
   - 轮询 mailbox
   - 或等待外部通知寄存器变化
6. 读取输出数据

## 16. 内存一致性与顺序要求

虽然当前方案不引入 cache coherence 协议，但软件上仍需满足基本顺序要求。

主控在触发任务前，应保证：

- descriptor 内容已写入目标可见存储
- 输入数据已写入目标可见存储
- doorbell 写发生在上述数据写之后

Coral 在发出完成通知前，应保证：

- 所有输出数据写回已经完成
- mailbox 状态已经更新完成

因此推荐执行顺序为：

1. Coral 写回输出数据
2. Coral 更新 mailbox `status / done_count / error_code`
3. Coral 可选写 `notify_addr`

## 17. 当前推荐最小版本

当前建议第一版先固定为：

- service 常驻在 ITCM
- mailbox 固定放在 DTCM
- doorbell 通过 DTCM 共享字段实现
- Coral 通过轮询方式发现新任务
- SiLU 仅支持 `int16 Q6.10`
- 输入 / 输出均为一维连续向量
- `notify_addr` 作为可选字段保留

也就是：

```text
零 RTL 改动
+ 常驻程序
+ DTCM mailbox
+ m_axi 访存
+ 可选外部 MMIO 完成通知
```

## 18. 后续可扩展方向

当前方案后续可逐步扩展为：

- `wfi + irq` 唤醒，而非轮询
- mailbox 从 DTCM 挪到正式 CSR / peripheral block
- 一个 service 支持多个 opcode
  - `SiLU`
  - `ReLU`
  - `Add`
  - `Mul`
  - `LayerNorm`
- 支持二维 stride 数据块
- 支持任务队列深度扩展
- 支持更复杂的完成中断协议

当前阶段的核心原则是：

```text
先用现有 Coral AXI 能力把服务机制跑通，
再决定哪些部分需要固化成正式硬件接口。
```
