# CoralNPU GEMM 软件调度参考

本文总结 `coral_gemm_mx_multicreg()` 当前采用的矩阵分块和指令调度方式，
用于后续编写其他尺寸 GEMM。目标是让 MatrixCore 在前一组矩阵计算时，
同时完成下一组 A/B 数据准备，并尽量让激活流在 PE 阵列中连续运行。

当前 `{M,K,N}={512,128,512}` 用例的实测结果为 1002.223 Logical MACs/cycle，
相对于 1024 MAC/cycle 理论峰值为 97.87%。这个数字依赖当前 RTL、DMA
带宽、ROB 和 scoreboard 配置；调度规则可以复用，但其他尺寸仍需独立验证。
实现入口见 [coral_matrix_gemm.h](../include/coral_matrix_gemm.h)，性能记录见
[性能分析](matrix_gemm_899_performance.md)。本例使用 ROB=64、矩阵 scoreboard=8。

## 1. 数据布局和硬件边界

计算目标是：

```text
C[M][N] = A[M][K] * B[K][N]
```

内存布局为：

```text
A: [M][K]，按行存储
B: [N][K]，已经转置，按输出列存储
C: [M][N]，按行存储
```

这里 C 的内存元素是 FP32，由 `msce32` 写出；C Reg 内部仍是定制累加数制。
各数据基址和字节 stride 需要满足当前 API 的 64 字节对齐要求。

因此 `B[n][k]` 是普通矩阵 `B[k][n]` 的元素。MatrixCore 的 DMA 沿 K
方向读取一行 B，所以调用方必须预先提供转置后的 B。

当前单条矩阵命令的逻辑上限为：

```text
tile_m <= 64
tile_n <= 64
tile_k <= 64
```

每 32 个 K 元素共享一个 scale。K 的软件分块边界可以是 64；如果最后
只剩不足 64 个元素，就将实际计算长度向上补齐到 32 的倍数，并对 A/B
输入做零 padding。完整的快速路径要求 K 是 64 的整数倍。

## 2. 三层分块

任意尺寸 `(M, N, K)` 先划分为：

```text
M tile:       [m0, m0 + tile_m),       tile_m = min(64, M - m0)
N group:      [n0, n0 + group_n),      最多 4 个 N tile
N tile:       [n0 + slot*64, ...),     tile_n = min(64, N - n_col)
K tile:       [k0, k0 + tile_k),       最多 64 个 K
```

一个 N group 最多包含四个 64 列 tile：

```text
C0: n0 + 0*64
C1: n0 + 1*64
C2: n0 + 2*64
C3: n0 + 3*64
```

这四个 C Reg 保存同一个 A tile 和不同 B tile 的部分和。沿 K 方向遍历
时，部分和一直驻留 C Reg。对每个 C tile，只有最后一个 K tile 的
MATMUL 已经发射后，才安排它的 STORE；硬件保证实际读取晚于结果完成。
不必等待同组另外三个 C tile 全部完成。

概念上可以理解为：

```text
for m0 in M tiles:
    for n0 in N groups:
        clear C0..C3
        for k0 in K tiles:
            accumulate four C tiles
        store C0..C3
```

当前快速路径把相邻两个 K tile 展开，并在 N group、M tile 的边界插入
预取和提前计算，所以实际发射顺序比这个概念循环更紧凑。
概念循环中的清零也不会一次集中发射四条，而是放在各自第一次 MATMUL 前、
对应 B 的 LOAD 后，防止旧 C 的 STORE 阻塞清零时连带挡住新的 B LOAD。

## 3. 物理 AB Reg 的固定调度

4 个 AB Reg 在硬件上地位相同。当前软件采用固定映射来减少动态寄存器
选择和地址计算，不代表硬件限制某个 Reg 只能保存 A 或 B。

偶数 K tile 使用：

```text
A0 + B1 -> C0
A0 + B2 -> C1
A0 + B3 -> C2
A0 + B1 -> C3
```

奇数 K tile 使用：

