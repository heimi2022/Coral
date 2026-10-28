# MatrixCore GEMM + DRAMsim3

## 当前报告基线：共享 32GB/s

当前暂停 DRAMsim3 性能优化，报告默认恢复为单通道、读写共享 32GB/s。
运行入口固定 500MHz、512-bit AXI，使用 bundled DRAMsim3 后端和
`CORAL_DDR4_32GBps_interleaved.ini`（`rochracobabg` 地址映射）。
本次选择历史 interleaved 基线，未保留后续 64GB/s bankspread 实验的
`rochrabacobg` 映射；两者不能当作仅带宽不同的对照。不改变 RTL 或 GEMM 调度。

在仓库根目录运行一项无波形测试：

```bash
bash tests/cocotb/run_matrix_dram_bandwidth.sh 32 gemm /tmp/coral_dram_bw32_report
```

脚本默认带宽也已改为 32；显式填写 32 便于复现。成功后自动生成
`/tmp/coral_dram_bw32_report/gemm_report.md`，并保留 `gemm_metrics.json`、
`test.log`、配置文件、后端及配置哈希。报告只接受本次生成的通过功能校验的
指标；失败或没有新指标时不生成本次报告。复测建议使用新的输出目录。

报告的端到端计算利用率定义为 `Logical MACs/cycle / 1024`，参考物理阵列
为 32×32 PE。512×128×512 的逻辑计算量为 33,554,432 MAC；500MHz 下
峰值为 512 GMAC/s。测试使用确定性的 sparse 输入，MAC 数按完整矩阵计。

历史同映射 32GB/s 结果为 **694.522 MAC/cycle、48,313 周期、67.82%**。
这是历史参考值，本次新结果需重跑后以自动报告为准，不预填历史数值。
该报告描述共享 32GB/s 模型，不表示实现了读写并发时读侧独享 32GB/s 的保证。

## 设计目标与现有模型的区别

2026-10-21 确认的架构要求是：**C 写回同时进行时，读侧仍能持续获得
32GB/s 的服务带宽**。512-bit AXI 在 500MHz 下，每拍可返回 64B，正好
对应 32GB/s；W 通道独立，接口写峰值也为 32GB/s，但这不自动构成 DDR
后端的并发带宽保证。

当前脚本使用单个 DRAMsim3 MemorySystem，32/48/64GB/s 配置均表示
**读写共享的物理峰值**。原先将共享 32GB/s 当作上述设计目标的解释有误。
已有结果仍是有效的共享通道实验，不能作为满足设计目标时的 MatrixCore
性能结论。共享 64GB/s 也不保证读侧持续 32GB/s：调度、读写切换、bank
时序和刷新仍会压低实际服务速率。

下一步应增加独立的架构带宽模型：读写分别排队和限速，在有足够读请求、
初始延迟已覆盖且 RREADY 持续有效时，读侧可每 2ns 返回一个 64B beat，
写流量不消耗读侧服务额度。写侧接口上限为 32GB/s，其保证带宽需要另外
定义，不能仅由读侧要求推导。该模型用于检验既定带宽预算下的 NPU 性能；
保留 DRAMsim3 共享通道模型，单独验证实际内存系统能否兑现预算。仅将
读写拆到两个 DRAMsim3 实例虽能去除相互竞争，仍不能保证有效读带宽达到
32GB/s，也不能未经说明将其视作实际 DDR 拓扑。

上述独立带宽保证模型尚未实现；当前报告使用共享通道模型。

500MHz 下 512x128x512 的已通过波形分析见
[读深度 4/16 的瓶颈对照](matrix_dramsim3_500mhz_performance.md)，
包含读深度 4/16 的 546.854/564.357 MAC/cycle，以及 read16 地址交织
配置的 680.755 MAC/cycle，记录 AXI 实际 outstanding、DDR bank
映射和 PE 等待 LOAD 的证据。交织版已通过功能校验和周期级波形分析，
剩余空档主要与数据/scale LOAD 等待重叠。

后续已实现 [跨 LOAD 请求流水化](matrix_dma_load_overlap.md)，独立 DMA
测试已通过；交织配置上的完整 GEMM 复测为 694.522 MAC/cycle、48,313
周期。该结果高于先前 680.755 MAC/cycle，但仍不能单凭总周期判断 DRAM
后端、按序 R 返回等待和 DMA 内部等待各自占比。

## 接法

这条路径复用现有 MatrixCore cocotb 测试，不修改可综合 RTL：

```text
GEMM ELF -> CPU -> MatrixCore DMA -> 512-bit AXI
                                      |
                          Python MatrixMemory 五通道/数据模型
                                      |
                          Dramsim3AxiTiming 有限队列
                                      |
                          ctypes -> dramsim3_c_api.cc
                                      |
                          SIM/dramsim3/lib/libdramsim3.so
```

这里直接调用已有动态库的 MemorySystem。没有实例化目录中的 SV DPI
wrapper，也没有使用其 shadow memory；输入和输出数据仍由原 Python RAM
保存。因此 Verilator 和 VCS 可以共享这套适配方式，当前脚本使用 Verilator。

已有测试不设置 `CORAL_MATRIX_MEMORY_MODEL` 时继续使用原 RAM。
目前只有 multicreg GEMM 测试入口接入可选模型，普通标量/RVV 的外部内存
模型保持原样，并不与矩阵 DMA 共享这个 DDR 通道。

## 时序和带宽

- 默认配置是 `tests/cocotb/CORAL_DDR4_32GBps_interleaved.ini`：单通道、64-bit DDR
  总线、BL=8、tCK=0.5ns，读写共享峰值为 32 GB/s（十进制）。
  这是共享通道对照配置，不满足上述并发读带宽保证，也不代表已选定或
  验证某款 DDR 器件。
- 每个 DRAM transaction 为 64B，恰好对应一个矩阵 AXI beat。
- MatrixCore/AXI 仿真时钟默认 500MHz，周期为 2ns；按整数飞秒累积相位
  推进 DRAM tick。当前 tCK=0.5ns，因此一个 AXI 周期推进四个 DRAM 周期。
- 读请求被接收后，每个 beat 单独提交到 DRAMsim3；得到回调后才能返回 R。
- W 握手后才提交写 transaction，最后一个 beat 的回调完成后才允许 B。
- 读、写共享同一个 DRAMsim3 MemorySystem，模型负责 bank、行、刷新、
  调度以及读写切换的时序。该配置物理峰值为 `8B*2/0.5ns=32GB/s`，
  是读写共享上限。512-bit AXI 在 500MHz 下的单方向接口峰值为 32GB/s；
  读写同时运行时，DDR 侧仍共享同一个 32GB/s 上限。
- AXI 读请求最多缓存 16 个 burst；写侧最多 16 个尚未响应的 burst，
  外加最多 64 个等待提交的写 beat。DRAMsim3 自己还有配置中的有限队列。
  队列满时，逐步通过 R/W 和 AR/AW 通道向 DMA 传递反压。
