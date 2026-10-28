# 500MHz、读写共享 32 GB/s DRAMsim3 GEMM 波形分析

本文记录共享 DDR 通道的历史实验。2026-10-21 确认的设计要求是 C 写回
同时进行时，读侧仍能持续获得 32GB/s；本文配置的 32GB/s 是读写共享
物理峰值，不满足该保证。因此本文用于解释该配置下的行为，不能直接作为
满足设计带宽目标时的性能结论。模型区别及后续方案见
[设计目标与现有模型的区别](matrix_dramsim3.md#设计目标与现有模型的区别)。

## 结果和测量范围

波形基线目录为 `/tmp/coral_dram_500mhz_wave`，矩阵尺寸为
`{M,K,N}={512,128,512}`，使用 `CORAL_DDR4_32GBps.ini`。其 DMA 读
outstanding 深度为 4；输出校验、AXI 握手和内部命令计数相互一致。
随后将读深度单独改为 16（写深度保持 4），在
`/tmp/coral_dram_read16_gemm` 重跑同一个无波形 GEMM，并在
`/tmp/coral_dram_read16_wave` 跑过带波形版本。两个 read16 测试均通过，
周期完全相同，传输字节数和矩阵指令数与基线相同。各次均使用现有 sparse
数据，未额外注入 AXI 周期背压。

| 指标 | 读 outstanding=4 | 读 outstanding=16 |
| --- | ---: | ---: |
| 总执行周期 | 61359 | 59456 |
| 执行时间 | 122.718 us | 118.912 us |
| Logical MACs/cycle | 546.854 | 564.357 |
| AXI 读数据 | 675840 B | 675840 B |
| AXI 写数据 | 1048576 B | 1048576 B |
| 功能校验 | 通过 | 通过 |

读深度从 4 增至 16 后，周期减少 1903（约 3.1%），Logical MACs/cycle
提升约 3.2%。read16 波形已经做完握手、描述符配对和激活输入计数校验，
实际读在途峰值确实达到 16，详细对照见后面的 read16 分析。

以下至 read16 对照小节前的波形和 outstanding 指标来自读深度 4
的基线，不能当作 read16 的队列行为数据。

| 指标 | 实测 |
| --- | ---: |
| 核/AXI 时钟 | 500MHz / 2ns |
| 总执行周期 | 61359 |
| 时间 | 122.718 us |
| Logical MACs/cycle | 546.854 |
| 相对 1024 MAC/cycle | 53.40% |
| AXI 读数据 | 675840 B，10560 beat |
| AXI 写数据 | 1048576 B，16384 beat |
| 端到端合计流量/时间 | 14.052 GB/s |
| 完成 MATMUL | 128 |

14.052 GB/s 是按 AXI 握手字节数除以执行时间得到的平均数，不能直接当作
DDR 总线忙碌时间占比。停止时还有 15 个已得到写回调、但尚未发物理 WRITE
命令的 transaction，符合 DRAMsim3 写缓冲语义，详见接入文档。

## Outstanding 已经工作，读请求窗口不足以充分隐藏当前延迟

从真实握手计算：读 outstanding 为已接收 AR 减去已完成的 RLAST；写
outstanding 为已接收 AW 减去已完成的 B。没有用 beat 数代替 burst 数。

| 指标 | 实测 |
| --- | ---: |
| 读 outstanding 峰值 | 4 burst |
| 写 outstanding 峰值 | 4 burst |
| 读 outstanding 平均值，复位后测量窗口 | 3.120 |
| 读 outstanding=4 的周期数 | 30776 |
| 读 outstanding=3 的周期数 | 19842 |
| AR/R/AW/W/B 的 VALID&&!READY 周期 | 全部为 0 |
| AR 到 R 首拍/末拍的平均延迟 | 18.127 核周期，即 36.254ns |
| AR 到 R 的最大延迟 | 508 核周期 |
| AW 到 B 的平均延迟 | 17.085 核周期 |

Python 模型可接收各 16 个未完成的读/写 burst，而该次基线的 DMA RTL
配置是 4，因此这次不是 Python 只接收单笔、或 Python 地址队列被填满。
`RVALID=0` 时没有数据可返回，属于等待，不会计入 `VALID&&!READY`。
后端队列重试次数 2235，是 beat 向 DRAMsim3 提交时的失败重试次数，不是
AXI 总线停顿拍数，也不能直接加到 PE 空档里。

全部 10560 个读 burst 都是 1 beat；每个只有 64B。写侧则是 4096 个
burst，每个 4 beat，共 256B。因而读侧的 4 项窗口最多覆盖 256B，写侧
的 4 项窗口可以覆盖 1024B，不能仅凭 outstanding 项数相同认为效果相同。

以这次平均端到端读延迟作窗口估算：

```text
4 * 64B / (18.127 * 2ns) = 7.06 GB/s
```

这解释了为什么 DDR 峰值设为 32 GB/s，读侧仍不能持续用满接口。
此值用于解释当前请求窗口，不是修改深度后的固定带宽上限：修改队列深度
会改变 DRAM 排队和平均延迟，必须实际重测。

读 burst 短的直接原因是 A/B 以 K=128 为整行跨度，而每条软件 MATMUL
只取 K=64 的一半：有效行宽 64B，stride=128B，不满足 DMA 连续行合并
条件。读取下一行会跳过 64B，因此当前 DMA 每行发一条单 beat AR。
scale 是另一条独立 LOAD，有自身的行跨度，也不与数据 LOAD 合并。

## PE 空档主要出现在 MATMUL 等待 LOAD 的时候

| 输入时间分类 | 核周期 |
| --- | ---: |
| 启动，含 execute_from 到首个 block | 674 |
| 有效激活输入 | 32768 |
| 首个和末个 block 之间的额外输入空档 | 27604 |
| 最后一行输入后的收尾 | 313 |
| 合计 | 61359 |

512 个内部 block 有 511 次相邻起点间隔：423 次恰好 64 拍，另外 88 次
大于 64 拍。当前已不再像理想 RAM 测试那样全程连续。

复位后共有 28576 拍没有输入激活，其中：

- 25752 拍控制器处于 Idle，2824 拍在单独装 PE 权重。
- 26307 拍 CPU 队头是因寄存器依赖而等待的 MATMUL，约占无输入时间的 92%。
- 这些 MATMUL 的实际 scoreboard 阻塞项是 A/B 数据或 scale 的 LOAD。
- STORE 寄存器依赖直接挡在 CPU 队头且没有输入的时间只有 57 拍。
- 无激活输入且有 AXI 读在途、但 RVALID=0 的时间为 21409 拍。

这些分类存在重叠，不应相加。STORE 仍可能通过 DDR 读写竞争间接延迟
LOAD；57 拍只表示 STORE 直接阻塞顺序发射入口这一种现象。
波形没有发现 ROB 满、矩阵命令入口反压、DMA 命令入口反压或 C bank
边界 bubble 是本次主要空档来源。

一个具体例子：

```text
8422ns 开始：PC=0x274 的 MATMUL 等待
阻塞项：PC=0x25c 数据 LOAD，PC=0x26c scale LOAD，目标为 AB2
该组阻塞项持续 858 拍，其中 638 拍与激活输入空档重叠
8862ns～10246ns：一段 692 拍的连续激活输入空档
10246ns：下一内部 block 开始输入
```

软件寄存器映射中，这条 MATMUL 是偶数 K 阶段的 `A0 * B2 -> C1`。
这里 scoreboard 在正确阻止使用尚未完成装载的 B2；这不是 C 部分和读写
冲突，也不是要求 LOAD 先 ROB 退休才允许计算。

## Read16 波形对照与剩余限制

read16 分析目录为 `/tmp/coral_dram_read16_wave`。128 条 MATMUL 全部
接收和完成，512 对内部 weight/act 描述符配对正确；实际 PE 命令在途
峰值为 2。AXI 五通道均未观察到 `VALID&&!READY`，这不代表 DDR 没有
等待：多数等待表现为 RVALID 尚未拉高。

| 指标 | 读深度 4 | 读深度 16 |
| --- | ---: | ---: |
| 实际读在途峰值，burst | 4 | 16 |
| 实际写在途峰值，burst | 4 | 4 |
| 复位后窗口内平均读在途数 | 3.120 | 10.917 |
| AR 到 R 平均延迟，核周期 | 18.127 | 61.449 |
| AR 到 R 最大延迟，核周期 | 508 | 800 |
| 激活输入有效周期 | 32768 | 32768 |
| 复位后激活输入空档周期 | 28576 | 26673 |
| 首末 block 间额外输入空档 | 27604 | 25618 |
| 无激活输入且 MATMUL 因寄存器依赖等待 | 26307 | 24278 |
| 无激活输入且读在途、RVALID=0 | 21409 | 20342 |
| 511 次相邻 block 起点中恰好间隔 64 拍 | 423 | 425 |
| AXI 合计流量/端到端时间，GB/s | 14.052 | 14.502 |

read16 的读在途数为 15 或 16 的时间共 35922 拍，占复位后测量窗口
59441 拍的 60.4%。窗口确实被使用，但更多请求在后端排队，平均延迟
增至 122.898ns；不能用深度增大四倍推导带宽也增大四倍。DDR 共享
读写带宽、bank group 时序和按序响应均未因扩大队列而消失。

read16 总周期可分为：首个 block 前 642 拍、有效激活输入 32768 拍、
内部额外空档 25618 拍、最后一行输入后收尾 428 拍，合计 59456 拍。
激活输入空档不是所有 PE 都完全空闲的同义词。空档中的 MATMUL 阻塞
来源仍为 A/B 数据或 scale LOAD；未观察到 ROB 满或矩阵命令入口反压
成为这些空档的主因。

### DDR 地址映射集中到单个 bank

当前配置 `address_mapping=rochrababgco` 将列放在低位。按 DRAMsim3
地址解码，先去掉 64B transaction 的 6 位 byte offset，再使用
`log2(1024)-log2(BL8)=7` 位选择列，所以同一个 8KiB 地址区域共享
rank、bank、bank group 和 row。

输入数据 LOAD 的 64 行地址为 `base + row*128`，每行读 64B。
本用例 tile 基地址对齐或在该区域内偏移 64B，64 行均处于同一个
8KiB 区域，因此同一 tile 没有展开到多个 DRAM bank 并行读取。
10559 对相邻读请求中有 10240 对仍在同一个 8KiB 区域；这些响应间隔
中，7582 次为 3 个核周期，2507 次为 2 个核周期。

配置的 `tCCD_L=11` 个 DDR tick，即 5.5ns，而 `tCCD_S=4` 才是 2ns。
同 bank group 连续列读受到前者约束，64B/5.5ns 约为 11.64GB/s，
即使全部 row hit，也不能按每 2ns 读 64B 估算这段访问。观测到的
2～3 核周期响应间隔与此相符；按序返回和其他后端等待也会影响响应
间隔，不能把全部 PE 空档都归因于这一项。这是 DDR bank 映射，
与 PE 权重 ping/pong bank 或 C Reg bank 冲突不同。

### 多行在途不等于多条 LOAD 并行

`MatrixDmaLoad.sv` 的 `issue_cmd_pop` 要求 `!issue_cmd_active`、
`!recv_cmd_active`、`!read_busy` 且 inflight FIFO 为空。该设计允许
同一条 LOAD 的多行 burst 在途，但上一条 LOAD 接收排空后才启动
下一条，包含数据 LOAD 到 scale LOAD 的切换。这是现有错误恢复边界，
不是等待上一条 LOAD 在 CPU ROB 退休。

read16 的具体例子：A 数据 LOAD 在 598ns 被 DMA 接收，直到 990ns
完成；A scale LOAD 已在 606ns 接收排队，但在 A 数据结束后才执行，
到 1040ns 完成。B 数据/scale 也已排队，分别到 1430ns/1466ns 完成，
随后第一条 MATMUL 才能进入 PE。增大单条 LOAD 的行请求窗口没有消除
这层命令间串行关系。

## 后续实验建议

用户确认后，`MatrixDma.sv` 实例化读模块的 `READ_OUTSTANDING_DEPTH`
从 4 改为 16，写侧仍为 4。read16 无波形 GEMM 已通过并带来约 3.2%
的 MAC/cycle 提升。带波形结果已确认实际用到 16 笔窗口。随后完成了
DDR 地址映射的单变量对照，将 bank group 交织到更低位，保持读深度 16、
写深度 4、时序参数、ELF 和输入数据不变。
这只涉及仿真内存配置；它表示评估不同内存控制器映射，不表示真实硬件
可以任意更改其地址映射，也不能将对照结果直接冒充当前配置的性能。

对照配置为 `tests/cocotb/CORAL_DDR4_32GBps_interleaved.ini`，只有
`address_mapping` 从 `rochrababgco` 改为 `rochracobabg`；解析后的
其余配置项全部相同，默认配置也保留。地址的低位字段变为：

```text
byte offset [5:0] -> bank group [7:6] -> bank [9:8] -> column [16:10]
```

例如 tile 基地址为 `0x80000000` 时，前四行 `+0/+128/+256/+384`
对应 `(bg, bank)=(0,0)/(2,0)/(0,1)/(2,1)`。本次输入 stride=128B
只轮换两个 bank group，不是四个全用；连续 64B 则可轮换四个。
相同 bank group 的 tCCD_L、刷新、读写切换等约束仍然有效，因此不预设
该映射能跑满 32GB/s。

无波形 GEMM 已由用户运行并通过完整矩阵功能校验，结果目录为
`/tmp/coral_dram_read16_interleaved_gemm`。复现命令：

```bash
cd /home/wjj/2-NPU/coralnpu
CORAL_DRAMSIM3_CONFIG="$PWD/tests/cocotb/CORAL_DDR4_32GBps_interleaved.ini" \
bash tests/cocotb/run_matrix_dramsim3.sh gemm /tmp/coral_dram_read16_interleaved_gemm
```

| 指标 | read16 原映射 | read16 交织映射 |
| --- | ---: | ---: |
| 总执行周期 | 59456 | 49290 |
| 执行时间 | 118.912 us | 98.580 us |
| Logical MACs/cycle | 564.357 | 680.755 |
| 相对 1024 MAC/cycle | 55.11% | 66.48% |
| AXI 读数据 | 675840 B | 675840 B |
| AXI 写数据 | 1048576 B | 1048576 B |
| AXI 合计流量/端到端时间，GB/s | 14.502 | 17.493 |
| DRAMsim3 提交重试次数 | 4049 | 1487 |
| CPU 已发射未退休 MATMUL 峰值 | 2 | 3 |
| 功能校验 | 通过 | 通过 |

交织映射少用 10166 拍，周期降低约 17.1%，MAC/cycle 提升约 20.6%。
两次均退休 128 条 MATMUL、320 条 LOAD、64 条 STORE C、64 条 MZERO
和 3 条 CONFIG。结果支持当前地址映射是性能限制之一；配置变化同时
影响读写两侧，不能把全部收益单独归因于读 tCCD_L。

DRAMsim3 平均读请求延迟从 239.275 降到 127.313 个 DDR tick，分别
为 119.638ns 和 63.657ns。这是后端请求统计，不能当成 AXI AR 到 R
延迟；CPU 的未退休峰值也不等于 PE 接收未完成命令峰值。交织版现已
完成 VCD 分析，PE 接收未完成峰值也确认是 3，详细计数见下节。

同一交织配置的波形已经由用户生成，性能与无波形版完全相同。复现命令：

```bash
cd /home/wjj/2-NPU/coralnpu
CORAL_DRAMSIM3_CONFIG="$PWD/tests/cocotb/CORAL_DDR4_32GBps_interleaved.ini" \
bash tests/cocotb/run_matrix_dramsim3.sh wave /tmp/coral_dram_read16_interleaved_wave
```

用 `profile_matrix_axi_wave.py` 分析该目录。分析通过了 AXI 请求/响应、
全部 128 条 PE 命令和 512 对内部描述符、激活输入与矩阵维度的一致性
校验。本次只回填分析文档，未修改 RTL、GEMM 调度或默认 DDR 配置。

### 交织版的剩余空档

| 波形指标 | read16 原映射 | read16 交织映射 |
| --- | ---: | ---: |
| 实际读/写在途峰值 | 16 / 4 | 16 / 4 |
| 复位后窗口内平均读在途数 | 10.917 | 9.833 |
| AXI AR 到 R 平均延迟，核周期 | 61.449 | 45.884 |
| AXI AR 到 R 最大延迟，核周期 | 800 | 582 |
| 相邻 R 握手间隔 1 拍的次数 | 0 | 9187 |
| 激活输入有效周期 | 32768 | 32768 |
| 复位后激活输入空档周期 | 26673 | 16507 |
| 无激活输入且 MATMUL 因寄存器依赖等待 | 24278 | 14394 |
| 无激活输入且读在途、RVALID=0 | 20342 | 11906 |
| 511 次相邻 block 起点中恰好间隔 64 拍 | 425 | 440 |
| PE 接收未完成 MATMUL 峰值 | 2 | 3 |

交织版总执行周期可分为：首个 block 前 494 拍、有效激活输入 32768 拍、
内部额外输入空档 15715 拍、最后一行输入后收尾 313 拍，合计 49290 拍。
16507 拍的空档按控制器状态分为 Idle 14227 拍、单独装 PE 权重 2280 拍。
这些是激活输入信号的分类，不能当作每个 PE 的独立运算利用率。

没有发现 ROB 满、scoreboard 容量满、矩阵命令入口反压或 DMA 命令入口
反压成为本轮的主要空档来源。无激活输入时，MATMUL 寄存器依赖等待占
14394/16507，约 87.2%；对应阻塞项仍是 A/B 数据或 scale LOAD。
STORE 因寄存器依赖直接阻塞 CPU 队头且无激活输入的时间是 208 拍，
但这不排除 STORE 与 LOAD 竞争 DDR 后端。

将 DMA 接收事件、第一条 AR 和完成事件对应起来，每个数据 LOAD 有
64 个单 beat 行读，每个 scale LOAD 有 2 个单 beat 行读：

| 命令执行区间指标 | read16 原映射 | read16 交织映射 |
| --- | ---: | ---: |
| 数据 LOAD 数 / scale LOAD 数 | 160 / 160 | 160 / 160 |
| 数据 LOAD 第一条 AR 到命令完成平均周期 | 288.513 | 214.650 |
| scale LOAD 第一条 AR 到命令完成平均周期 | 50.538 | 39.700 |
| 激活空档落在数据 LOAD 执行区间内 | 18174 | 10996 |
| 激活空档落在 scale LOAD 执行区间内 | 6409 | 3679 |

这里的执行区间从第一条 AR 握手开始，到 scoreboard 观察到命令完成
为止，包含 DDR 时序、排队、返回和 DMA 写寄存器收尾，不包含此前命令
排队时间。区间与 PE 空档的重叠不能直接当作可消除的周期数。

交织版剩余 11906 拍“无激活输入且读在途、RVALID=0”中，有 5471 拍
也有写 burst 在途。读写共享后端仍有影响的可能，但波形未记录原生
DRAM 命令与逐笔回调，无法进一步准确拆出写排空、刷新、bank 时序和
按序返回队头等待各占多少；这些类别不能凭重叠直接做因果归因。

一个具体的长空档发生在 7120ns～8354ns，共 617 个核周期：

```text
B2 数据 LOAD: DMA 接收 6700ns，第一条 AR 6706ns，命令完成 7948ns
B2 scale LOAD: DMA 接收 6708ns，第一条 AR 7952ns，命令完成 8282ns
MATMUL PC=0x274: 等待 B2 数据和 scale，直到准备就绪才允许发射
```

scale 虽然早在 6708ns 就进入 DMA 队列，仍要等数据 LOAD 接收完成
后才能开始发 AR。这再次确认了不同 LOAD 命令间的串行边界。该空档
期间共有 60 个写 burst 的在途区间与其相交，但不表示 617 拍全部
由写流量造成。

上述波形采集时，LOAD 之间仍串行执行。后续经方案讨论，已实现
[跨 LOAD 请求流水化](matrix_dma_load_overlap.md)：提前发射下一条命令，
增加 LOAD 尾拍元数据、返回边界保护和按命令排空错误。读 outstanding
保持 16，写侧保持 4。读深度 4/16 的独立 DMA 测试已通过，完整 CPU/GEMM
回归与同配置 DRAMsim3 性能复测待执行。本文各项性能数据仍来自修改前
的波形，不能作为流水化后的测量结果。

不能承诺扩大窗口即可恢复此前 1002 MAC/cycle，DDR 读写竞争、短事务、
按序返回及命令级等待仍可能构成瓶颈。数据预打包为连续 64B 行可作为另一
条实验路径，但会改变输入布局及打包成本，不应与深度实验混在一起。

## 复现分析

无需重新跑仿真：

```bash
cd /home/wjj/2-NPU/coralnpu
python3 tests/cocotb/profile_matrix_axi_wave.py /tmp/coral_dram_500mhz_wave
```

读深度 16 的波形实验命令：

```bash
bash tests/cocotb/run_matrix_dramsim3.sh wave /tmp/coral_dram_read16_wave
```

read16 波形已生成，可使用同一分析器处理：

```bash
python3 tests/cocotb/profile_matrix_axi_wave.py /tmp/coral_dram_read16_wave
```

脚本一次读取 VCD，生成可复用的采样缓存和以下结果：

- `gemm_axi_profile.json`：逐通道握手、在途数、每个 burst 的地址和延迟。
- `gemm_performance_profile.json`：激活输入、空档、CPU 阻塞项及事件。
- `gemm_command_overlap.json`：PE 接收和完成、内部描述符的配对校验。
- `gemm_axi_samples.csv.gz`：后续分析使用的紧凑采样缓存。

脚本的小型合成测试检查两笔请求同时在途、多 beat 不重复计数、通道背压、
错误 RLAST 和缺失响应的检测。