```text
A2 + B3 -> C0
A2 + B0 -> C1
A2 + B1 -> C2
A2 + B3 -> C3
```

也就是：

```text
even K: A0, B1/B2/B3/B1
odd  K: A2, B3/B0/B1/B3
```

这样做的原因是：

- A0 和 A2 交替保存相邻 K tile 的 A 数据。
- A0 所在阶段使用 B1、B2、B3，B1 在 C3 中复用。
- A2 所在阶段使用 B3、B0、B1，B3 在 C3 中复用。
- B 的复用由 MatrixCore scoreboard 保证旧 MATMUL 使用完成后才能覆盖。
- 四个 C Reg 与四个 N tile 固定对应，避免运行时为 C Reg 重新分配。

## 4. 一个 K tile 对内的发射顺序

### 4.1 偶数 K tile

以 `A0 + B1/B2/B3/B1` 为例，实际顺序是：

```text
LOAD A0(k0)

LOAD B1(n0,       k0) -> MZERO C0(仅首个 K tile) -> MATMUL C0
LOAD B2(n0+64,    k0) -> MZERO C1(仅首个 K tile) -> MATMUL C1
LOAD B3(n0+128,   k0) -> MZERO C2(仅首个 K tile) -> MATMUL C2
LOAD B1(n0+192,   k0) -> MZERO C3(仅首个 K tile) -> MATMUL C3
```

如果后面还有奇数 K tile，则在当前偶数阶段四条 MATMUL 发射后加载：

```text
LOAD A2(k0 + 64)
```

这是当前软件选用的顺序：A2 与当前 B2 共用物理 AB2。过早插入 A2 LOAD，
可能因旧 B2 仍被使用而停在顺序发射入口，连带挡住后面的当前阶段命令。
因此先发射四条当前 MATMUL，再提交 A2 LOAD。这里不是等待四条 MATMUL
全部完成；A2 覆盖 AB2 的安全性由 scoreboard 保证。

### 4.2 奇数 K tile，后面还有 K tile

奇数阶段先发射 C0、C1，再把当前 C2/C3 的 B LOAD 都排在下一轮 A LOAD 前：

```text
LOAD B3(n0,       k0) -> MATMUL C0
LOAD B0(n0+64,    k0) -> MATMUL C1
LOAD B1(n0+128,   k0)       # 当前 C2 的 B
LOAD B3(n0+192,   k0)       # 当前 C3 的 B
LOAD A0(next_k0)
MATMUL C2                  # 使用当前 A2、B1
MATMUL C3                  # 使用当前 A2、B3
```

这里的 A0 是下一偶数 K tile 的 A。它在当前 C2/C3 的 MATMUL 前预取，
这两条 MATMUL 使用 A2，不再读取 AB0。但 A0 与当前 B0 共用 AB0，
LOAD A0 仍可能等待前面的 C1 使用完成。因此先排好当前 C2/C3 的 B LOAD，
防止 A0 的等待把这些 DMA 请求挡住。下一偶数阶段跳过重复的 A0 LOAD。

### 4.3 最后一个 K tile

最后 K tile 的 MATMUL 完成该 C tile 的累加，因此需要写回。写回不能
提前到最后一个 K tile 之前，否则后续 K tile 将无法继续累加。

偶数 K 结束时，C0/C1 的 STORE 由后续 C1/C2 的发射路径带出，C2/C3
在最后补充：

```text
MATMUL C0
MATMUL C1 -> STORE C0
MATMUL C2 -> STORE C1
LOAD B1 -> MATMUL C3
LOAD 下一组 A0/B1
可选：MZERO C0 -> MATMUL 下一组 C0
STORE 当前 C2
STORE 当前 C3
```

奇数 K 结束时：

```text
MATMUL C0
MATMUL C1 -> STORE C0
MATMUL C2 -> STORE C1
MATMUL C3
预取下一组 A0/B1
可选：MZERO C0 -> MATMUL 下一组 C0
STORE 当前 C2
STORE 当前 C3
```

如果不能提前下一组 C0，奇数阶段改为：

```text
MATMUL C3 -> STORE 当前 C2
STORE 当前 C3
```