- 每个 AXI 周期最多尝试提交一个读 beat 和一个写 beat，交替读写优先级。
- DRAM 可以乱序回调，AXI R 和 B 各自按接收顺序返回，保证 ID 和 burst
  对应正确；此处有按序返回造成的队头等待。
- 可选逐读 beat 追踪记录 AR 接收、DRAM 提交、原生回调 tick、回调被
  Python 观察、RVALID 开始和 R 握手时间。报告区分后端等待、回调轮询
  延迟、按序响应/适配器等待和 R 通道反压；“后续 beat 已完成但队首未完成”
  是队首等待的子集，不能与各阶段延迟简单相加为总停顿周期。

512-bit 是 MatrixCore 侧的 AXI 数据宽度，64-bit 是本模型的 DDR 通道
数据宽度，不是将 RTL 的 AXI 改为 64-bit。DDR 的一次 BL8 突发搬运
`8B*8=64B`，正好对应一个 AXI beat。每个突发占用 4 个 DDR 周期，即
2ns；因此持续 32 GB/s 相当于平均每 2ns 传输一个 512-bit AXI beat。
AXI 时钟为 500MHz，一拍恰好 2ns；单方向连续传输时接口峰值与 DDR
共享峰值相等。DDR 时序开销、读写竞争和队列占用通过握手反压体现。

新配置基于已有 DDR4-3200 配置，将最小延迟向上换算到 0.5ns 周期，
保留原本的绝对延迟，例如 CL 从 22 拍变为 28 拍，tRFC 从 560 拍变为
706 拍；刷新间隔向下取整。突发间隔 tCCD_S 保持 BL/2=4 拍以实现目标
峰值，其余约束仍可能降低有效带宽。32 GB/s 是共享峰值，不保证任意
GEMM 的实测带宽达到这个数，也不表示读和写各自同时拥有 32 GB/s。

写回调遵循 DRAMsim3 的写缓冲语义，不保证物理 DDR 写命令已经完成。
测试停止时可能仍有已响应的写操作在内存控制器中排队；本测试测量 CPU
观察到的 GEMM 完成时间，不额外加入内存控制器物理排空时间。

Python 数据存储在 W 握手时更新；它不模拟缓存一致性、跨 master 的内存
仲裁或 DDR 引脚。当前 GEMM 输入和输出地址互不重叠，适合这条时序路径。
若后续增加重叠地址的跨 master 读写，需要单独定义数据可见性规则。

当前适配器要求 64B 后端 transaction，不对其他粒度做隐式拆分或合并。
例如 `ST-1.2x_32B.ini` 会明确报错；512-bit AXI 不代表需要把 DDR 总线也
设为 512 bit。切换配置时应确认 `bus_width / 8 * BL == 64`。

## 写 Drain 调度实验

命令轨迹显示长读等待常与控制器写 drain 重叠，因此新增一个**独立的
DRAMsim3 实验后端**：把每次写 drain 允许排入命令队列的事务数限制为最多
16；写批次后若有读等待，优先排入读事务。它不限制物理 DDR 总线上连续
WRITE 命令的绝对数量，命令队列里已有的写命令和 DDR bank/刷新时序仍会
影响实际读延迟。bundled 库、RTL、32GB/s 配置和 AXI outstanding 都不改。

上游 DRAMsim3 固定在提交 `29817593b3389f1337235d63cac515024ab8fd6e`。
构建脚本在 `/tmp` 下分别生成未修改基线和 write16 实验库，不会覆盖仓库中
预编译的 `libdramsim3.so`：

```bash
bash tests/cocotb/build_dramsim3_write_drain.sh /tmp/coral_dramsim3_write_drain
bash tests/cocotb/run_dramsim3_write_drain_probe.sh /tmp/coral_dramsim3_write_drain
```

第二条命令以独立进程运行 bundled、同提交重建基线、write16 三个确定性
争用测试：先预填 32 个写，再提交 32 个读，同时持续补充写直至共 1024
个写。它检查所有读写完成、比较读延迟，并校验 bundled 与未修改重建版的
命令轨迹完全一致。独立进程是必要的，因为动态加载器会对相同 SONAME 的
库复用已载入实例；在同一进程里先后载入两个版本会造成错误的 A/B 结果。

本次本机探针 bundled 与重建基线完全一致；write16 下 32 个读请求的平均
延迟由 235.98ns 降为 205.19ns，P95 由 268ns 降为 236.5ns（11.75%），
最大值由 274ns 降为 238.5ns。DRAMsim3 为 32 个读和 1024 个写都返回了
事务完成回调；写回调遵循其缓冲语义，不代表 1024 个物理 WRITE 都已发出。
该合成压力结果只验证读写争用时的调度方向，不等于 GEMM 性能提升，也不
代表物理连续 WRITE 批次被硬性限制为 16。

桥接脚本可通过 `CORAL_DRAMSIM3_BACKEND_LIBRARY` 选择外部库，并检查
运行时实际加载路径；默认仍使用 bundled 库。每个结果目录的
`dramsim3_backend.json` 记录库、配置及 SHA256，构建库旁的
`coral_backend_build.json` 记录上游提交和策略。通过快速探针后，才应使用
完全相同的配置分别跑 GEMM 对照：

```bash
CORAL_DRAMSIM3_BACKEND_LIBRARY=/tmp/coral_dramsim3_write_drain/baseline/libdramsim3.so \
CORAL_DRAMSIM3_COMMAND_TRACE=1 \
CORAL_DRAMSIM3_CONFIG="$PWD/tests/cocotb/CORAL_DDR4_32GBps_interleaved.ini" \
bash tests/cocotb/run_matrix_dramsim3.sh gemm /tmp/coral_gemm_dram_baseline

CORAL_DRAMSIM3_BACKEND_LIBRARY=/tmp/coral_dramsim3_write_drain/write16/libdramsim3.so \
CORAL_DRAMSIM3_COMMAND_TRACE=1 \
CORAL_DRAMSIM3_CONFIG="$PWD/tests/cocotb/CORAL_DDR4_32GBps_interleaved.ini" \
bash tests/cocotb/run_matrix_dramsim3.sh gemm /tmp/coral_gemm_dram_write16
```

两次完整 GEMM 都通过功能校验后，再比较 MAC/cycle、读延迟拆解和 DDR
命令画像。bundled 原始结果 694.522 MAC/cycle 应保留为历史参考；公平的
补丁效果对照是“同一上游重建基线”与 write16 实验库。

### 完整 GEMM 对照结论

2026-10-21 的两次完整 GEMM 均通过输出校验；后端元数据确认使用同一
上游提交、相同 DDR 配置，分别加载 baseline 和 write16 库。结果目录为
`/tmp/coral_gemm_dram_baseline` 和 `/tmp/coral_gemm_dram_write16`。

| 指标 | 重建 baseline | write16 |
| --- | ---: | ---: |
| MAC/cycle | 694.522 | 688.564 |
| GEMM 周期 | 48,313 | 48,731 |
| 提交到读完成平均延迟 | 64.957ns | 60.722ns |
| 提交到读完成 P95 | 453.5ns | 347.5ns |
| 提交到读完成最大延迟 | 1,162.5ns | 977ns |
| AXI 队首等待后端周期 | 26,372 | 26,660 |
| 其中后续 beat 已就绪的周期 | 10,327 | 11,009 |
| READ/WRITE 方向切换次数 | 343 | 805 |
| ACTIVATE 命令数 | 853 | 972 |
| PRECHARGE 命令数 | 821 | 940 |
| 读行命中率 | 94.95% | 94.49% |
| 写行命中率 | 98.08% | 97.64% |
| REFRESH 命令数 | 24 | 24 |

方向切换次数按实际 READ/WRITE 命令序列中相邻命令的方向变化计数，忽略
穿插的 ACT/PRE/REF 命令。write16 更频繁地打断写流，方向切换超过两倍，
行命中率也下降；这些结果支持其增加读写交错、行切换开销的解释。但不能
把命令间隔简单求和，或将每次 ACT/PRE 固定折算成 GEMM 空闲周期：bank
操作可重叠，最终影响还取决于关键路径上的 LOAD 和 STORE 完成时刻。

write16 的读请求延迟分布变好，但端到端增加 418 个 AXI 周期（836ns），
MAC/cycle 下降约 0.86%。AXI 队首等待后端增加 288 拍；已有后续 beat 就绪
但队首仍未完成的重叠子集增加 682 拍，不能把两者相加。逐请求平均/P95
改善不等于 GEMM 更快，因为请求等待可以相互重叠，且关键 LOAD 的完成
顺序会改变后续发射和 DDR 访问顺序。

实验结束时 baseline 已发出 16,384 个物理 WRITE，write16 为 16,379 个，
但两者均收到 16,384 个写事务回调并通过输出校验。这符合 DRAMsim3 的
写缓冲回调语义；write16 仍有 5 个物理写未发出，不能将其解释为丢数据，
也不能将 pending=0 当作物理 DDR 已排空。两组使用相同的 CPU 可见完成
口径；若要比较物理排空时间，需要另做统一的 drain 测量。

结论：在共享 32GB/s 对照中不采用 write16 作为默认后端，保留原调度和
694.522 MAC/cycle 历史基线，不继续盲目缩小写批次。关键 LOAD 完成时刻
及 A/B/C 地址对应的 bank/row 冲突仍值得分析，但针对设计目标的性能评价
应先使用符合并发读带宽预算的模型。实验补丁仅保留用于对照。

## DDR 带宽敏感性实验

`run_matrix_dram_bandwidth.sh` 每次只运行一个 32/48/64GB/s 带宽点，固定
使用仓库原生调度库、500MHz MatrixCore/AXI 和 512-bit AXI，不使用 write16。
通道数、bank 数量、地址映射、队列深度、RTL 和软件调度都不修改。
32GB/s 配置逐字复制既有交织基线；48/64GB/s 配置通过生成器写到结果
目录，不覆盖原始配置。

| 指标 | 32GB/s | 48GB/s | 64GB/s |
| --- | ---: | ---: | ---: |
| DDR tCK | 0.5ns | 1/3ns | 0.25ns |
| 64B 突发传输时间 | 2ns | 1.333ns | 1ns |
| CL 绝对时间 | 14ns | 14ns | 14ns |
| tRCD / tRP | 14ns | 14ns | 14ns |
| tRFC | 353ns | 353ns | 353ns |
| tREFI | 7862ns | 7862ns | 7862ns |
| READ 命令到回调 | 16ns | 15.333ns | 15ns |

大部分最小延迟按绝对时间换算、向上取整到新 DDR 周期；刷新间隔向下
取整。`tCCD_S` 和 BL/2 保持周期数，让跨 bank group 的列命令间隔和突发
占用随数据速率缩短；`tCCD_L` 保留原绝对时间。同一 bank group 的有效
吞吐因此仍可能受限。生成的同名 JSON 记录每项参数及取整误差。

这是更高数据速率的架构敏感性实验，**并非严格只改变带宽的理想模型**：
命令时钟也加快，包含突发长度的派生时序会变化；48GB/s 的时钟在 AXI
适配器中取整为整数飞秒，存在不足 1fs 的每 tick 量化误差。参数不代表
已验证的实际 DDR 器件，功耗参数也未针对新速率标定。不能把结果解释为
真实器件的性能/功耗保证。

AXI 单方向峰值始终只有 32GB/s；DDR 共享 64GB/s 主要用于缓解同时读写
的竞争，不会让单个 AXI 读通道达到 64GB/s。

无需 RTL 编译的检查命令：

```bash
bash tests/cocotb/run_matrix_dram_bandwidth.sh 48 selftest /tmp/coral_dram_bw48_selftest
bash tests/cocotb/run_matrix_dram_bandwidth.sh 64 selftest /tmp/coral_dram_bw64_selftest
```

先跑 64GB/s 的 smoke 和完整 GEMM，确认更高带宽是否值得，再补 48GB/s：

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_matrix_dram_bandwidth.sh 64 smoke /tmp/coral_dram_bw64_smoke
bash tests/cocotb/run_matrix_dram_bandwidth.sh 64 gemm /tmp/coral_dram_bw64_gemm
bash tests/cocotb/run_matrix_dram_bandwidth.sh 48 gemm /tmp/coral_dram_bw48_gemm
```

每条命令单独启动一个测试，不固定 Bazel jobs。需要重新测量 32GB/s 时：

```bash
bash tests/cocotb/run_matrix_dram_bandwidth.sh 32 gemm /tmp/coral_dram_bw32_gemm
```

脚本自动开启逐读和原生命令追踪；与 694.522 MAC/cycle 基线比较完整
GEMM 周期、关键读等待、命令统计，不仅看平均/P95。用户已完成完整
48/64GB/s GEMM，报告如下；这些仍是共享带宽实验：

| 共享 DDR 峰值 | MAC/cycle | 相对共享 32GB/s |
| --- | ---: | ---: |
| 32GB/s | 694.522 | 基线 |
| 48GB/s | 734.844 | +5.81% |
| 64GB/s | 752.679 | +8.37% |

增大共享带宽有收益，但上述结果不等同于在 C 写回时保证读侧 32GB/s
的实验，不能据此认定设计所需的读带宽已经满足或不足。

## 64GB/s 下的 LOAD 与 MATMUL 等待关联

2026-10-22 重新运行共享 64GB/s 完整 GEMM，通过数值、AXI 流量和退休
计数检查，复现 752.679 MAC/cycle：44,580 个 MatrixCore 周期，89.160 us。
测量窗口内 AXI 读 675,840 B、写 1,048,576 B，端到端平均分别为
7.580 GB/s 和 11.761 GB/s。这些平均值包含计算及命令间隙，不能据此
判断 DDR 是否在关键访存时段饱和。

原有 gemm 模式没有 VCD，只有 MATMUL 发射时间及逐读追踪，不能直接
确定具体哪条 LOAD 阻止了 MATMUL 发射。本次保持当前软件、RTL 和
64GB/s 配置，已完成以下带波形的关联观测：

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_matrix_dram_bandwidth.sh \
  64 wave /tmp/coral_dram_bw64_dependency_wave
```