当前 C0 的 STORE 已经发射后，下一组才能复用 C0。STORE 不需要完成退休
后软件才可继续准备其他独立寄存器，但 C0 的实际复用仍由 scoreboard 检查。

## 5. N group 之间的预取

N group 的宽度最多为 256 列。下一组预取只在下面条件同时满足时启用：

```text
当前 group 是完整的四个 N tile
下一 group 也至少有完整的四个 N tile
K 是 64 的整数倍
下一 group 存在
```

满足条件时，在当前 group 的最后一个 K tile 中，先发射当前 C3 的 MATMUL，
再发射下一组的预取：

```text
LOAD 下一组 A0(m_next, k=0)
LOAD 下一组 B1(n_next, k=0)
```

B1 与 M 维度无关，所以只要下一 group 完整，B1 都可以预取。A0 只有在
下一组的 `tile_m` 与当前相同时才可以提前加载；如果下一组是短 M 尾块，
必须等当前 C store 发射后再修改 `msettilem` 并加载 A。

## 6. 跨 M tile 的提前 C0

当前组最后一个 N group 结束后，下一组会从下一个 M tile 的 `n0=0` 开始。
如果：

```text
next_tile_m == tile_m
```

则当前组结束时可以执行：

```text
LOAD 下一 M tile 的 A0(k=0)
LOAD 下一 M tile 的 B1(n=0, k=0)
MZERO C0
MATMUL 下一 M tile 的 C0
STORE 当前 C2
STORE 当前 C3
```

下一轮循环已经拥有 A0、B1，并且 C0 的第一个 K tile 已经发射，所以
下一轮需要跳过 C0 的第一次 MATMUL，从 C1 继续发射。软件通过三个标志
记录这个状态：

```text
prefetched_a0
prefetched_b1_c0
prefetched_c0_issued
```

如果下一 M tile 比当前短，则不执行提前 C0：

```text
STORE 当前 C2
STORE 当前 C3
CONFIG msettilem(较短行数)
LOAD 短 A0
```

这样旧 C store 仍使用旧行数，新的 M 配置不会影响旧结果。

## 7. M/N/K 边界的完整规则

### M 边界

- `tile_m` 相同：允许预取 A0，并提前下一组 C0。
- `tile_m` 变化：先发射旧 C2/C3 STORE，再执行 `msettilem`。
- M 尾块不改变算法，只使用较小的 `tile_m`。

### N 边界

- N 每 64 列形成一个 tile。
- 每 4 个 N tile 形成一个 group，C0..C3 分别保存四块结果。
- 当前和下一 group 都有 256 个有效列时，可以跨 group 预取；不要求整个
  N 是 256 的整数倍。例如 N=600 的前两个完整 group 可以重叠，进入最后
  88 列前则不使用这个跨组快速路径。
- N 尾 group 只使用有效的 C Reg，按实际 `tile_n` 设置 N 并写回。
- 尾 group 不使用需要完整四 tile 的提前 C0 快速路径。

### K 边界

- K 每 64 个元素形成一个 K tile。
- scale 每 32 个元素一组，K 尾部向上补齐到 32 的倍数。
- K 是 64 的整数倍时，使用偶数/奇数双 K tile 展开和预取。
- K 不是 64 的整数倍时，使用通用路径，逐 tile 设置实际 `tile_k`。
- 只有最后一个 K tile 允许 STORE C。

## 8. 可供其他尺寸参考的伪代码

### 8.1 外层坐标和地址

当前实现把 M/N 两层循环合并为一个 group 循环，以减少跨 M 时的标量准备：

```text
m0 = 0; n0 = 0
while m0 < M:
    tile_m = min(64, M - m0)
    group_n = min(256, N - n0)
    active = ceil_div(group_n, 64)
    tile_n[slot] = min(64, group_n - slot*64)

    # 使用下文调度完成本组全部 K；可能顺便发射下一组的首条 MATMUL
    schedule_group(m0, n0, tile_m, tile_n, K, carried_prefetch_state)

    n0 += group_n
    if n0 == N:
        m0 += tile_m
        n0 = 0
```