该命令只运行一个仿真目标，没有固定 `--jobs=1`。仿真通过后自动分析
当前运行的波形和 DRAM 追踪，新增两个报告：

- `gemm_wave_profile.json`：激活供数空档、CPU 队首停顿、scoreboard
  依赖、DMA 接收事件以及 AXI R 握手。
- `gemm_dram_dependency_profile.json`：逐条 LOAD 的 PC、独立发射编号、
  A/B data 或 scale 类别、物理寄存器、地址、首末 AR、DDR 全部完成、
  末次 R 返回及 scoreboard 释放时间；关联被这些 LOAD 阻塞的 MATMUL。

关联时逐个核对 DMA LOAD 的行地址，并要求所有 R 握手与 DRAM 追踪
具有相同的时间偏移。PC 在循环中重复执行时使用独立发射编号区分，不能
仅按 PC 或寄存器号关联。地址不匹配、时钟不能对齐、完成事件缺失会直接
报错，不输出部分匹配的结论。当前支持行地址 64 B 对齐、每行最多 64 B
的 A/B data 和 scale LOAD，覆盖本次 M512/N512/K128 GEMM。

重点看 `load_blocked_matmul_activation_idle_cycles` 及
`joint_load_phases_during_activation_idle`：前者是 MATMUL 因 LOAD
寄存器依赖而停顿、同时没有激活供数的周期，后者进一步区分 AR 尚未发完、
DDR 尚未全部完成、DDR 已完成但 AXI 尚未返回、R 已返回但 scoreboard
尚未释放等状态。若有多个阻塞 LOAD，同一周期只计一次，并保留共同状态。

这些是观测状态，不是可直接消除的性能损失：激活供数空档不表示所有 PE
都闲置，DDR 尚未全部完成也可能同时存在有序返回等待。提前 LOAD 本身
被 STORE、ROB 或其它指令阻塞的情况还需结合完整队首停顿报告；不能只
统计 MATMUL 的 LOAD 依赖。

### 本次波形结果与瓶颈

`/tmp/coral_dram_bw64_dependency_wave` 的测试、波形检查及 LOAD/DRAM
关联检查均通过；320 条 LOAD、10,560 个读 beat 全部匹配，性能仍为
752.679 MAC/cycle。激活供数为 32,768 拍，复位和启动之后没有激活供数
的周期为 11,797 拍，其中 10,227 拍同时存在 MATMUL 等待 LOAD 依赖，
占这类空档的 86.69%。本次没有观测到 ROB 满或矩阵命令入口反压。

在上述 10,227 拍中，仅 B data 与 B scale 尚未完成的周期为 7,486 拍，
仅 B scale 尚未完成的周期为 2,523 拍；其余 218 拍还包含 A 或 A scale。
按所有阻塞 LOAD 的共同状态进一步划分：

| 状态 | 周期 |
| --- | ---: |
| 至少一条 LOAD 尚未发完 AR | 6,397 |
| 所有 AR 已发完，至少一个 DDR 请求尚未完成 | 3,514 |
| DDR 回调轮询等待 | 29 |
| 所有 DDR 请求已完成，AXI R 尚未全部返回 | 134 |
| R 已全部返回，scoreboard 尚未释放 | 153 |

表中分类互斥，按 AR、DDR 完成、回调、AXI 返回、scoreboard 的顺序
取第一个未完成阶段。它描述当前可见状态，不表示优化相应阶段就能消除
全部这些周期；例如有序返回等待也会发生在 AR 尚未发完时。

进一步直接采样 VCD 中 DMA 的 `meta_fifo_full_w`、ARVALID/ARREADY、
RVALID/RREADY：在上述 6,397 拍中，4,773 拍是读 outstanding 已达 16、
元数据 FIFO 满且没有发 AR；1,485 拍有 AR 握手，其余 139 拍未发 AR。
没有 ARVALID 有效但 ARREADY 拉低的周期。因此主要不是 AXI 地址入口
拒绝请求，而是旧读没有返回，读窗口无法及时腾出位置。

在这些关键周期中，5,235 拍队首读的 DDR 后端尚未完成，其中 3,381 拍
已有后续读在 DDR 完成。这些数字与前表重叠，不能相加。当前 DMA 使用
同一 AXI ID 按序接收，因此后续读必须等待队首，间接使 16 个 outstanding
槽位持续占用，也延迟后续 B data/scale 的 AR。这解释了为什么不能把
前表的 134 拍当作所有有序返回等待的总损失。

一个具体例子是 LOAD 发射编号 403 的 B scale：共两笔 64 B 读，AR
分别在 62,772 ns、62,774 ns 握手，末笔到 63,554.75 ns 才发出原生 DDR
READ，63,569.75 ns 后端完成，63,572 ns 返回 AXI，63,578 ns 释放依赖并
发射 MATMUL。对应 B data 早在 62,826 ns 完成。末笔 scale 从提交到
DDR READ 之间有 205 条 WRITE 命令，没有同 rank 刷新重叠；这是写流量
竞争下的排队实例，不是 scale 数据量本身很大。

### outstanding 深度是否需要增加

进一步复核时，用元数据 FIFO 的 push/pop 重建占用数，并逐一核对
10,560 次 AR 和 R 握手时间。上述 4,773 拍全部满足：存在待发 DMA burst、
元数据 FIFO 满、已经握手但未返回的读请求恰好为 16、没有 AR 发出。
因此确认读窗口发生了实际限流，不只是满标志恰好与停顿重叠。

但是，限流不等于把深度增加到 32 就能消除这些等待。将这 4,773 拍的
队首请求与原生 DDR READ 命令关联，得到以下互斥分类：

| 队首请求状态 | 周期 |
| --- | ---: |
| 尚未发出原生 DDR READ，仍在等待控制器调度及 DRAM 时序允许 | 4,143 |
| READ 已发出，等待数据返回的固定后端延迟 | 488 |
| 后端已完成，AXI R 正在本拍握手 | 93 |
| 后端已完成，仍等待 AXI 返回 | 49 |

所有这些队首请求都属于当前 MATMUL 正在等待的 LOAD，不是无关 LOAD
占住窗口。此外，4,773 拍中的 3,141 拍已经有后续读在 DDR 完成，但队首
尚未完成。此数与前表重叠，说明按序返回使槽位继续被占用，不能另算为
一项可直接消除的损失。连续窗口满且未发 AR 的最长区间为 442 拍。

这支持的结论是：读窗口满确实阻止了后续 AR，但队首关键读的长延迟，
尤其是 DDR READ 发出前的排队，是重要的上游槽位耗尽原因。把 16 改成
32 可以让更多请求提前进入后端，却不保证这些关键读更早完成，也不保证
MATMUL 提前发射；后端调度会随新增请求变化，不能把观察到的满窗口周期
直接当作扩容后的收益。

当前决定保持读 outstanding 为 16，不修改 RTL 或仿真接收上限。先检查
关键读的 DDR 调度等待与写流量、刷新及 bank 状态的关系，再决定是否值得
做深度对照。只有容量对照下的端到端周期、关键 LOAD 完成时间和相同验证
结果，才能确认扩大读窗口的实际收益。若后续实施深度实验，必须同步调整
Python 模型当前为 16 的读请求接收上限，写侧及其它条件保持不变。

本次进一步诊断保存在
`/tmp/coral_dram_bw64_dependency_wave/gemm_read_window_diagnosis.json`。
这是同一份波形和原生 DDR 命令的离线分析，没有重跑或改变仿真时序。

### 用原生 bank 状态进一步区分等待原因

新增 `replay_matrix_dram_state.cc` 和 `profile_matrix_dram_readiness.py`，
离线重放同一份 shared64GB/s 追踪。工具链接当前使用的 DRAMsim3 动态库，
调用其 `ChannelState::GetReadyCommand` 和 `Timing`，不重新实现 DDR 时序公式。
28,824 条实际发出的命令均通过原生时序与 bank 状态核验；在上述 4,143 拍，
查询队首关键读当时的物理可发条件，结果如下。周期单位均为 500MHz AXI/
MatrixCore 的采样周期，不是 DDR tCK。

| 状态或限制 | 周期 |
| --- | ---: |
| 当前打开了其它 row，先前 WRITE 的恢复时序尚不允许 PRECHARGE | 1,786 |
| 目标 row 已打开，但先前 WRITE 的写后读时序尚不允许 READ | 1,253 |
| 刷新后的时序尚不允许 ACTIVATE | 415 |
| PRECHARGE 后尚不允许 ACTIVATE | 213 |
| 先前 READ 的时序尚不允许 READ | 170 |
| ACTIVATE 后尚不允许 READ | 163 |
| ACTIVATE 后尚不允许 PRECHARGE | 20 |
| 先前 ACTIVATE 的时序尚不允许再次 ACTIVATE | 12 |
| 激活窗口限制 | 4 |
| READ 本身已满足物理时序 | 83 |
| 前置 PRECHARGE 已可发，但 READ 还不可发 | 11 |
| 前置 ACTIVATE 已可发，但 READ 还不可发 | 13 |
| 合计 | 4,143 |

其中 3,039 拍（73.35%）的直接物理限制来自先前 WRITE。这比仅观察
“等待期间有写流量”更具体：1,786 拍的目标 B 数据位于 row `0x2000`，
同一个 bank 却仍打开 C 写回所使用的 row `0x2001`～`0x2004`，且写恢复时间
尚未到，不能立即关掉 C 的 row 去读 B。另外 1,253 拍受写后读时序限制。
只有 83 拍（2.00%）属于 READ 本身已经满足物理时序但尚未发出的采样。

这个结果仍然不是扩大 outstanding 的性能预测。更多请求可能让控制器
提前选择其它 bank，也可能加剧队列竞争；只有深度对照才能测出净收益。
当前证据更直接指向 DDR 读写竞争和同 bank 的 row 切换，保持读 16、写 4。
下一步优先评估 B 读取与 C 写回的 bank/row 分布及调度，再决定是否需要
增加读窗口。不要将 3,039 拍全部视为可消除损失。

重放只恢复物理 bank 状态和时序，不恢复控制器 transaction/command queue、
写排空状态或待执行刷新优先级。因此不能把那 83 拍直接归因于某个调度策略。
查询发生在对应 DDR 时钟的命令更新之前，完整明细和该时钟实际发出的命令
保存在 `gemm_dram_readiness_profile.json`。

本机已有与动态库匹配的上游源码时，重复本次离线分析只需：

```bash
bash tests/cocotb/build_dramsim3_state_probe.sh \
  /tmp/coral_dram_state_replay_source /tmp/coral_dram_state_probe
CORAL_DRAM_STATE_PROBE=/tmp/coral_dram_state_probe \
python3 -m unittest discover -s tests/cocotb \
  -p profile_matrix_dram_readiness_test.py -v
python3 tests/cocotb/profile_matrix_dram_readiness.py \
  /tmp/coral_dram_bw64_dependency_wave --probe /tmp/coral_dram_state_probe
```

源码须为未修改的 `umd-memsys/DRAMsim3` commit
`29817593b3389f1337235d63cac515024ab8fd6e`，并与所链接库的配置及 C++ ABI
匹配。源码目录是本次临时下载的位置，不是仓库依赖；换机器时将参数替换为
本机同版本源码路径。分析脚本目前针对保留了配置文件和完整追踪的
shared64GB/s 单通道、单 beat 按序 AXI 读测试。

只重做离线分析、不重新仿真时运行：

```bash
python3 tests/cocotb/profile_matrix_gemm_wave.py \
  /tmp/coral_dram_bw64_dependency_wave/gemm_m512_n512_k128.vcd \
  --metrics /tmp/coral_dram_bw64_dependency_wave/gemm_metrics.json \
  --output /tmp/coral_dram_bw64_dependency_wave/gemm_wave_profile.json
python3 tests/cocotb/profile_matrix_gemm_dram.py \
  --wave-profile /tmp/coral_dram_bw64_dependency_wave/gemm_wave_profile.json \
  --metrics /tmp/coral_dram_bw64_dependency_wave/gemm_metrics.json \
  --reads /tmp/coral_dram_bw64_dependency_wave/dramsim3/axi_read_trace.jsonl \
  --output /tmp/coral_dram_bw64_dependency_wave/gemm_dram_dependency_profile.json
```

### bank 分布与单变量映射对照

`profile_matrix_dram_banks.py` 继续分析同一份 shared64GB/s 基线，不重扫
VCD，也不重新仿真。它将原生 READ/WRITE 的物理地址还原为字节地址，核对
全部 AXI 读地址及 C STORE 覆盖范围，再比较不同映射下的数据分布。

基线中，一块 B tile 是 64 行、每行 64 B、行跨度 128 B；一块 C tile
是 64 行、每行 256 B、行跨度 2,048 B。首次 tile 的分布如下：

| 映射 | B tile 的 bank / bank group 数 | C tile 的 bank / bank group 数 |
| --- | ---: | ---: |
| 基线 `rochracobabg` | 8 / 2 | 4 / 4 |
| 候选 `rochrabacobg` | 2 / 2 | 16 / 4 |
| column 低位对照 `rochrababgco` | 1 / 1 | 16 / 4 |