快速路径的条件是 `group_n == 256 && K % 64 == 0`。
仅仅 `active == 4` 不够，例如 193 列仍有四个 tile，但最后一个只有一列。

所有偏移如下，stride 单位均为字节：

```text
A 数据:    A  + m0*lda + k0
B 数据:    BT + (n0 + slot*64)*ldb + k0
A scale:   AS + (k0/32)*a_scale_stride + m0
B scale:   BS + (k0/32)*b_scale_stride + n0 + slot*64
C STORE:   byte_address(C) + m0*ldc + (n0 + slot*64)*4
```

以下每条 `LOAD A/B` 都代表两条矩阵指令：数据 LOAD 和 scale LOAD。
`MATMUL Cx` 表示 `Cx += A_tile * B_tile`。下面是软件发射顺序，不是
硬件完成顺序；各 LOAD、MATMUL、STORE 可以在不同单元重叠执行。

### 8.2 K=128、完整 N group 的实际顺序

该例最接近当前 512x128x512 性能用例。`current` 和 `next` 是不同输出块，
但它们复用同一组物理 C Reg。开始时消费上一组留下的三个标志：

```text
if not prefetched_a0:
    LOAD A0(current_m, k=0)
if not prefetched_c0_issued:
    if not prefetched_b1_c0:
        LOAD B1(current_n + 0, k=0)
    MZERO C0
    MATMUL C0(A0, B1)
clear the three consumed flags

# 偶数 K tile，k=0
LOAD B2(current_n + 64,  k=0); MZERO C1; MATMUL C1(A0, B2)
LOAD B3(current_n + 128, k=0); MZERO C2; MATMUL C2(A0, B3)
LOAD B1(current_n + 192, k=0); MZERO C3; MATMUL C3(A0, B1)
LOAD A2(current_m, k=64)

# 奇数 K tile，k=64，也是最后一个 K tile
LOAD B3(current_n + 0,   k=64); MATMUL C0(A2, B3)
LOAD B0(current_n + 64,  k=64); MATMUL C1(A2, B0)
STORE current C0
LOAD B1(current_n + 128, k=64); MATMUL C2(A2, B1)
STORE current C1
LOAD B3(current_n + 192, k=64); MATMUL C3(A2, B3)

# 只有当前/下一组均为256有效列时，才启用以下跨组预取
if prefetch_next_group:
    if next_tile_m == tile_m:
        LOAD A0(next_m, k=0)
        prefetched_a0 = true
    LOAD B1(next_n, k=0)
    prefetched_b1_c0 = true

    if next_tile_m == tile_m:
        # current C0 已经 STORE；scoreboard 保证复用时不破坏旧结果
        MZERO C0
        MATMUL next C0(A0, B1)
        prefetched_c0_issued = true

STORE current C2
STORE current C3

if prefetch_next_group and next_tile_m != tile_m:
    CONFIG M = next_tile_m
    LOAD A0(next_m, k=0)
    prefetched_a0 = true
# 下一组消费这些标志，从 C1 继续；若 C0 尚未发射，则补发 C0
```

预取标志表示命令已经安排，不表示 DMA 已经完成。下一条依赖命令是否
能实际发射由硬件判断；软件不查询完成状态，也不插入固定拍数的等待。
没有下一完整 group 时，上述预取分支不执行，保留正常的 C2/C3 STORE。

依赖寄存器的可用性随 MatrixCore 的完成信号释放，不必等待 ROB 退休。
不过依赖某条 LOAD 的 MATMUL 仍须等待该 LOAD 完成，当前没有边装载同一
寄存器边启动其 MATMUL 的逐行旁路。预取的作用是把这段等待藏在其他计算中。

维度配置也遵循发射边界：旧 LOAD/STORE 必须先交给 MatrixCore、锁存旧
维度，再发射新的 CONFIG；不是要求旧 STORE 完成或退休。完整 N/K 块尽量
维持 N=64、K=64，等行数跨 M 也不重复设置 M，以减少顺序发射入口的停顿。