地址位从低到高，基线为 byte offset `[5:0]`、bank group `[7:6]`、
bank `[9:8]`、column `[16:10]`、rank `[17]`、row `[33:18]`。
候选只将 column 移到 `[14:8]`，bank 移到 `[16:15]`，其它字段不变。
这里的 bank 数将 channel、rank、bank group、bank 合起来区分。

候选让 C 写回分散到更多 bank，同时保留 B 在两个 bank group 间交错。
但它也把 B tile 的 bank 并行度从 8 降为 2；当前采用每 bank 命令队列，
这可能降低可用排队空间。因此它是待测候选，不能仅凭 C 更分散就认定更快。
column 低位映射还会把一块 B 集中到单个 bank group，本次仅作对照。

将基线实际 READ/WRITE 的顺序固定，只重新映射地址，统计同 bank 相邻
数据访问改变 row 的次数，得到：

| 映射 | 全部 row 切换 | WRITE → READ 切换 | C WRITE → B READ 切换 |
| --- | ---: | ---: | ---: |
| 基线 | 662 | 323 | 139 |
| 候选 | 534 | 245 | 137 |
| column 低位对照 | 372 | 156 | 108 |

这不是替代映射的物理执行重放：控制器在新映射下会重新排序命令，刷新和
PRE/ACT 时序也会影响结果。表中次数不是预测的 ACT/PRE 数或节省周期，
尤其 C → B 次数仅从 139 降到 137，不能宣称已消除关键 B 冲突。
此前确认的 1,786 拍 C 写恢复限制是采样周期数，与这里的切换次数不能混算。

生成离线报告和候选配置：

```bash
python3 tests/cocotb/profile_matrix_dram_banks.py \
  /tmp/coral_dram_bw64_dependency_wave
```

输出为该目录下的 `gemm_dram_bank_profile.json` 和
`CORAL_DDR4_64GBps_bankspread.ini`。生成器验证新旧配置只有
`system.address_mapping` 不同；带宽、时序、容量和队列设置均保持不变。
地址往返解码、bank 分布及配置隔离的 5 项检查已通过，候选的原生 DRAM
自检也通过。

完整对照使用通用脚本，以免带宽脚本重新生成基线配置覆盖选择：

```bash
cd /home/wjj/2-NPU/coralnpu
CORAL_DRAMSIM3_CONFIG=/tmp/coral_dram_bw64_dependency_wave/CORAL_DDR4_64GBps_bankspread.ini \
CORAL_DRAMSIM3_BACKEND_LIBRARY="$PWD/hdl/verilog/SIM/dramsim3/lib/libdramsim3.so" \
CORAL_GEMM_CLOCK_NS=2.0 \
CORAL_DRAMSIM3_COMMAND_TRACE=1 \
bash tests/cocotb/run_matrix_dramsim3.sh gemm /tmp/coral_dram_bw64_bankspread_gemm
```

单变量 GEMM 对照已完成。两次测试都是 M/N/K=512/512/128、500MHz、
共享 64GB/s、相同 DRAMsim3 动态库；实际配置仅 `address_mapping` 不同。
两次均 PASS，AXI 读写 beat 数分别保持 10,560 和 16,384，且都验证了
全部输出数据。RTL、读 outstanding 16、写 outstanding 4、矩阵布局及软件
调度均未改变。

| 指标 | 基线 | 候选 |
| --- | ---: | ---: |
| GEMM 执行周期 | 44,580 | 41,478 |
| Logical MACs/cycle | 752.679 | 808.969 |
| AXI AR→R 平均 / P95 | 78.82 / 322 ns | 63.60 / 268 ns |
| AXI 队首等待后端的周期 | 23,370 | 19,430 |
| 队首等待且后续 beat 已就绪的周期 | 13,340 | 4,134 |
| 原生 DDR ACT / PRE 命令 | 949 / 917 | 699 / 683 |

候选减少 3,102 周期（6.96%），吞吐提高 7.48%；ACT 和 PRE 分别减少
250 和 234 条。AXI 队首等待计数下降，但它们与计算重叠，不可当作可直接
相加的性能损失。单笔读从 DRAMsim3 提交到原生 READ 发出的平均等待却由
31.56 ns 增至 43.00 ns，`submit_to_issue` P95 由 178 ns 增至 215 ns；
因此不能声称所有单笔读或每个 row conflict 都变快。整体收益是已实测事实，
其详细调度因果尚未完全分离。特别是固定访问次序的 C WRITE→B READ row
切换只从 139 降至 137，不能单独解释全部收益。

在这个 M/N/K 和当前 DRAM 模型下，候选映射通过功能与性能对照，可作为
后续实验的优选映射；不要据此推断所有工作负载都会变快。它收窄 B tile
bank 分布的代价仍然存在。更换矩阵尺寸、stride、读写比例或 DRAM 控制器
策略时应重新测量；不需要仅为这次映射实验修改 RTL 或 outstanding。

### 是否继续扩大读 outstanding

bankspread GEMM 的 AXI trace 仍观测到 16 笔读请求同时 outstanding；逐周期
监测得到窗口满 5,366 拍。但这 5,366 拍全部没有 ARVALID，也就是窗口虽满，
RTL 当时并没有请求接受新的读事务。这里没有“ARVALID 被 READY 阻塞”的周期，
因此本次证据不支持把读 outstanding 从 16 增至 32；增大深度不会让不存在的
AR 请求提前发出。

逐笔 trace 现在会在每个 AXI 周期额外记录窗口满、窗口满时 ARVALID、
ARVALID 且未握手，以及满窗口但无 ARVALID 的计数。重新跑候选 GEMM 时
启用 `CORAL_DRAMSIM3_TRACE=1`，runner 会汇总这些分类。只有满窗口期间
持续存在被阻塞的 ARVALID，且该阻塞覆盖 MATMUL 等待 LOAD 的激活空闲周期，
才有依据做读 outstanding 16→32 的单变量对照。此测量不产生 VCD，也不改 RTL。

为重新采集候选映射计数，运行：

```bash
cd /home/wjj/2-NPU/coralnpu
CORAL_DRAMSIM3_CONFIG=/tmp/coral_dram_bw64_dependency_wave/CORAL_DDR4_64GBps_bankspread.ini \
CORAL_DRAMSIM3_BACKEND_LIBRARY="$PWD/hdl/verilog/SIM/dramsim3/lib/libdramsim3.so" \
CORAL_GEMM_CLOCK_NS=2.0 \
CORAL_DRAMSIM3_TRACE=1 \
CORAL_DRAMSIM3_COMMAND_TRACE=1 \
bash tests/cocotb/run_matrix_dramsim3.sh gemm \
  /tmp/coral_dram_bw64_bankspread_read_window
```

重点看 `Read window capacity cycles` 的 `full_with_ar_blocked` 与
`full_without_ar_valid`。本次分别为 0 和 5,366，表明接下来应追查软件/标量
发射序列、DMA LOAD 产生节奏或 MatrixCore 对新 LOAD 的需求，而非扩大读窗口。
这只是“窗口满期间没有新 AR”的证据，不证明软件一定是唯一瓶颈；下一步需
用 MATMUL 等待 LOAD 的区间与 LOAD/AR 发射时间对齐，定位是谁没有及时提出
下一笔请求。只有新数据出现持续 ARVALID 被阻塞，才值得安排 16→32 对照。

下一步需要把窗口计数与 CPU head、LOAD dispatch/完成以及 PE activation-feed
空闲区间对齐。使用同一候选配置运行 wave 模式会同时生成 DRAM trace、VCD，
并自动输出 `gemm_dram_dependency_profile.json`。VCD 较大，确保输出磁盘有
足够空间；不要并行运行其它大型仿真：

```bash
cd /home/wjj/2-NPU/coralnpu
CORAL_DRAMSIM3_CONFIG=/tmp/coral_dram_bw64_dependency_wave/CORAL_DDR4_64GBps_bankspread.ini \
CORAL_DRAMSIM3_BACKEND_LIBRARY="$PWD/hdl/verilog/SIM/dramsim3/lib/libdramsim3.so" \
CORAL_GEMM_CLOCK_NS=2.0 \
CORAL_DRAMSIM3_TRACE=1 \
CORAL_DRAMSIM3_COMMAND_TRACE=1 \
bash tests/cocotb/run_matrix_dramsim3.sh wave \
  /tmp/coral_dram_bw64_bankspread_wave
```

分析 `gemm_dram_dependency_profile.json` 中 activation idle 时的 LOAD phase，
以及 `gemm_wave_profile.json` 中对应 CPU head blocker。若窗口满且无 ARVALID
发生在 CPU 仍执行标量准备/前序 STORE，优先调整软件调度；若 CPU 已发出 LOAD
但 LOAD 未发出 AR，则追 DMA 内部排队/启动条件。两类都不是把 outstanding
直接增到 32 的理由。

随后使用同一候选配置完成了三个功能验证，均 PASS，且均为 500MHz、
共享 64GB/s、相同 DRAMsim3 后端：

| 用例 | 结果 | 输出校验 | 产物目录 |
| --- | --- | --- | --- |
| multicreg GEMM smoke，M/N/K=64/256/64 | PASS | 65,536 B | `/tmp/coral_dram_bw64_bankspread_smoke` |
| 边界 GEMM，M/N/K=65/257/128 | PASS | 66,820 B | `/tmp/coral_dram_bw64_bankspread_boundary` |
| 同一边界 GEMM + AXI backpressure | PASS | 66,820 B | `/tmp/coral_dram_bw64_bankspread_backpressure` |

三份 `dramsim3_backend.json` 记录了相同候选配置及 SHA-256；背压用例
确实覆盖了 `stalled=true`，仍完成全部输出校验。到此，候选映射有一个
完整性能结果及 smoke、尾块、背压功能验证。当前只应将它用于显式选择的
64GB/s 仿真对照；未改变现有默认配置和 32GB/s 模型，避免把单一 512 方阵
的性能结论外推到所有测试或内存系统。

下一项泛化检查使用 M/N/K=256/512/128：N 方向仍覆盖完整 512 列，M
方向改为一半，以验证相同 B/C bank 布局在不同 M 分块数量下是否仍有收益。
测试作为独立的大用例，不会扩展常规参数化 GEMM 回归集合：

```bash
cd /home/wjj/2-NPU/coralnpu
CORAL_DRAMSIM3_CONFIG=/tmp/coral_dram_bw64_dependency_wave/CORAL_DDR4_64GBps_bankspread.ini \
CORAL_DRAMSIM3_BACKEND_LIBRARY="$PWD/hdl/verilog/SIM/dramsim3/lib/libdramsim3.so" \
CORAL_GEMM_CLOCK_NS=2.0 \
bash tests/cocotb/run_matrix_dramsim3.sh gemm-rect \
  /tmp/coral_dram_bw64_bankspread_gemm_256x512
```

此形状的候选与基线 A/B 对照尚未完成；应先确认候选 PASS 和指标，再用
相同形状、只替换回 `CORAL_DDR4_64GBps_interleaved.ini` 跑基线。不要仅因
方阵和尾块测试通过，就将候选映射设为全局默认。

## 运行

从仓库运行，每次只执行一个目标。脚本编译很小的桥接动态库，并将其路径
传给 Bazel 本地 TestRunner；输出目录可自选。没有固定设置 `--jobs=1`。