### 8.3 扩展到其他 K 和尾块

K=64、192 等含奇数个完整 K tile 时，最后阶段使用 A0，仍采用
`MATMUL C1 -> STORE C0`、`MATMUL C2 -> STORE C1`、
`MATMUL C3 -> 下一组预取/提前 C0 -> STORE C2/C3` 的顺序。
每组只有 k=0 时清零，后续 K tile 全部累加。

K=256 等包含非最后奇数阶段时，使用第 4.2 节的顺序：当前 C2/C3 的
B 先 LOAD，下一偶数阶段的 A0 随后 LOAD，再发射当前 C2/C3 MATMUL。

非快速路径的保守模板如下。它仍使用最多四个 C Reg：

```text
for k0 = 0; k0 < K; k0 += logical_tile_k:
    logical_tile_k = min(64, K - k0)
    tile_k = round_up(logical_tile_k, 32)
    CONFIG K = tile_k when required
    choose fixed even/odd A and B mapping
    LOAD A
    for slot = 0; slot < active; slot++:
        CONFIG N = tile_n[slot] when required
        LOAD B for slot
        if k0 == 0: MZERO C[slot]
        MATMUL C[slot]
        if last K tile:
            STORE C[slot] using the same M and N
```

这是通用路径的正确性模板。当前代码还对完整 256 列、但 K 有尾块的情况
保留“后一块 MATMUL 后 STORE 前一块”的优化；不启用跨组预取。
不足 256 列的组走逐 tile STORE，避免 N 配置已经切换导致 STORE 宽度错误。

## 9. 为什么这个调度利用率高

高利用率来自以下几个因素共同作用：

1. C0..C3 沿 K 方向驻留，避免每个 K tile 都写回和重新清零。
2. K 循环两两展开，减少 shape 配置、寄存器选择和循环控制指令。
3. 当前 C3 MATMUL 发射后，立即预取下一组 A0/B1，覆盖 DMA 和装权延迟。
4. 当前 C0/C1 完成后就逐步 STORE，不等待四个 C Reg 全部结束。
5. 下一组 C0 可以在旧 C2/C3 STORE 前发射，消除同 M 和等行数跨 M 的空档。
6. A/B 的覆盖由 MatrixCore scoreboard 排序，软件只需要遵守 shape 和有效
   数据边界，不需要等待每条 LOAD 退休。
7. 短 N/K 使用通用路径；M 行数变化时延后配置和 A LOAD，避免旧 STORE
   读到新维度。短 M 本身仍可在完整 N/K group 内采用快速路径。

当前实测波形中，512 个内部 block 的相邻起点全部间隔 64 拍；因此稳态
激活流已经连续，不表示每拍每个 PE 都在做有效 MAC。该次无 AXI 背压、
稀疏数据用例共 33480 拍，其中连续激活输入 32768 拍，启动 399 拍、
收尾 313 拍。继续提升该用例时，重点应转向启动、收尾和不同尺寸下的
固定开销，而不是继续压缩已经消失的组间输入气泡。

## 10. 编写新尺寸 GEMM 时的检查清单

```text
[ ] A 是 [M][K]，B 已转置为 [N][K]
[ ] lda/ldb/scale stride/ldc 满足 DMA 对齐和最小跨度
[ ] K 尾部已零 padding，scale 数量为 ceil(K/32)
[ ] 每个 tile 的 M/N/K 不超过 64
[ ] C Reg 只在对应 tile 的最终 K 完成后 STORE
[ ] LOAD B 后的 MATMUL 依赖由 scoreboard 保护
[ ] 覆盖 N=64、65、128、129、255、256、257
[ ] 覆盖 M=1、63、64、65、127、128、129
[ ] 覆盖 K=1、31、32、33、63、64、65、127、128、129
[ ] 覆盖 full group、N 尾 group、M 尾块和 K 尾块
[ ] 在有背压时确认命令不会依赖固定周期假设
[ ] 用功能校验和波形分别检查输出、STORE 顺序和激活连续性
```