先做无需 RTL 的快速自检：

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_matrix_dramsim3.sh selftest /tmp/coral_dram_selftest
```

然后验证 64x256x64 的四 C Reg GEMM，尺寸顺序为 M/N/K：

```bash
bash tests/cocotb/run_matrix_dramsim3.sh smoke /tmp/coral_dram_smoke
```

通过后，依次运行 M/N/K=65/257/128 边界与额外 AXI 背压用例：

```bash
bash tests/cocotb/run_matrix_dramsim3.sh boundary /tmp/coral_dram_boundary
```

```bash
bash tests/cocotb/run_matrix_dramsim3.sh backpressure /tmp/coral_dram_backpressure
```

最后运行 M/N/K=512/512/128，与此前 RAM 下的 1002.223 MAC/cycle 对比。
此前记录来自 1.25ns 时钟、理想 AXI RAM；新结果使用 2ns 时钟、真实
DRAM 时序，须同时查看周期数、时钟与带宽，不能把旧结果当作已验证的
500MHz DDR 性能：

```bash
bash tests/cocotb/run_matrix_dramsim3.sh gemm /tmp/coral_dram_gemm
```

需要诊断 694 MAC/cycle 的内存读路径时，可在同一完整 GEMM 上启用逐笔
追踪。追踪文件远小于 VCD，且不需要波形目标：

```bash
CORAL_DRAMSIM3_TRACE=1 \
CORAL_DRAMSIM3_CONFIG="$PWD/tests/cocotb/CORAL_DDR4_32GBps_interleaved.ini" \
bash tests/cocotb/run_matrix_dramsim3.sh gemm /tmp/coral_dram_load_trace
```

脚本会生成 `dramsim3/axi_read_trace.jsonl` 和
`gemm_dram_read_profile.json`。分析结果给出每阶段平均值、P50/P95/最大值，
以及按周期分类的 AXI R 通道等待计数。分类是互斥的周期统计；其中
`head_wait_with_later_beat_ready` 是额外的重叠诊断子集，不参与总和。
后端耗时包含 DRAMsim3 队列、bank/row 时序、刷新和读写竞争，不能直接
归因为某个物理机制。这个功能仅用于仿真和观测，不改 RTL 调度。

### 已通过的逐读请求结果

`/tmp/coral_dram_load_trace` 的完整 GEMM 通过，仍为 694.522 MAC/cycle。
10,560 个读 beat 的 `submit_to_backend_done` 平均 64.957ns，P95 为
453.5ns，最大 1,162.5ns；回调轮询平均只增加 0.771ns。
`observed_to_offer` 平均 25.110ns，最大 1,146ns：后续请求已经完成，
仍可能被同 ID 的较早请求挡在 AXI 返回队首。

48,446 个内存模型观测周期中，26,372 拍（54.4%）等待已提交的队首
请求完成；其中 10,327 拍（占总周期 21.3%）已有后续 beat 就绪。
R 通道反压仅 344 拍（0.71%）。这说明应优先检查后端长尾和按序返回
的放大作用，而不是先增加接口带宽。以上比例不是 PE 空闲率。

### 继续记录实际 DDR 命令

下面的开关自动开启读事件追踪，并额外记录原生库真正发出的 READ、
WRITE、ACTIVATE、PRECHARGE、REFRESH 等命令：

```bash
cd /home/wjj/2-NPU/coralnpu
CORAL_DRAMSIM3_COMMAND_TRACE=1 \
CORAL_DRAMSIM3_CONFIG="$PWD/tests/cocotb/CORAL_DDR4_32GBps_interleaved.ini" \
bash tests/cocotb/run_matrix_dramsim3.sh gemm /tmp/coral_dram_command_trace
```

增加的输出是 `dramsim3/ddr_commands.trace` 和
`gemm_dram_command_profile.json`。报告按配置解码每个读地址的 channel、
rank、bank group、bank、row、column，与物理 READ 匹配，拆分“提交到
READ 发出”和“READ 发出到回调”，并统计长延迟窗口内 WRITE 的数量、
同 rank 刷新窗口的重叠、相邻 READ 之间的 WRITE 批次。
READ/WRITE/REFRESH 总数必须与原生统计一致，否则分析失败。

WRITE 或 REFRESH 与请求等待重叠只说明相关性，不能把整个等待窗口
归因于该命令；控制器队列和 bank 时序也会影响调度。该分析当前支持
DDR4、六字段地址映射，并要求每个逻辑读对应一个物理 READ；如果引入
重复地址合并或写转发，分析器会明确拒绝无法一一匹配的轨迹。

命令记录只在桥接库编译时启用，借助随仓库提供的 Linux 动态库导出符号
观测命令，不依赖私有对象字段布局，不更改 DDR 调度或参数。它依赖这版
库的 C++ 符号；替换库后应先运行以下快速自检，验证记录入口和命令计数：

```bash
CORAL_DRAMSIM3_COMMAND_TRACE=1 \
bash tests/cocotb/run_matrix_dramsim3.sh selftest /tmp/coral_dram_commands_selftest
```

追踪时间使用内存模型的相对时间原点，不能直接当作 VCD 绝对时间。
周期统计覆盖内存模型开始到测试完成检查的观测区间，并非 PE 空闲周期
统计。`observed_to_offer` 包括按序返回和适配器调度等待；
`offer_to_handshake` 即使无反压也包含半个 AXI 周期。逐 beat 延迟可重叠，
不能把所有请求延迟求和当作 GEMM 墙钟时间。

需要 VCD 时使用同一用例的波形目标：

```bash
bash tests/cocotb/run_matrix_dramsim3.sh wave /tmp/coral_dram_wave
```

切换配置示例：

只改变 DDR 地址映射的 32GB/s 对照配置（保持所有时序参数相同）：

```bash
CORAL_DRAMSIM3_CONFIG="$PWD/tests/cocotb/CORAL_DDR4_32GBps_interleaved.ini" \
bash tests/cocotb/run_matrix_dramsim3.sh gemm /tmp/coral_dram_read16_interleaved_gemm
```

该配置把 bank group 放在低位以分散访问，详细映射和验证状态见
[性能对照文档](matrix_dramsim3_500mhz_performance.md)。切换 DDR 时序配置的示例：

```bash
CORAL_DRAMSIM3_CONFIG="$PWD/hdl/verilog/SIM/dramsim3/configs/DDR4_8Gb_x8_2666.ini" \
bash tests/cocotb/run_matrix_dramsim3.sh gemm /tmp/coral_dram_ddr4_2666
```

默认硬件等待上限为 1000000 个周期，Bazel 墙钟超时为 3600 秒。
分别用 `CORAL_GEMM_TIMEOUT_CYCLES`、`CORAL_DRAMSIM3_TIMEOUT` 调整。
`CORAL_GEMM_CLOCK_NS` 可以覆盖 MatrixCore/AXI 周期，默认是 `2.0`。
脚本启动日志和结果 JSON 均记录实际时钟。其他未选择 DRAMsim3 的既有
测试仍保留其历史默认时钟，避免重写此前的回归条件；也可以显式设置这个
变量运行 500MHz 的 multicreg GEMM RAM 对照测试。

## 输出与验证范围

每次完整仿真仍校验全部 C 元素、源数据/填充区、LOAD/STORE burst、退休
指令数量和写掩码，并检查每个 AXI beat 都进入 DRAMsim3 且收到完成回调。
这不是仅把旧测试的周期乘一个延迟系数。

输出包括：

- `test.log`：仿真日志。
- `gemm_metrics.json`：MAC/cycle、周期数、AXI 流量及 `memory` 模型信息，
  明确记录 AXI 位宽、DDR 通道位宽、时钟和共享峰值带宽。
- `dramsim3/dramsim3.json`、`dramsim3/dramsim3.txt`：后端统计。
- `dramsim3_backend.json`：实际加载库路径及 SHA256、DDR 配置 SHA256，
  外部构建库还包含上游提交和策略元数据。
- `dramsim3/axi_read_trace.jsonl`、`gemm_dram_read_profile.json`：仅在
  `CORAL_DRAMSIM3_TRACE=1` 时生成的读延迟拆解。
- `dramsim3/ddr_commands.trace`、`gemm_dram_command_profile.json`：仅在
  `CORAL_DRAMSIM3_COMMAND_TRACE=1` 时生成的原生命令及读长尾关联分析。
- `gemm_m512_n512_k128.vcd`：仅 wave 模式生成。
- `gemm_wave_profile.json`、`gemm_dram_dependency_profile.json`：开启读
  追踪的 wave 模式通过后自动生成的计算供数与 LOAD 等待关联报告。

短自检已通过：原生库加载、32 GB/s 配置与 512-bit AXI 对应关系、
独立时钟换算、读请求延迟、队列满后重试、
重复地址回调、AXI 返回顺序及不支持粒度的拒绝。完整 RTL 联调需运行上面
的 smoke，再按需要运行边界和性能用例；尚未据此给出新的 DDR 利用率。

默认使用仓库自带的 x86-64 Linux 预编译 DRAMsim3 动态库。桥接脚本需要
本机 g++ 和兼容的 C++ 运行库；只有显式运行写 drain 实验构建脚本才会
下载并重建 DRAMsim3 本体，还需要 git、CMake 和联网。
