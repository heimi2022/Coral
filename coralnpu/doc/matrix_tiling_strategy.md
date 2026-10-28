# CoralNPU 矩阵分块策略

本文解释如何把大矩阵乘法拆成 MatrixCore 支持的 tile，并结合物理 AB
Matrix Reg、C 累加寄存器说明数据如何驻留、复用和写回。本文描述当前代码
和 RTL 的实现边界，可作为后续 C API 与 AI 编译器 lowering 的参考。

当前高利用率版本的指令编排、A/B 预取及 M/N/K 边界规则，集中见
[GEMM 软件调度参考](matrix_gemm_schedule_reference.md)，其中给出了
K=128 完整 group 的实际发射顺序和可复用伪代码。

## 当前实现进度（2026-10-15）

已实现软件分块工具，以及使用固定物理寄存器映射的多 C reg GEMM 接口。
AB 物理寄存器生命周期分配器仍作为独立通用工具保留，但 GEMM 热路径不再调用它。
用户已确认最新的 `N=65/129/255/257` 四个用例在
Verilator 和 VCS 下全部通过。这轮工作只更新软件、测试和文档，没有修改 RTL。

当前推荐入口为 `coral_matrix_gemm_multicreg_run()`：把大矩阵拆成不超过 64x64x64
的运算，最多让四个 N tile 的部分和保存在 C0..C3，复用同一块 A，遍历
全部 K tile 后再写出 FP32 结果。N 尾块仍走 multicreg 路径。

接口参数集中在 `coral_matrix_gemm_desc_t` 中，高层 GEMM 统一使用
`coral_matrix_gemm_multicreg_run()`。`coral_gemm_mx_multicreg()` 保留为长参数
兼容入口，需要逐项传递所有指针、stride 和尺寸参数。N group 只有一个
tile 时，同一个调度自然只使用 C0，不需要独立的单 C Reg 回退实现。

本轮增加任意正整数 M/N/K 的软件支持：K 不再要求是 32 的倍数，描述符
保留逻辑 K，最后一段计算时向上补齐到 32。调用方先准备零 padding 的
A/B 行，并提供 `ceil(K/32)` 组 scale。新增布局计算、补零函数与边界测试，
用户已确认第 14 节新增的 7 个 Verilator 硬件用例全部通过，覆盖最小维度、
M/N/K 尾块、四 C reg 调度和 AXI 背压。该批用例尚未进行 VCS 验证。

目前完成的是可执行的 C API 软件调度层。工具链负责生成冻结编码的矩阵
指令；尚未实现自动识别普通 C matmul 循环的编译器优化。完整四 N tile 且
K 为 64 的倍数时，GEMM 走专用的双 K tile 展开，消除热循环中的 shape、
寄存器选择和 K/group 除法控制；其余尾块继续走通用路径。主机调度模型已
覆盖 252 组 M/N/K 形状并通过。具体实现和本轮验证范围见第 12 节。

## 1. 运算和内存布局

目标运算：

```text
C[M][N] = A[M][K] * B[K][N]
```

MatrixCore 的 B/weight 输入方向要求 B 按转置形式存储：

```text
B_transposed[N][K]
B_transposed[n][k] = B[k][n]
```

也就是说，内存中的每个 B 行对应一个输出列，沿 K 方向连续。这不是普通
row-major 的 `B[K][N]` 布局；当前约定调用方已经提供转置好的数据，
本轮不增加 B 转置接口。

当前 MXINT8 运算中：

- A、B 数据元素是 S1.6 int8。
- 每连续 32 个 K 元素共享一个 scale。
- A scale 的逻辑布局为 `a_scale[ceil(K/32)][M]`。
- B scale 的逻辑布局为 `b_scale[ceil(K/32)][N]`。
- 输出 C 由 msce32 写成 FP32 row-major 矩阵。

scale 的分组编号为 g = floor(k/32)，对应原始 K 区间
[g*32, g*32+31]。数据 tile 与 scale tile 必须使用相同的 K 分组起点。

## 2. 单条指令和接口约束

当前软件按单条 MatMul 最大 tile 尺寸 64x64x64 调度：

```text
tile_m <= 64
tile_n <= 64
tile_k <= 64
```

接口接收任意正整数 M、N、K，不再要求逻辑 K 是 32 的倍数。A、转置 B
的每行 `[K, round_up(K,32))` 必须预先补零；最后不足 32 个数的组使用
该组原有 scale，补出的零不产生贡献。GEMM 不会在指令执行期间修改输入，
也不自动分配临时 buffer。零维度仍返回 BAD_ARGUMENT。

当前 DMA 接口还要求矩阵起始地址 64B 对齐，并要求 lda、ldb、
a_scale_stride、b_scale_stride 和 ldc 都是 64B 的倍数。各 stride 单位是
字节。常见的 packer 取值为：

```text
lda              = round_up(K, 64)
ldb              = round_up(K, 64)
a_scale_stride   = round_up(M, 64)
b_scale_stride   = round_up(N, 64)
ldc              = round_up(N * sizeof(float), 64)
```

同时必须满足 lda >= round_up(K,32)、ldb >= round_up(K,32)、a_scale_stride >= M、
b_scale_stride >= N、ldc >= N*sizeof(float)。物理行可以比逻辑行宽，
多出的字节是 padding，不属于有效矩阵元素。

`include/coral_matrix_gemm_layout.h` 提供两个准备接口：

- `coral_matrix_gemm_layout_init(&layout, M, N, K)` 计算上述 stride、五个
  buffer 的容量、`compute_k` 和 scale 组数，并检查 size_t 溢出。
- `coral_matrix_gemm_pad_k(A, lda, B_transposed, ldb, M, N, K)` 将可写
  输入每行的 K 尾部置零。它不复制有效元素、不转置 B、不改 scale。

例如 `M=65,N=257,K=129`，逻辑矩阵仍为 A[65][129]、B_transposed[257][129]。
建议 A/B 行 stride 为 192B，scale 行 stride 分别为 128B/320B，C 行
stride 为 1088B。需要 5 组 scale；K tile 的逻辑宽度为 64/64/1，
发给硬件的计算宽度为 64/64/32。下面示意完整的调用顺序：

```c
#include "include/coral_matrix_gemm.h"
#include "include/coral_matrix_gemm_layout.h"

coral_matrix_gemm_layout_t layout;
int rc = coral_matrix_gemm_layout_init(&layout, m, n, k);
if (rc != CORAL_MATRIX_LAYOUT_OK) return rc;

/* Caller allocates five 64-byte-aligned buffers with layout.*_bytes capacity,
 * fills A/BT using layout.lda/ldb and fills ceil(K/32) scale rows. */
rc = coral_matrix_gemm_pad_k(a, layout.lda, bt, layout.ldb, m, n, k);
if (rc != CORAL_MATRIX_LAYOUT_OK) return rc;

const coral_matrix_gemm_desc_t desc = {
    a, layout.lda, bt, layout.ldb,
    a_scale, layout.a_scale_stride, b_scale, layout.b_scale_stride,
    c, layout.ldc, m, n, k,
};
return coral_matrix_gemm_multicreg_run(&desc);
```

准备完成的输入必须对 DMA 可见，并保持到相关命令完成。这个函数返回值
表示参数检查及指令提交完成，不是额外的硬件完成屏障。此阶段只验证 GEMM
写出结果，不加入后续标量/RVV 读取 C。C 只写有效 MxN 元素，行 padding
保留；目前不支持直接输出到不满足 64B stride 要求的紧凑 C buffer。

## 3. 物理寄存器映射

### 3.1 AB Matrix Reg

RTL 中 ABMatrixReg 有 4 个物理寄存器，每个容量为 64 行 x 64B。4 个
寄存器在硬件上地位完全相同；硬件没有规定 reg0 只能放 A 或其它 reg
只能放 B。A/B 操作数名称只是指令中的访问角色，实际物理寄存器由指令
字段选择：

| 操作数名称 | 可选择的物理 AB reg | 说明 |
|---|---:|---|
| A0、B0 | 0 | A/B 都可以选择物理寄存器 0 |
| A1、B1 | 1 | A/B 都可以选择物理寄存器 1 |
| A2、B2 | 2 | A/B 都可以选择物理寄存器 2 |
| A3、B3 | 3 | A/B 都可以选择物理寄存器 3 |

所以 A0 和 B0 不能同时保存两块不同的数据。这里表示它们选择同一个物理
寄存器，而不是表示物理寄存器 0 只能作为 A 使用。固定 GEMM 调度采用
固定 GEMM 调度直接采用下面的映射；这只是软件策略，不是硬件固定要求：

```text
AB reg 0 / A0 : 当前 A[M tile, K tile]
AB reg 1 / B1 : 第 1 个 N tile 的 B
AB reg 2 / B2 : 第 2 个 N tile 的 B
AB reg 3 / B3 : 第 3 个 N tile 的 B
```

第四个 N tile 没有新的空闲 AB reg，固定调度复用 B1 对应的物理 Reg；硬件
scoreboard 会等待 B1 的最后一次 MMACC 使用完成后才允许覆盖。覆盖任何
AB reg 之前若旧内容仍被 MMACC 使用，就会导致计算读到错误数据。

通用 lowering 若需要动态映射，仍可遵守下面的生命周期原则；当前 GEMM
热路径不执行这些选择：

```text
1. 从 4 个 AB reg 中选择一个保存 A tile。
2. 从剩余空闲 reg 中选择 B tile 的存放位置。
3. 记录每个物理 reg 的最后使用者和释放时间。
4. 只有在最后一个使用该 reg 的 MMACC 完成后才能重新 load。
```

分配器用单调递增的 command-order event 表示“最后使用”，而不是假设固定
时钟数。Reg 在事件 E 的 MMACC 中仍然有效；进入大于 E 的事件后才变成可
复用状态。这只是软件生命周期；真正发射覆盖 load 前，CPU 的矩阵寄存器
scoreboard 会等待旧 MMACC 完成，不能把软件事件当作硬件完成信号。

scale 有独立的 ABScaleReg 存储，按相同的物理寄存器编号与数据寄存器配对。
例如 A0 数据与 A0 scale、B2 数据与 B2 scale 分别对应同一逻辑 tile。

### 3.2 C 累加寄存器

C0、C1、C2、C3 是独立的累加寄存器文件，与 AB Matrix Reg 分开：

| 输出 slot | C 累加寄存器 |
|---:|---|
| 0 | C0 |
| 1 | C1 |
| 2 | C2 |
| 3 | C3 |

每个输出 tile 的生命周期是：

```text
mzero(Cx)              只在这个输出 tile 的第一个 K tile 前执行一次
mmacc(Cx, B, A)        对这个输出 tile 的每个 K tile 执行
msce32(Cx, address)   所有 K tile 累加完成后执行一次
```

若在每个 K tile 前都清零，之前 K tile 的部分和会丢失。

## 4. 任意合法 M/N/K 的基础分块

分块起点按 64 递增：

```text
m0 = 0, 64, 128, ...
n0 = 0, 64, 128, ...
k0 = 0, 64, 128, ...
```

每个 tile 的实际边长：

```text
tm = min(64, M - m0)
tn = min(64, N - n0)
tk = min(64, K - k0)
compute_tk = round_up(tk, 32)
```

逻辑 `tk` 可为 1..64，矩阵指令实际使用 `compute_tk`，因此硬件宽度
只有 32 或 64。`coral_matrix_k_tile_t.size` 表示逻辑宽度，
`compute_size` 表示硬件宽度。K=96 时为 64/32；K=65 时逻辑为 64/1，
硬件为 64/32，最后一组只有一个有效元素。

tile 起始地址：

```text
A_tile       = A            + m0 * lda + k0
B_tile       = B_transposed + n0 * ldb + k0
A_scale_tile = a_scale      + (k0 / 32) * a_scale_stride + m0
B_scale_tile = b_scale      + (k0 / 32) * b_scale_stride + n0
C_tile       = C            + m0 * ldc + n0 * sizeof(float)
```

特别注意 B 地址使用 n0*ldb，因为 B 是 `[N][K]`；不要按普通` [K][N] `的
地址公式计算。

## 5. 四个 C reg 的 N 方向分组

四 C reg 优化把最多 4 个相邻的输出 tile 合成一个 N group，每个 tile 的宽度不超过 64 列。下面的
映射是当前 GEMM 的固定软件调度，不是 RTL 的固定要求：

```text
group 起点 n0 = 0, 256, 512, ...
group 覆盖最多 256 列
```

一个完整的四 tile group 映射如下：

| slot | 输出列区间 | B 操作数 | 物理 AB reg | C reg |
|---:|---|---|---:|---|
| 0 | n0 .. n0+63 | B1 | 1 | C0 |
| 1 | n0+64 .. n0+127 | B2 | 2 | C1 |
| 2 | n0+128 .. n0+191 | B3 | 3 | C2 |
| 3 | n0+192 .. n0+255 | B1，复用 | 1 | C3 |

A tile 和前三个 B tile 同时占用四个物理 AB reg。分配器会记录每个 Reg
的 operand kind、owner、首次使用事件和最后使用事件；如果调度策略改变，
A tile 可以放到其它物理 Reg，MMACC 的 A/B 字段也会随分配结果改变。第四
个 tile 到来时，等待被选中的 B reg 完成最后一次使用后再覆盖它。

N group 不足 4 个 tile 时只使用存在的 slot。例如 N=192 使用 C0/C1/C2；N=128 使用 C0/C1。N group 的实际 tile 数为：

```text
active = min(4, ceil((N - n0) / 64))
```

对每个 M tile 和 N group，K 方向所有 tile 都累加进同一批 C reg。每个 C
完成最后一个 K tile 的 MMACC 后立即发射自己的 store，不等待其它 C。
不能在非最终 K tile 之间 store 再重新 zero。

## 6. 四 C reg schedule 的指令顺序

固定一个 M tile 和一个 N group：

1. 为当前 M tile 设置一次 M；K 全部由 64 元素 tile 组成时设置一次 K。
2. 偶数 K tile 使用 A0 和 `B1/B2/B3/B1`；奇数 K tile 使用 A2 和
   `B3/B0/B1/B3`。A0/A2 交替让下一块 A 不覆盖当前 MMACC 的输入；奇数
   tile 把重复 B 放到 B3，使 B0 的最后一次使用提前，从而不拖住下一块
   A0 的装载。不能把第四个奇数 N tile 改回 B0：那会让 reg0 仍有一个
   后续 B 使用，下一偶数 A0 的预加载就必须等到该 MMACC 消费完。
3. 对前三个 N tile 逐个执行：配置实际 N，使用对应的 B reg
   装入 B tile 和 scale，然后发射对应 C 的 MMACC。仅在 `k0=0` 时，
   在该 tile 的 B/scale load 之后、MMACC 之前插入对应 C 的 mzero。
4. 配置指令不等待旧 MMACC 退休，允许多条 MMACC 在途；不在 group 开始时
   集中清零四个 C，避免尚未完成的旧 C store 阻塞下一组 A/B load。
5. 若 active=4，把第四个 B tile 装入复用的 B1。硬件 scoreboard 等待
   B1 的旧使用者完成后才允许覆盖。
6. 第一个 K tile 在 B1/scale load 之后清零 C3，再执行 C3 的 MMACC；
   后续 K tile 对 C0..C3 都不再清零，继续累加。
7. 最后一个 K tile 中，每个 C 的 MMACC 后紧接它自己的 store，直接复用
   此条 MMACC 的 N shape。STORE C0 不等待 C1/C2/C3 都完成累加。

对于完整四 tile N group 且 K 是 64 的倍数，热路径将相邻两个 K tile
展开为一个软件流水段。顺序为：

```text
even: load A0
      B1/C0, B2/C1, B3/C2, B1/C3
odd:  load A2
      B3/C0, B0/C1
      load next-even A0
      B1/C2, B3/C3
```

`A2` 放在四条 even MMACC 之后，是因为它和 even 的 B2 共用物理 reg2；
否则 B2 的 scoreboard 等待会挡住 even 的 B3/C2、B1/C3。`next-even A0`
放在 odd 的 B0/C1 之后，是因为奇数映射中 B0 不再有后续使用；它和 odd
剩余的 B1/B3 不冲突，可以形成 K tile 切换的 lookahead。下一轮直接复用
已经装好的 A0。这个展开只改变完整四 tile N group 的发射顺序，尾块仍走
通用路径。

上面的 `B/C` 表示 B payload/scale load 和 MMACC；如果它是最后一个 K
tile，还包括紧接 MMACC 的该 C 的 STORE。组末不再集中发出四条 STORE。
完整四 tile group 在全部 STORE 发出后，优先预取下一组 A0 和 B1，
让它们的 DMA 与旧 C 写回重叠。不在 STORE C2 前插入下一组 B2 load：
AB2 此时可能仍保存当前组最后一个 K tile 的 A2。

各 tile 的 load、首次清零和 MMACC 顺序很重要。msettilem/k/n 不再要求 ROB 清空。配置指令
发射后，Decode 阻止下一拍矩阵指令与普通 CSR 发射，等待配置写入 CSR；
独立标量指令仍可发射。软件不需要插入 nop。`coral_gemm_mx_set_n(tile_n)`
等价于：

```text
msettilen(tile_n)
```

SCore 的旧 load/store 可能还在等待标量操作数，或等待 MatrixCore 接收。
这两种情况下配置必须等待，直到 mem.fire 交接完成。DMA 在握手时保存
rows/cols/stride；之后即使传输尚未结束，新的配置也不会改变旧命令。
MMACC 同样在接收时保存 M/N/K。配置可以与旧命令执行重叠，AB/C 数据依赖
仍由矩阵 scoreboard 管理，普通 CSR 指令仍要求 ROB 清空。

例如 T 拍发射 msettilen，T+1 拍写 CSR 并阻止矩阵消费者，T+2 拍即可
接收使用新 N 的 MMACC，无需等待上一条 MMACC 退休。若 ROB 满或存在寄存器
冲突，仍由原有规则等待。

本次修改处理配置与命令交接的时序，没有增加配置状态在较老指令异常时的
回滚机制；不能据此声称精确异常恢复已验证。具体实现见
include/coral_matrix_gemm.h 的 coral_gemm_mx_multicreg()。

## 7. N 尾块与 multicreg 调度

### N 是 64 的倍数

当前可以使用四 C reg 路径。例如 N=64、128、192、256、512。末尾 group
可以有 1、2、3 个完整的 64 列 tile，也可以包含一个不足 64 列的尾 tile。

### N 不是 64 的倍数

例如 N=193，前三个 tile 是 64 列，最后一个 tile 只有 1 列。这里的
“同一个 multicreg group”不是一条硬件指令同时操作四个 C reg，而是连续
发射多条 MMACC / load / store 指令。每条矩阵指令都有自己的 `cfg_n`，因此
可以让不同 C reg 对应不同宽度：

```text
C0、C1、C2 使用 N=64
C3             使用 N=1
```

这在当前 RTL 中有对应的独立 metadata 路径：`matmul_tiling` 为每个 N/K
block 生成自己的 `psum_n_cols`；`pe_ctrl` 将它写入 output/writeback
metadata，并分别用它产生 C 读写阶段的有效列 mask。N1 还通过 `nblock`
选择 C reg 的高半区。因此尾块只会少写无效列，不要求 C0~C3 使用相同的
宽度，也不需要修改 MatrixCore RTL。

软件实现也应保留每个 slot 的实际 `tile_n`，并在该 slot 的 MMACC、C 读和
C store 前设置对应的 N；不能把最后一个尾 tile 填充成 64 列后无条件写回。
在 MMACC 前使用 `set_n(tile_n)` 恢复实际 N；它只发出
`msettilen()`，配置生效的等待由 Decode 完成。当前
`coral_gemm_mx_multicreg()` 已按这个规则调度尾块。

例如 N=193 可以在同一个 multicreg group 中按下面方式调度：

```text
slot 0: N=0..63,   tile_n=64, C0
slot 1: N=64..127,  tile_n=64, C1
slot 2: N=128..191, tile_n=64, C2
slot 3: N=192..192, tile_n=1,  C3
```

对 slot 3，`matmul_tiling` 会生成 `nblock=0、psum_n_cols=1` 的 block，
计算只使能第 0 列，写回时也只产生这一列的有效数据。C3 仍然可以在同一
个 group 中保持自己的 K 累加状态；完成 K 遍历后，再按 `tile_n=1` 执行
store。

## 8. 512 x 128 x 512 具体映射

这里按常用记法写成 M x K x N：

```text
A = 512 x 128
B = 128 x 512，实际内存布局 B_transposed = 512 x 128
C = 512 x 512
```

tile 数：

```text
M_tiles = 512 / 64 = 8
N_tiles = 512 / 64 = 8
K_tiles = 128 / 64 = 2
```

每个 M tile 中，N 方向分成两个 group：n0=0 和 n0=256。每个 group
处理 4 个 N tile。下面的 A0/A2 和 B0/B1/B2/B3 是当前验证程序采用的
两相软件分配，不是硬件规定的固定角色。对固定的 m0/n0：

```text
k0 = 0:
    load A[64x64] -> A0
    load B tile 0 and scale -> B1; mzero C0; mmacc C0
    load B tile 1 and scale -> B2; mzero C1; mmacc C1
    load B tile 2 and scale -> B3; mzero C2; mmacc C2
    reload B tile 3 -> B1
    load B tile 3 scale; mzero C3; mmacc C3

k0 = 64:
    load下一块 A -> A2
    load B tile 0 and scale -> B3; mmacc C0; store C0
    load B tile 1 and scale -> B0; mmacc C1; store C1
    load B tile 2 and scale -> B1; mmacc C2; store C2
    load B tile 3 and scale -> B3; mmacc C3; store C3
    不再 mzero

if 下一组也是完整四 N tile group:
    必要时设置下一 M tile 的 M
    prefetch 下一组 A -> A0
    prefetch 下一组 B tile 0 and scale -> B1
```

总输出 group 数是 8*2=16；每组有 4 个 C tile，每个 C tile 有 2 个 K
step。因此：

```text
MMACC = 16 * 4 * 2 = 128 条
MZERO = 16 * 4 = 64 条
STORE C = 16 * 4 = 64 条
```

这个形状的多寄存器 C API 程序为
tests/cocotb/matrix_c_api_multicreg_gemm_program.cc，cocotb 回归会检查
输出矩阵数值、矩阵指令退休计数和 AXI 读写序列。

## 9. 四 C reg 的伪代码

下面伪代码表达包含 N 尾块时的通用 schedule。当前 C 实现采用固定的两相软件
映射：偶数 K tile 为 `A0/B1/B2/B3/B1`，奇数 K tile 为
`A2/B3/B0/B1/B3`；四个 AB Reg 在硬件上仍然对称，固定映射只是减少热路径
中的动态寄存器选择。当 K 为 64 的倍数时，每个完整四 tile N group
使用双 K tile 展开，即使整个 N 还有后续尾块；其它 group 使用同样寄存器
映射的通用循环。当整个 N 没有尾块时，
整个 GEMM 只配置一次 `set_n(64)`；否则完整 N group 只配置一次
`set_n(64)`，尾 group 才逐 tile 配置 `set_n(tile_n)`，随后连续发出 B
load、scale load 和 MMACC。覆盖旧
`B1` 的 load 由硬件 scoreboard 等待最后一个使用者完成。
每个 C 的清零只出现在 `k0=0`，安排在该 slot 的 B/scale load 之后、
MMACC 之前；不提前集中清零整组 C。这样某个 C 等待旧 store 完成时，
已经发射的下一组 A/B load 可以继续进行。

```text
function GEMM_multicreg(A, B_transposed, scales, C, M, N, K):
    validate positive dimensions, aligned strides, buffer extents
    # A and B are already zero-padded through round_up(K,32).
    # Scale storage has ceil(K/32) rows.

    for m0 = 0; m0 < M; m0 += 64:
        tm = min(64, M - m0)

        for n0 = 0; n0 < N; n0 += 256:
            active = min(4, (N - n0 + 63) / 64)

            for slot = 0; slot < active; slot++:
                tile_n[slot] = min(64, N - (n0 + slot * 64))
                c_reg[slot] = C0, C1, C2, or C3

            for k0 = 0; k0 < K; k0 += 64:
                tk = min(64, K - k0)
                compute_tk = round_up(tk, 32)
                final_k_tile = (k0 + tk == K)
                g0 = k0 / 32
                set_tile_m(tm)
                set_tile_k(compute_tk)

                # Fixed software mapping; all fields are compile-time constants.
                # Use A0/B1/B2/B3/B1 for even K tiles and A2/B3/B0/B1/B3
                # for odd K tiles.
                load A tile and its scales into (A0 or A2)

                if active >= 1:
                    set_n(tile_n[0])
                    load B tile and scales into the phase's B register
                    if k0 == 0: mzero(c_reg[0])
                    mmacc(c_reg[0], phase_b[0], phase_a)
                    if final_k_tile:
                        msce32(c_reg[0], C_tile_address(m0, n0))
                if active > 1:
                    set_n(tile_n[1])
                    load B tile and scales into the phase's B register
                    if k0 == 0: mzero(c_reg[1])
                    mmacc(c_reg[1], phase_b[1], phase_a)
                    if final_k_tile:
                        msce32(c_reg[1], C_tile_address(m0, n0 + 64))
                if active > 2:
                    set_n(tile_n[2])
                    load B tile and scales into the phase's B register
                    if k0 == 0: mzero(c_reg[2])
                    mmacc(c_reg[2], phase_b[2], phase_a)
                    if final_k_tile:
                        msce32(c_reg[2], C_tile_address(m0, n0 + 128))

                if active == 4:
                    set_n(tile_n[3])
                    load fourth B tile and scales into phase_b[3]
                    if k0 == 0: mzero(c_reg[3])
                    mmacc(c_reg[3], phase_b[3], phase_a)
                    if final_k_tile:
                        msce32(c_reg[3], C_tile_address(m0, n0 + 192))

    return OK
```

## 10. 后续编译器 lowering 应跟踪的资源

AI 编译器可以把一个高层 matmul lowering 成上面的循环，但调度器必须跟踪
寄存器的活跃区间：

| 资源 | 活跃区间 | 可以复用的条件 |
|---|---|---|
| A operand / 任意 AB reg | A load 到该 K tile 的 MMACC 全部消费完 | 当前 K step 完成 |
| B operand / 任意 AB reg | 对应 B tile 的最后一次 MMACC 消费完 | scoreboard 允许覆盖 load 发射 |
| C0..C3 | mzero 到全部 K 累加、store 完成 | 对应 C tile 写回完成 |

其中 `set_n` 只发射配置指令，Decode 等待 N 配置通过 CSR 路径生效。
当前 C API 不再在热路径使用软件 AB 生命周期分配器，而是使用上述固定映射；
编译器 lowering 若采用其它映射，仍必须依据 MMACC 对输入数据的最后使用时刻，
不能只按“寄存器当前看起来空闲”来覆盖 AB 数据。

## 11. 支持范围总结

RTL 和目标 multicreg schedule 的支持范围可以概括为：

| 输入情况 | 策略 |
|---|---|
| 正整数 M/N/K，输入按要求补零，地址和 stride 满足 64B 对齐 | 可进入 tiled GEMM |
| 任意 M 尾块 | 最后一个 M tile 使用 min(64, M-m0) |
| N 是 64 的倍数 | multicreg 可按最多 4 个 N tile 使用 C0..C3 |
| N 不是 64 的倍数 | multicreg 仍可使用 C0..C3；尾 tile 使用自己的 `tile_n` |
| K 是 64 的倍数 | K tile 都是 64 |
| K 除以 64 余 32 | 最后一段 K tile 宽度为 32 |
| K 不是 32 的倍数 | 先用 pad_k 补零，GEMM 将最后一段计算宽度向上取整到 32 |

因此，“支持任意大矩阵”应理解为通过软件循环支持任意规模的合法尺寸；
实际能否走四 C reg 优化仍受输入 padding 和 DMA stride 约束；N 不对齐本身不是
硬件禁止 multicreg 的条件。

## 12. 实现结构与本轮验证

### 12.1 软件各层的职责

| 文件 | 已实现的职责 |
|---|---|
| `include/coral_matrix_tiling.h` | 校验非零尺寸和 K 的 32 元素分组，提供 M tile、N group/N tile、K tile 的起点、大小和 scale 分组信息 |
| `include/coral_matrix_ab_allocator.h` | 独立的通用 AB 生命周期工具和单元测试；当前 GEMM 热路径不依赖它 |
| `include/coral_matrix_gemm.h` | 校验地址和 stride，按固定 A0/B1/B2/B3/C0..C3 调度生成 load、scale load、mzero、MMACC 和 store 指令 |
| `tests/cocotb/matrix_cpu_dma_test.py` | 加载实际 C API ELF，在 CPU/MatrixCore/AXI 路径上执行并核对数值、访存和退休计数 |

tiling 工具提供可独立查询的 plan API；当前 GEMM 发射循环使用同一头文件的
tile 常量、`min` 和向上取整函数计算分块，没有先创建完整 plan 再逐项遍历。

### 12.2 一组输出如何执行

固定一个 M tile 和最多 256 列的 N group 后，执行顺序是：

1. 遍历 K；每个活动 C slot 在第一个 K tile 的 B/scale load 之后、
   MMACC 之前清零一次，跨 K tile 保留部分和。
2. 每个 M tile 配置一次 M；K 全部为 64 元素 tile 时只配置一次 K，装载
   A0 及其 scale。
3. 当 N 没有尾块时，整个 GEMM 只配置一次 `N=64`；否则完整 N group
   配置一次 `N=64`，尾 group 在每个活动 N tile 前配置实际 N，然后按
   `B load -> scale load -> 首个 K tile 执行 MZERO -> MMACC` 发射。前三个 tile
   使用 B1/B2/B3，第四个 tile 覆盖并复用 B1。
4. B1 覆盖由硬件 scoreboard 等待旧的 B1 使用者完成，不依赖软件 event 或
   `nop`；每条命令在接收时保存自己的维度。
5. 全部 K step 完成后，完整 N group 直接执行 `msce32`；尾 group 逐 slot
   恢复自己的 N 后再 store。例如 N=65 时，C0 写出 64 列，C1 只写出 1 列。

退休计数中，一个尾 N group 的 N 配置条数为
`(ceil(K/64) + 1) * active`：每轮 K 为各活动 slot 设置一次 N，
store 时再为各 slot 设置一次。不能固定按 `2 * active` 计算。
例如 `M=65、N=257、K=128` 的 CONFIG 总数为 11：M 配置 2 条、
K 配置 1 条，两个 M tile 内各有 1 条完整 N group 配置和 3 条尾 group 配置。

四个 AB Reg 在接口上对称，但当前调度固定 A0/B1/B2/B3 以减少标量指令。
这不是硬件限制；其它软件 lowering 仍可选择其它映射，但必须满足同样的
scoreboard 依赖。当前实现已经按每个 B tile 的 load 后立即 MMACC 发射，
而不是先把前三块 B 全部装载完再计算。

### 12.3 本轮通过的用例

四个用例均为 `M=64、K=64`，区别在 N 方向边界：

| N | 各 group 的 N tile 宽度 | 主要覆盖点 | Verilator | VCS |
|---:|---|---|---|---|
| 65 | `[64, 1]` | 两个 C slot，短尾块加载后恢复首条 MMACC 的 N | PASS | PASS |
| 129 | `[64, 64, 1]` | 三个 C slot，短尾块与完整 tile 的 N 切换 | PASS | PASS |
| 255 | `[64, 64, 64, 63]` | 四个 C slot，第四块 B 的 AB Reg 复用及 63 列 store | PASS | PASS |
| 257 | `[64, 64, 64, 64]`，`[1]` | 跨 N group 的资源复用及第二组的 1 列尾块 | PASS | PASS |

VCS PASS 是用户运行脚本后报告的结果。四个用例检查的不只是程序停止：

- CPU 无 fault，并在超时前正常 halted。
- 配置、load、MMACC、mzero、C store 的退休数量与软件 schedule 一致。
- AXI 读写地址、burst 顺序和响应完成情况符合预期，没有遗留事务。
- C 的每个 FP32 元素与参考结果按字节一致；参考值按每 32 个 K 元素的
  int8 点积乘 `2^(a_scale+b_scale-254-12)`，再沿 K 累加。
- 写字节集合只包含有效 C 元素，且完整内存镜像匹配；没有重复写、遗漏，
  或破坏源数据、padding 和 guard 区域。

这些 multicreg 用例使用确定性输入，每个 32 元素分组的前四个元素非零，
scale 编码取 126..128，AXI memory model 不插入背压。因此本轮结果验证了
这些形状下的软件分块与寄存器调度正确性，不能替代随机数值、背压或所有
尺寸组合的覆盖，也不代表已经评估吞吐、面积或功耗。

### 12.4 重跑命令

VCS 脚本覆盖上述四个用例，串行构建和执行，单个测试超时为 900 秒：

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_matrix_multicreg_vcs.sh
```

脚本接受额外 Bazel 参数，例如末尾加 `--test_timeout=1800`。
对应的 Verilator 命令为：

```bash
bazel test \
  //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_n65 \
  //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_n129 \
  //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_n255 \
  //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_n257 \
  --jobs=1 --local_test_jobs=1 \
  --test_output=streamed --nocache_test_results --test_timeout=900
```

软件分块工具和 AB 分配器的独立单元测试入口为：

```bash
bazel test \
  //tests/toolchain:coral_matrix_tiling_test \
  //tests/toolchain:coral_matrix_gemm_layout_test \
  //tests/toolchain:coral_matrix_ab_allocator_test \
  --test_output=errors
```

### 12.5 新增组合边界用例

新增 `M=65,N=257,K=128` 的 C API ELF，用两个测试入口分别执行无 AXI
背压和带背压的同一运算。初次运行两个入口均失败；用户修改 pending 条件后，
2026-10-12 两个入口均在本轮完整 Verilator 模型上通过，结果见第 13 节。
分块为：

```text
M: 64 + 1
N: group 0 = [64,64,64,64], group 1 = [1]
K: 64 + 64，每个输出 tile 保留 C 部分和跨 K 累加
```

预期执行 20 条 MMACC、10 条 MZERO 和 10 条 C STORE，产生 65x257 个
FP32 元素。A/B 行 stride 为 128B，scale 行 stride 为 512B，C 行 stride
为 1088B；每行 C 只有前 1028B 有效，其余 60B padding 必须保持原值。
带背压入口复用 `MatrixMemory` 的地址/数据通道周期性停顿、读数据间隔和
延迟写响应；两个入口均检查完整内存镜像、有效写字节、AXI 事务与退休计数。

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_matrix_multicreg_boundary.sh verilator
bash tests/cocotb/run_matrix_multicreg_boundary.sh vcs
```

这两个命令各运行上述形状的两个入口。原来的
`run_matrix_multicreg_vcs.sh` 仍只重跑第 13.3 节的四个已通过用例。

#### 短分块累加依赖与本次修复

初次运行仅 `C[64,256]` 错误：得到 `-0.513427734375`，参考值为
`-0.0419921875`。软件最终输出 tile 的两条 MMACC 实际握手维度均为
`M=1,N=1,K=64`，每条指令内部进一步拆为两个 32 元素的 K block。
这里的全局列 256 映射到局部列 0，不是硬件的 N1 block。

波形确认四个 K32 点积依次为 `346,-424,510,-604`，对应贡献为
`0.08447265625,-0.103515625,0.12451171875,-0.1474609375`。
前两个贡献相加应为 `-0.01904296875`，最终结果应为 `-0.0419921875`。
PE 点积正确；错误发生在后一 K block 的 C 读取早于前一 K block 的写回。
这属于累加的数据依赖，不需要出现同拍的奇偶 bank 冲突。

`pe_ctrl` 在分块首行激活读取时将 `stream_start_age_q` 清零，使用
`stream_start_pending_q` 阻止下一分块过早发出首行。当 M=1 且下一块权重
已准备好时，当前块的首行、末行和下一块 `stream_pop` 可以同时发生。
原来的 pending 判断只检查旧的 `next_stream_ready`；若旧 age 已为 7，
它会漏掉本拍重新清零的情况。此时一拍 boundary bubble 仍然生效，但两块
首行仅相隔两拍，不足以等待 C 部分和写回。

用户修改了 pending 的置位条件：在 `stream_pop` 时，若计时尚未 ready，
或者本拍同时发出当前块首行，都将下一分块标记为 pending。状态机、权重
预加载和 age 的现有阈值保持不变；只约束下一分块的激活读取。
这个条件不会使每条 MMACC 固定等待：没有同拍首行发出且 age 已 ready 的
`stream_pop` 不会触发 pending，pending 在 ready 时也不阻止激活读取。

补充独立控制器用例 `pe_ctrl_m1_n1_k64_c_dependency`，直接覆盖一行激活、
一行权重和两个 K32 block 的累加，同时检查 C 读写冲突和定制 C 数值。
它已注册到 `//tests/cocotb:pe_ctrl_standalone`。2026-10-12 使用现有 Verilator
工具直接构建修复后的独立模型，四个控制器用例全部通过；新增单行用例在
修复前的旧模型上失败，在修复后通过，包括 K1 读 C 前 K0 已写回的检查。
完整组合边界 ELF 用例的本轮结果见第 13 节；标准 Bazel 控制器目标未在本轮重跑。

## 13. 配置与在途命令重叠的实现与验证

配置重叠改动时 ROB 保持 8 项（后续扩为 32 项，见第 18 节）。
`Decode.scala` 删除了矩阵配置必须等 ROB 清空的条件，
普通 CSR 的条件保持原样。`SCore.scala` 将访存操作数暂存和命令待接收状态
反馈给 Decode；只有这两种状态都结束，后续配置才可发射。

配置发射后的下一拍，Decode 暂停矩阵指令和普通 CSR，等待 CSR 写入完成；
独立标量 ALU 指令可在这一拍发射。GEMM 软件因此删除了配置后的 `nop`。
MatrixCore、PE、指令编码和 ROB 容量不属于本次修改范围。

新增端到端用例在没有软件 `nop` 的情况下，顺序发射两条 MMACC：

| 用例 | 第一条 M/N/K | 第二条 M/N/K | AXI 背压 |
|---|---|---|---|
| matrix_cfg_overlap | 64/64/64 | 3/1/32 | 无 |
| matrix_cfg_overlap_backpressure | 64/1/64 | 3/64/32 | 有 |
| matrix_cfg_overlap_n_boundary | 64/33/64 | 3/32/32 | 无 |

用例要求第二组配置和第二条 MMACC 均在第一条 MMACC 退休前发射，并检查
最后一次 B 装载尚未退休时第一组配置已经发射。随后核对两组输出的每个
FP32 元素、store 字节掩码、完整内存镜像、AXI 事务和顺序退休。
这些检查分别验证命令维度快照、CPU 访存交接和在途命令重叠。

2026-10-12，标量侧 36 项单元测试通过，包含 ROB 非空时配置发射、访存
暂存期间配置等待、配置后一拍的消费者等待，以及普通 CSR 仍需 ROB 清空。
上表三个端到端用例，以及 N65 和无背压 M65/N257/K128 的 multicreg ELF
回归通过。第一组用例的 MMACC0 在第 193 拍发射、第 522 拍退休，MMACC1
已在第 200 拍发射；FIRST CFG 在第 108 拍发射，LAST LOAD 第 191 拍退休。
带背压用例分别在第 236/243 拍发射两条 MMACC，第一条第 406 拍退休。
这些周期由测试监视器从启动后计数，不是整段仿真的绝对时钟编号。
VCS 由用户执行。

补充回归 N129、带背压 M65/N257/K128、MX 累加、标量/RVV 高负载并发和
C load/store 背压也全部通过。本轮合计 36 项标量单元测试、10 个 Verilator
端到端用例通过。原有 VCS 历史结果不能替代这次配置时序修改后的 VCS 回归。

统一运行脚本覆盖上表三个用例和 N65/N129、M65/N257/K128（含背压）的
四个 multicreg ELF 回归：

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_matrix_cfg_overlap.sh verilator
bash tests/cocotb/run_matrix_cfg_overlap.sh vcs
```

原有 tutorial 的 MMACC/ROB 用例已改为要求配置在旧 MMACC 退休前发射。
VCS 命令：

```bash
bazel test --config=vcs \
  //tests/cocotb/tutorial:vcs_matrix_mmacc_rob \
  --jobs=2 --test_output=errors --nocache_test_results
```

本次未实现旧指令异常时对提前写入的矩阵配置做回滚，精确异常恢复仍需
独立设计与验证，不能由这些正常执行用例推断。

## 14. 任意正整数维度 GEMM 验证

新增用例以 `(M,N,K)` 表示，全部使用已转置 B 和 K 零 padding：

| 维度 | 覆盖目标 |
|---|---|
| (1,1,1) | 最小维度，31 个补零元素 |
| (3,65,31) | K 最后一组少一个元素，N 尾列 |
| (33,129,33) | M/N 跨 PE block，第二个 scale 组仅一个元素 |
| (65,257,65) | M/N/K 全部跨 tile，四 C reg、多 N group |
| (65,257,65)，背压 | 同一组合边界，AXI 停顿和延迟 B 响应 |
| (3,193,127) | 四 C reg、K 最后一组补一个零 |
| (3,65,129) | 三个 K tile，192B 输入行 stride |

参考模型使用稠密 S1.6 int8 数据、不同的逐组/逐行/逐列 scale，直接对
原始 K 个元素计算结果，不把 padding 纳入数学点积。测试还核对 FP32
输出每一元素、完整内存镜像、有效写字节、AXI 读写与退休指令计数。
本轮 3 项软件单元测试与 6 个 ELF 编译通过。2026-10-13，用户确认
下列脚本中的 7 个 Verilator 硬件用例全部通过。重跑命令：

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_matrix_gemm_any.sh verilator
```

暂不要求 VCS。需要时同一脚本将首个参数换成 `vcs`。

## 15. 大矩阵波形与性能基线

使用现有 `M=512,N=512,K=128` ELF 程序，输入 A 为 `[512][128]`，
已转置 B 为 `[512][128]`，输出 C 为 `[512][512]` FP32。M 分成 8 个
64 行 tile，N 分成 2 组、每组 4 个 64 列 tile，K 分成 2 个 64 元素
tile；总计执行 128 条 MMACC、64 条 MZERO 和 64 条 C STORE。

运行并导出波形：

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_matrix_gemm_wave.sh
```

脚本使用独立的 Verilator 波形入口，保持通常的回归入口不变。波形直接
写入 Bazel 的 test outputs，测试成功后提取到固定目录：

```text
/tmp/coral_matrix_gemm_512_wave/gemm_m512_n512_k128.vcd
/tmp/coral_matrix_gemm_512_wave/gemm_metrics.json
/tmp/coral_matrix_gemm_512_wave/test.log
```

如需另存，可将目录作为脚本第一个参数。VCD 可用本机 Verdi 打开：

```bash
verdi -sv -ssf /tmp/coral_matrix_gemm_512_wave/gemm_m512_n512_k128.vcd
```

该用例使用既有稀疏测试数据和无主动背压的 AXI RAM 模型，每个 32 元素
scale 组中前 4 个元素非零，仍按完整的 K 维度执行矩阵指令。适合分析
指令、DMA 和 PE 的时序；不用于估计稠密数据的翻转功耗或真实 DRAM 性能。

`gemm_metrics.json` 的周期统计从 `execute_from` 调用前开始，到 CPU
halt 为止，包含启动控制、标量指令、DMA、计算和全部 C store；不包含
之前的 ELF 装载和之后的检查等待。它不是纯 PE 运算周期。文件同时记录
逻辑 MAC 数、平均 MAC/cycle、AXI 读写 beat/字节数和矩阵指令退休计数。
模拟时钟沿用测试默认的 1.25 ns；分析吞吐时应首先比较周期数，不能据此
推断芯片已达到该频率。

波形中可优先搜索 `u_pe_ctrl`，观察 `cmd_valid_i/cmd_ready_o` 握手、
`state`、`rs2_read_valid_o`、`rs1_read_valid_o`、`rd_write_valid_o` 和
`done_valid_o`，结合 MatrixCore 的 `matmul_valid_i/matmul_ready_o`、
`mem_valid_i/mem_ready_o` 及顶层 matrix AXI 通道，区分装载等待、权重装载、
激活输入、累加写回和 C 输出阶段。

## 16. 驻留计算连续发射与描述队列反压

满尺寸 N tile 的前三块 B 已驻留在 AB reg 时，软件使用固定的物理寄存器
映射和维度配置，再连续发射三条 MMACC。例如 A 在 AB0，
三块 B 在 AB1/AB2/AB3，结果分别写 C0/C1/C2；指令之间不再插入寄存器
选择分支和 N 配置。这个快速路径只处理相同 N=64 的驻留块，N 尾块仍然
使用对应的有效维度。四个 AB reg 的分配能力和一般调度路径保持不变。

每条 M/N/K=64/64/64 的 MMACC 会生成四组描述，顺序为
N0-K0、N0-K1、N1-K0、N1-K1。weight 和 act/psum FIFO 各有 8 项，
消费者独立出队，因此两条命令就可能填满其中一个队列。第三条命令能被
接收，并不表示它的四组描述已经全部进入 FIFO。

旧的 `matmul_tiling` 未连接 FIFO 的 `full_o`，在 StateFill 每拍都推进。
连续发射时，满 FIFO 会拒绝实际写入，但分块计数仍增加，导致描述丢失；
最后一块即使没有写入，也会退出 StateFill。此前失败的 512/512/128
波形中，按上升沿之前的稳定输入采样，前三条命令在约
1448.75、1456.25、1463.75 ns 接收，第三条
丢失全部四个 act/psum 描述和三个 weight 描述，之后无法完成。

修复只改变分块前端的写入许可和结束条件：

```text
write_pair = StateFill && !weight_full && !act_psum_full
if write_pair:
    同时写入当前 weight 和 act/psum 描述
    推进 block_fill_count
    if 当前是最后一个 block:
        退出 StateFill
else:
    保留当前 block，不推进计数，继续保持 fill_busy
```

`pe_ctrl` 在命令握手时已保存 M/N/K 和寄存器号。等待期间这些快照保持
不变；现有 `cmd_ready_o = !pc_full && !fill_busy && !tiling_start_q`
将前端反压传给上游。第三条命令可以先被接收，随后在展开期间等待空间，
上游则不能再提交第四条命令。已经进入队列的描述继续执行并释放空间，
不暂停 PE 或累加器流水线，也不增大任一 FIFO。

若队列在某拍开始时为满，即使该拍出队，仍不写入新描述；下一拍看到
非满后才恢复。两类消费者不要求同时出队，但生产端必须成对写入，
避免一类描述成功、另一类描述丢失。单块命令和多块命令的最后一块也遵守
相同规则。

新增独立测试分别覆盖 act/psum FIFO 满、weight FIFO 满，以及单块命令
的最后一块被阻塞。测试先填满两个队列，再只释放一侧空间，确认仍然
等待；随后逐项释放另一侧空间，核对每条描述的寄存器、维度、地址、
N/K block 和 last 标记，检查没有丢失或重复。

```bash
bazel test \
  //tests/cocotb:matmul_tiling_backpressure_act_fifo_full \
  //tests/cocotb:matmul_tiling_backpressure_weight_fifo_full \
  //tests/cocotb:matmul_tiling_backpressure_single_last_block_full \
  --jobs=2 --local_test_jobs=1 --test_output=errors --nocache_test_results
```

2026-10-13，上述三个 Verilator 独立测试和 PE 控制器的四个用例通过。
用户随后确认 `run_matrix_tiling_backpressure.sh` 的全部用例通过，包括
整核 multicreg smoke、N65/N129/N255/N257 和 M65/N257/K128（含 AXI
背压）。随后用户运行大 GEMM，功能与波形检查均通过，结果见第 17 节；
旧的大 GEMM 通过日志不计入这次修改的验证结果。

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_matrix_tiling_backpressure.sh
bash tests/cocotb/run_matrix_gemm_wave.sh
```

第一个脚本覆盖三个反压单元测试、四个 PE 控制器用例，以及 multicreg
smoke、N65/N129/N255/N257、M65/N257/K128（含 AXI 背压）。第二个
脚本运行 512/512/128 大 GEMM 并导出波形，路径见第 15 节。

软件发射但未退休的命令数量，与 MatrixCore 实际握手接收的命令数量是
不同指标，分析在途情况时应结合 `cmd_valid_i && cmd_ready_o` 的波形。

## 17. 大 GEMM 的实际接收与描述完整性检查

`run_matrix_gemm_wave.sh` 在功能测试通过并导出 VCD 后，自动运行
`tests/cocotb/analyze_matrix_gemm_wave.py`。分析器按 VCD 中的 timescale
转换时间，取每个上升沿前稳定的信号值，避免同一时间戳中时钟和状态
更新的文本顺序影响握手统计。无需修改 RTL 或额外暴露硬件端口。

大 GEMM 仍检查全部输出数据、AXI 事务与退休指令计数。额外波形检查为：

| 检查 | 预期 |
|---|---|
| `cmd_valid_i && cmd_ready_o` | 共接收 128 条 MATMUL |
| `done_valid_o && done_ready_i` | 共返回完成 128 条，PC 与接收顺序一致 |
| 已接收但未返回完成的命令峰值 | 至少 3 条 |
| weight/act_psum 描述写入 | 两侧每次同时成功，各 512 项 |
| weight/act_psum 描述出队 | 各 512 项，全部命令结束后无剩余 |
| 任一描述 FIFO 满且正在展开命令 | 不写描述，对外 `cmd_ready_o=0` |

描述总数由每条已接收命令的 N/K 维度推导，当前大 GEMM 的每条命令
均为 64/64/64，因此 128 条命令对应 512 组描述。PC 完成返回是
MatrixCore 向上游的完成握手，不能直接等同于 CPU ROB 退休。
三条命令在途表示共享 PE 阵列前后存在排队或执行中的命令，不能解释为
三个独立 PE 阵列同时计算。

运行命令保持不变：

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_matrix_gemm_wave.sh
```

结果目录新增 `gemm_command_overlap.json`，与 VCD、`gemm_metrics.json`
和 `test.log` 同在 `/tmp/coral_matrix_gemm_512_wave/`。其中
`peak_accepted_uncompleted_matmuls` 表示实际在途峰值，
`first_three_accepts` 和 `first_accept_gaps_ns` 给出前三条接收的
PC、维度、时间与间隔，`fill_stalled_cycles` 位于 `counts` 中，记录
描述队列满而等待的周期数。`verified=true` 表示波形检查通过；它与
功能测试的 `gemm_metrics.json` 一起使用。

只重新分析已有完整波形时可以运行：

```bash
python3 tests/cocotb/analyze_matrix_gemm_wave.py \
  /tmp/coral_matrix_gemm_512_wave/gemm_m512_n512_k128.vcd \
  --metrics /tmp/coral_matrix_gemm_512_wave/gemm_metrics.json \
  --output /tmp/coral_matrix_gemm_512_wave/gemm_command_overlap.json
```

若本次仿真失败，导出脚本仍提取本次可用的 VCD 和日志；编译失败未
开始仿真时，不使用之前留下的 test outputs。功能测试失败或波形检查
失败都会让脚本返回非零退出码。不同运行结果可以通过脚本的目录参数
分开保存。

2026-10-13，分析器的六个小测试通过，覆盖上升沿采样顺序、三条在途、
FIFO 满等待、不成对写入、满队列写入、错误完成顺序、截断波形和串行
接收。它对旧失败波形得到：接收 3 条、完成 2 条，weight 写入/出队
各 9 项、act/psum 写入/出队各 8 项，预期各 12 项，因此正确返回失败。
修复后的大 GEMM 完整结果已于 2026-10-13 读取并确认，功能测试 PASS，
`gemm_metrics.json` 与 `gemm_command_overlap.json` 均为 `verified=true`。

| 本次结果 | 数值 |
|---|---|
| M/K/N | 512/128/512 |
| 接收 / 完成 / 退休 MATMUL | 128 / 128 / 128 |
| 实际已接收但未完成的峰值 | 3 |
| weight 描述写入 / 出队 | 512 / 512 |
| act/psum 描述写入 / 出队 | 512 / 512 |
| 波形规则违规 | 0 |
| 从启动调用到 CPU halt | 83,226 周期 |
| 逻辑 MAC 数 | 33,554,432 |
| 平均逻辑 MAC/cycle | 403.172 |
| AXI 读 / 写字节 | 675,840 / 1,048,576 |
| 描述 FIFO 满时展开等待 | 6,752 周期 |
| 上游有有效命令但 ready 为低 | 320 周期 |

前三条实际接收时间为 1448.75、1456.25、1463.75 ns，相邻间隔
7.5 ns，即当前模拟时钟下的 6 拍；第一条完成返回发生在 1860.0 ns。
因此第三条在第一条完成前已经接收，原先只有一条命令在途的现象在
本用例中已解决。

FIFO 满时的 6,752 周期是描述生成端等待，并不直接表示 PE 停算了
6,752 周期；已有描述可以继续执行。波形分析器观察到 83,222 个复位
释放后的上升沿，与从 `execute_from` 调用前开始统计的 83,226 周期
使用不同边界，不应将这两个统计混用。

当前结果是无主动 AXI 背压、稀疏输入的整段 GEMM 基线，平均吞吐包含
软件、DMA、计算和 C store。下一步性能分析应统计激活输入、权重装载、
DMA 和命令等待的时间及重叠关系，区分流水填充与软件/访存等待，再决定
是否优化调度；不能仅凭在途数量或 FIFO 满周期判断 PE 利用率。

## 18. CPU ROB 扩为 32 项

2026-10-13，根据用户确认，将 `Parameters.scala` 的
`retirementBufferSize` 从 8 改为 32。32 是 2 的幂，符合现有循环队列
的容量要求，指针仍按二进制截断回绕。Decode 的 ROB 空槽输入改成
`log2Ceil(retirementBufferSize + 1)` 位，即 6 位，可完整表示 0..32。
ROB、结果暂存和退休端口中使用该参数的结构随之扩容。

此修改针对大 GEMM 中 CPU 的等待：前三条 MATMUL 已接收后，ROB
被尚未退休的矩阵和后续标量指令占满，第四块 B 的地址准备和 LOAD
延迟到前三条完成后才继续。扩大 ROB 给后续准备指令提供更多空间；
能否消除 PE 空闲及提高吞吐，必须以新仿真数据判断。

矩阵 scoreboard 使用独立参数 `matrixScoreboardDepth = 8`，Decode
通过 `MatrixScoreboard(p.matrixScoreboardDepth)` 实例化，不再与 ROB
容量绑定。ROB 保存所有未退休指令并保证按序退休；矩阵 scoreboard
保存未完成矩阵命令的 PC 和 AB data、AB scale、C 访问掩码，在
MatrixCore 返回完成时释放，供 RAW/WAR/WAW 冲突判断使用。

这不是增加物理矩阵寄存器，也不是保证 MatrixCore 同时接收 32 条
MATMUL。AB/C 仍各 4 个，MatrixCore 的 PC FIFO 和描述 FIFO 容量不变，
实际接收仍受 ready 和寄存器依赖限制。最多记录 8 条尚未完成的矩阵
LOAD/STORE、MATMUL 和 MZERO；满表时通过已有发射 interlock 暂停
后续这类矩阵指令，完成释放槽位后继续，支持同拍释放和补入。
ROB 剩余槽位仍可用于满足其他发射条件的标量/RVV 指令。

测试退休监视器按实际 `io_debug_rb_inst_*` 端口数量扫描，替代写死的
8 项，避免扩大 ROB 后漏记同一拍第 8 项及之后的退休指令。
RVVI trace 深度独立配置为 16（`rvviTraceDepth`），不随 32 项 ROB 扩展；
CSR trace 的矩阵规模由原先按 ROB 深度生成的 32x32 降为 16x16。
启用退休缓冲/RVVI 的验证配置下，退休缓冲每拍最多释放 16 项，保证
所有退休项都能被 RVVI 记录；非验证配置不受该上限影响。当前核心每拍
最多发射 4 条，故 16 路 trace 不会截断正常退休数据。未来若发射或
退休通道宽度超过 16，Chisel 参数约束/RTL assertion 会要求同步扩大
RVVI 深度，而不是静默漏记。
新增单元测试覆盖 Decode 的 0/1/31/32 个空槽、32 项循环队列满空/
回绕/同时进出/flush，以及按独立配置（当前 8 项）的 scoreboard 满表、同拍完成与补入、
逐项释放和 C 依赖保持。

完整回归的单元阶段已通过全部 23 个目标，包括 32 项循环队列、
标量、RVV、浮点、矩阵 scoreboard/Decode 和软件分块测试。
此前矩阵集成回归中，四个 PE 控制独立用例和
激活 FIFO 满的 tiling 反压用例通过。完整整机回归尚未完成：此前
Chisel 生成整机 RTL 时出现 JVM 堆内存不足，属于构建失败，不能据此
判断 RTL 功能失败或完整回归通过。`rules/chisel.bzl` 已为生成器增加
`emit_jvm_flags` 参数，默认堆上限 `-Xmx4g`；此设置仍需通过完整构建验证。
用户本次完整回归在矩阵阶段再次构建失败，57 个仿真均未执行。
内核日志确认系统内存耗尽，swap 剩余为 0，RTL 生成 Java 进程的
匿名驻留内存约 4.3 GiB，被 OOM killer 杀掉；此时不是测试断言失败。

完整非 VCS 回归由用户运行：

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_rob32_full_regression.sh
```

脚本自动查询当前 BUILD 中的测试，覆盖 common/core 单元测试、矩阵
集成、标量/RVV cocotb、tutorial、Verilator C++ 仿真和软件分块单元
测试。排除 `manual`、`vcs` 和 `synthesis` 标签，不运行 VCS 专属用例
及需要手动选择的大型工作负载。分单元、矩阵、其余仿真三个阶段，
默认编译任务数和同时仿真数均为 1，使用 Bazel batch 模式，Bazel
自身堆上限为 1024 MiB、使用 Serial GC；Scala/Java 编译使用 local
策略，避免持久 worker 在 RTL 生成期间占用内存。生成 RTL 的独立
JVM 仍使用 `-Xmx4g`，两者不是同一堆参数。出现构建或测试
失败立即停止，不自动修改 RTL。

本次 23 项单元测试已通过，可从矩阵阶段继续，随后执行其余仿真：

```bash
bazel shutdown
bash tests/cocotb/run_rob32_full_regression.sh --from matrix
```

`bazel shutdown` 释放前次运行留下的 server 和 worker，不清理构建
缓存。`--from` 跳过的阶段在 `status.tsv` 记为 `SKIPPED_BY_FROM`，
最终通过数量只统计本次请求运行的阶段。该模式不会检查跳过阶段是否
曾通过，只有前次通过且源码未变化时才应据此合并结果。
资源调整尚未完成长时间构建验证。如果仍被系统 OOM 杀掉，应增加
WSL 的可用内存或 swap，再继续；不能以减小 ROB 或跳过仿真替代验证。

每次运行在 `/tmp/coral_rob32_full_<时间>_<进程号>/` 保存完整及分阶段
目标清单、查询日志、各阶段控制台日志、Bazel build-event JSON 和
`status.tsv`。若构建失败，后续阶段尚未执行，不能按仿真失败统计。
可用 `CORAL_REGRESSION_DIR` 指定目录；`--list-only` 只生成清单，不
编译、不运行仿真。实际测试数量随 BUILD 变化，以清单为准。

两个外部 RV32 ELF 仿真也包含在回归中，脚本默认调用现有 Coral RV32
GCC/binutils 和 ELF 校验脚本，在结果目录生成 Matrix 与 RVV+Matrix
程序。可用 `CORAL_RV32_ELF`、`CORAL_RV32_RVV_ELF` 指定已有 ELF；
指定文件缺失时直接报错，不静默跳过。自定义工具链路径沿用
`CORAL_TOOLCHAIN_ROOT`、`CORAL_RV32_CC`、`CORAL_RV32_CC_B` 和
`CORAL_RV32_BINUTILS`。外部 ELF 使用 local TestRunner 访问绝对路径。

较短的定向回归及性能波形命令仍保留：

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_matrix_rob32.sh
bash tests/cocotb/run_matrix_gemm_wave.sh /tmp/coral_matrix_gemm_512_rob32_wave
```

首个脚本运行标量/RVV/矩阵单元测试、高负载并发、配置重叠和 tiling
反压回归。第二个生成本次大 GEMM 的 VCD 和统计，与原先
`/tmp/coral_matrix_gemm_512_wave/` 的 8 项 ROB 基线分开保存。
比较启动到 halt 的周期、平均 MAC/cycle、实际在途峰值，以及第四块 B
的 LOAD 和第四条 MATMUL 接收时间。本次配置为 ROB 32 项、矩阵
scoreboard 8 项；该配置的性能、面积和时序
尚未验证，不能沿用第 17 节的 403.172 MAC/cycle 作为新结果。

### 大 GEMM 波形仿真的墙钟超时

2026-10-14 的 512x128x512 波形运行在 900 秒墙钟限制下超时，
最后记录为 28672 个周期，MATMUL 退休 52/128，STORE C 退休 24/64。
此前每隔 4096 个周期的记录中，指令退休数和 DMA 读写数持续增加，
这段日志未显示死锁；但本次未完成结果校验，不能据此判定功能通过。
按已观察进度粗估，完整波形运行需要约 35～40 分钟，实际耗时取决于
主机负载和波形写盘速度。

`run_matrix_gemm_wave.sh` 默认墙钟超时为 3600 秒，仅限制同时仿真数
为 1；不再传入 `--jobs=1`，构建并行度使用 Bazel 配置。无需修改
RTL，重新运行：

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_matrix_gemm_wave.sh /tmp/coral_matrix_gemm_512_rob32_wave
```

可通过 `CORAL_GEMM_WAVE_TIMEOUT=5400` 等环境变量覆盖秒数。
测试正常结束后，脚本提取 VCD 和 `gemm_metrics.json`，随后生成
`gemm_command_overlap.json`。这次超时运行未提取到波形或性能统计；
输出目录存在并不代表上述文件已生成。若重新运行仍超时，应比较
最后几条进度记录，区分持续推进与计数停止，再决定后续排查方向。

### 交错 LOAD/MATMUL 调度的验证状态

当前软件按 `LOAD B1 -> MATMUL C0 -> LOAD B2 -> MATMUL C1 ->
LOAD B3 -> MATMUL C2 -> LOAD B1 -> MATMUL C3` 的顺序发射。
这里每次 LOAD 包括 payload 和 scale；每块 B 装载前、计算前各设置
一次 N。该顺序替代第 16 节的预装三块 B 后连续发射方案，不能直接
沿用其在途数量和性能结论。

2026-10-15 检查的完整运行在仿真时间 90081.25ns 时已 halt，失败于
旧测试要求的 `peak_unretired_matmuls >= 2`，实际峰值为 1，并非外部
墙钟超时。失败发生在 C 内存结果比较之前，因此这次运行尚不能记为
功能通过，也说明新的交错顺序没有达到多条 MATMUL 在途的性能目标。
具体发射阻塞原因仍需结合波形排查，不能仅凭顺序推断实现了 DMA 与
计算重叠。

退休计数期望同步改为当前序列：每个 K 分块设置 M/K 各一次，每个
N tile 在装载和计算前各设置 N 一次，最终每个 C store 再设置 N。
对于 512x128x512，期望 CONFIG=384、LOAD=320、MATMUL=128、
MZERO=64、STORE C=64。数值结果、全部退休计数和 AXI 事务检查保持
严格校验；功能检查完成后先保存统计，再检查性能门槛。

波形脚本默认 `CORAL_GEMM_MIN_INFLIGHT=1`，用于测量当前调度，
不会将单条在途宣称为性能优化成功。CPU 未退休峰值低于 2 时打印
警告；波形分析仍检查描述符数量、成对写入、FIFO 满时反压、完成顺序
和所有命令最终完成。需要把至少两条在途作为验收要求时运行：

```bash
CORAL_GEMM_MIN_INFLIGHT=2 bash tests/cocotb/run_matrix_gemm_wave.sh \
  /tmp/coral_matrix_gemm_512_interleaved_wave
```

该门槛同时用于 CPU 发射未退休计数和 PE 控制器接收未完成计数，
两者测量区间不同，统计仍分别保留。以上脚本修改尚需完整仿真验证。

## 19. CPU ROB 扩为 48 项

2026-10-15，交错调度的完整基线已通过数值结果、退休计数和 AXI
检查：71,794 周期、467.371 logical MAC/cycle，MATMUL 实际接收
未完成峰值为 1。该数据对应 32 项 ROB，不代表以下 48 项配置的性能。

进一步读取该次波形发现，第一条 MATMUL 在 1116.25 ns 发射后，
随后 31 条指令在 1158.75 ns 前占满剩余 ROB。第二块 B 的数据和
scale LOAD 已经发射，并在 1268.75 ns 前全部完成；第一条 MATMUL
直到 1527.50 ns 才完成，第二条在 1551.25 ns 才发射。期间 MATMUL
ready 保持为高，ROB 无空槽阻止了 CPU 继续发射。

两条 MATMUL 之间实际发射了 40 条指令，其中矩阵 LOAD 两条、N
配置两条、标量指令 36 条。若第一条尚未完成，容纳首尾两条 MATMUL
及中间指令需要 42 项。按用户要求先将 ROB 从 32 扩为 48，后续
再减少软件热路径中的标量指令；容量足够不保证其它依赖和反压消失。

48 不是 2 的幂，因此配套修改如下：

- `CircularBufferMulti` 允许非 2 的幂容量。指针用扩位加法，结果
  大于等于容量时减去容量，再截取指针位宽。每拍增量不超过容量，
  因此一次条件减法足够，不引入通用除法器。
- `RetirementBuffer` 的 RVV 结果暂存读写指针、分项索引和 debug
  索引使用相同回绕规则，避免第 47 项后访问不存在的 48..63 项。
- ROB 空槽计数仍为 6 位，可表示 0..48；矩阵 scoreboard 保持 8
  项、RVVI trace 保持 16 路。SystemC 退休端口展开宏补齐到 48 项。
- 新增 48 项队列测试，覆盖指针 47 处整队列进出、同时进出、随机
  回绕和 flush；Decode 测试增加 47/48 个空槽边界。

本次不修改 MatrixCore、PE 控制器或软件 GEMM 发射顺序。原有名称
包含 `rob32` 的回归脚本仍读取当前源码参数，不会将容量设回 32。
先验证循环队列与 Decode，再运行原有标量/RVV/矩阵回归，最后用
独立目录保存 48 项大 GEMM 波形：

```bash
bazel test //hdl/chisel/src/common:circular_buffer_multi_test \
  --test_output=errors --nocache_test_results --test_timeout=900

bazel test //hdl/chisel/src/coralnpu:coralnpu_matrix_decode_tests \
  --test_output=errors --nocache_test_results --test_timeout=900

CORAL_GEMM_MIN_INFLIGHT=2 bash tests/cocotb/run_matrix_gemm_wave.sh \
  /tmp/coral_matrix_gemm_512_rob48_wave
```

当前已通过本次修改文件的差异空白检查，以及 48 项 C/C++ 端口展开宏
的静态编译检查。循环队列单元测试触发 Verilator 等依赖重建，按长
编译由用户执行的约定主动中止，尚未进入仿真，不记为通过或功能失败。
以上单测、Decode 和整核回归仍需执行。

48 项配置尚未完成整核回归及性能测量。比较接收未完成峰值、首几条
MATMUL 的接收间隔和整体 MAC/cycle，不能预先将 ROB 扩容等同于
性能目标已达成。

## 20. 固定寄存器与延后清零的性能实测

2026-10-15，固定 A0/B1/B2/B3 映射的 512x128x512 GEMM 在集中清零
时为 47,561 周期、705.503 logical MAC/cycle。将各 C 的首次清零移到
对应 B payload/scale load 之后、MMACC 之前后，完整波形用例通过，
为 43,207 周期、776.597 logical MAC/cycle。节省 4,354 周期，
吞吐提高约 10.08%，端到端逻辑吞吐为 1024 MAC/cycle 的 75.84%。
M=65、N=257、K=128 的正常访存和 AXI 背压用例也已通过。

该次完整 GEMM 检查了数值、完整内存镜像、AXI 事务和退休计数。
退休指令为 CONFIG=10、LOAD=320、MATMUL=128、MZERO=64、
STORE C=64；AXI 读 10,560 beat、写 16,384 beat。CPU 发射未退休
MATMUL 峰值与 PE 接收未完成峰值均为 3，128 条命令均接收并完成。

按 PE 激活行输入划分全部执行时间如下。空档指没有新激活行输入，
不表示整个 PE 阵列在这些周期内全部空闲；旧数据仍会继续经过流水线。

| 时间类别 | 集中清零 | 延后清零 |
|---|---:|---:|
| 激活行输入 | 32,768 | 32,768 |
| K 分块切换（16 次） | 16 x 266 = 4,256 | 16 x 266 = 4,256 |
| 同一 M 内切换 N 分组（8 次） | 8 x 648 = 5,184 | 8 x 276 = 2,208 |
| 切换 M 分块（7 次） | 7 x 648 = 4,536 | 7 x 451 = 3,157 |
| 启动与最终排空/写回 | 817 | 818 |
| 总周期 | 47,561 | 43,207 |

384 次内部 block 切换和 96 次组内 MATMUL 切换均没有激活输入空档，
包括第四个 N tile 复用 B1 的情况。因此本轮主要改善来自跨 C 分组时
下一组加载与上一组 store 的交叠，而不是提高在途峰值。

剩余 10,439 周期开销中，K 切换占 4,256 周期，N/M 分组切换占
5,365 周期，启动与收尾占 818 周期。首个 K 切换中，最后一条旧
MATMUL 于 1935.00 ns 完成，下一块 A0 load 于 1937.50 ns 接收，
B1 scale 于 2176.25 ns 完成并接收下一条 MATMUL，激活输入于
2221.25 ns 恢复。该处仍未提前装入下一 K 分块的 A。

M 切换还有额外等待：首个此类边界的 B1 scale 已于 7058.75 ns
完成，但下一条 MATMUL 到 7257.50 ns 才接收；上一组 C3 store 于
7255.00 ns 完成。两者接近不能单独证明因果，具体需继续核对 CPU
发射、ROB 和清零依赖，不能据此认定 C0 与 C3 存在寄存器冲突。

本轮产物位于 `/tmp/coral_matrix_gemm_512_deferred_zero_wave`，
其中 `gemm_metrics.json` 保存功能与吞吐结果，
`gemm_idle_breakdown.json` 保存激活输入空档及命令/DMA 事件时间。
这是当前主机上的分析产物路径，不是仓库内可移植的构建输入。

## 21. 每个 C 完成 K 累加后立即发射 STORE

2026-10-16，软件调度改为每个 C 的最后一条 MMACC 后直接发射自己的
STORE，不再等整个 N group 的四个 C 都发射完 MMACC 后集中 STORE。
完整 group、N 尾块以及 K 尾块都使用此规则。这里的“立即”指软件指令
顺序；硬件 scoreboard 仍会等待对应 MMACC 的结果就绪再允许 STORE。

例如 K=128 的最后一个 K tile 使用如下顺序：

```text
LOAD B3; MMACC C0, B3, A2; STORE C0
LOAD B0; MMACC C1, B0, A2; STORE C1
LOAD B1; MMACC C2, B1, A2; STORE C2
LOAD B3; MMACC C3, B3, A2; STORE C3
LOAD next A0
LOAD next B1
```

这里 LOAD 包含 payload 与 scale。下一组只预取启动所需的 A0/B1，
不在当前组 STORE C2/C3 前插入下一组 B2 加载：AB2 可能仍保存当前
组 A2，覆盖等待会在顺序发射核中挡住后续 STORE。

主机 schedule 测试已通过 252 组 M/N/K 组合，检查输出数值、地址、
指令数量，以及每个最终 MMACC 后的下一条矩阵指令必须是对应 STORE。
RV32 编译与反汇编也已确认最终 MMACC 与 STORE 的顺序。
主机模型不模拟硬件延迟，以上检查不能代替 RTL 仿真。

本次未修改 RTL。新调度的边界仿真结果及错误定位见下一节，性能尚未测量。
紧随 MMACC 的 STORE 可能等待结果并阻塞后续发射，因此不能预先认定
吞吐会提升。

## 22. 提前 STORE 调度暴露的 C 读写冲突

2026-10-16，M=65、N=257、K=128 的正常访存用例失败，复用已编译
Verilator 模型生成波形后复现。矩阵指令退休计数、AXI 读写事务、写入
范围均通过检查；最终仅输出第 256 列、第 0..3 行数值错误。

该尾 group 的硬件形状是 M=64、N=1、K=64；两条 MATMUL 分别完成
逻辑 K[0:63] 和 K[64:127] 的贡献，每条内部又分成两个 K=32 block。
第一条 MATMUL 的最后一个 block 首行激活请求在 4465.00 ns，第二条
MATMUL 的第一个 block 首行激活请求在 4546.25 ns，相隔 65 个时钟
周期，而前一 block 只有 64 行。因此两 block 之间有一拍输入空档。

波形中的实际 C0 冲突如下，时钟周期为 1.25 ns：

| 时间 ns | 第二条 MATMUL 读 C0 | 第一条 MATMUL 写 C0 | rd_accept_w |
|---|---:|---:|---:|
| 4586.25 | 行 0 | 行 60 | 0 |
| 4587.50 | 行 1 | 行 61 | 0 |
| 4588.75 | 行 2 | 行 62 | 0 |
| 4590.00 | 行 3 | 行 63 | 0 |

这些请求同时访问同一 C reg 的同一奇偶 bank。CMatrixReg 按写优先拒绝
读取，下一拍 rd_data_valid_i=0、rd_data_i=0。但 pe_ctrl 的累加有效位
仍使用 psum_valid，未因 C 读取失败而暂停或重试，因此这四行丢失旧 C。
第 4 行开始，上一条写回已结束，读取恢复。

| 输出位置 | 实际结果 | 正确结果 |
|---|---:|---:|
| [0][256] | 0.22216796875 | 0.215576171875 |
| [1][256] | 0.01806640625 | 0.0322265625 |
| [2][256] | -0.0380859375 | 0.05126953125 |
| [3][256] | -0.3232421875 | -0.315185546875 |

四个实际结果均恰好等于逻辑 K[64:127] 的贡献，缺少 K[0:63] 的贡献，
与波形中四次读请求被拒绝一致。错误发生于累加读取阶段，并非 STORE
读错数据，也不是 M/N/K 配置错误。

现有 stream_boundary_bubble_q 仅处理 stream_pop 与 stream_last 同拍、
且旧 M 为奇数的连续边界，不能覆盖本例 M=64 而实际出现一拍空档的
命令边界。软件指令重排改变了启动时刻，暴露了该 RTL 时序限制。

按照 RTL 修改前先讨论的约定，本轮停在定位阶段，没有修改 RTL，也未
插入软件等待绕过问题。后续方案需要在 block 首行启动前同时保证旧 C
数据已可用、重叠读写的 bank 相位正确；不能只按 M 的奇偶判断，也不能
仅屏蔽累加 valid 而丢弃对应点积。尚需讨论并验证具体实现。

诊断波形保存在 `/tmp/coral_gemm_early_store_failure.vcd`，事件摘录为
`/tmp/coral_gemm_early_store_events.txt`。这些是本机诊断产物。

## 23. Stream 期间接收后到权重并预装载

2026-10-16，按用户指定范围，仅补充 `pe_ctrl.sv` 的权重预装载功能，
不修改 C bank 冲突判断、边界 bubble 或最小启动间隔。

控制器处于 `Stream` 时，发现 weight FIFO 非空即取出下一块权重描述，
进入 `StreamPreloadWeight`。此时不取下一块 act/psum 描述，不重置当前
激活计数，不切换当前 A/C/尺寸参数。下一拍继续当前激活，并在权重
bank 有空位时开始从 AB reg 装权；bank 全忙时仅等待，不覆盖在用权重。

本次进入预装载只清除权重完成标志；激活完成标志记录进入当拍的
`stream_last`，覆盖新权重描述与当前最后一行同时到达的情况。当前
激活和新权重都完成后，才按原有交接路径取下一块 act/psum 描述。

新增四个控制器定向用例，分别检查权重提前就绪后无缝衔接、预装载
与当前末行同拍、激活结束后等待权重，以及两个权重 bank 均忙时延迟
装载。用例使用不同 C reg、每条命令 K=32，隔离 C 累加冲突；同时核对
激活/权重地址序列、逐元素输出和命令完成顺序。入口为：

```bash
bazel test //tests/cocotb:pe_ctrl_standalone \
  --test_output=errors --nocache_test_results --test_timeout=300
```

本功能可消除权重足够早到达时的额外装载空档；命令更晚到达或权重
装载更久时仍允许出现空档，不能视为第 22 节所述 C bank 问题的通用修复。

## 24. 连续预装载后暴露的 C 零标志同拍更新问题

2026-10-16，`matrix_cpu_dma_multicreg_c_api_elf_multicreg_m65_n257_k128`
集成测试仍失败，错误数量由原来的 4 个变为 64 个。日志列出的前 32 个
错误值都精确等于 K[64:127] 的贡献，缺少 K[0:63] 的贡献。

复用本次已编译模型抓取的波形为
`/tmp/coral_stream_prefetch_failure.vcd`，与第 22 节旧波形分别保存。
在 M=64、N=1 的命令边界，预装载功能实际执行如下：

| 时间 ns | 当前激活 | 下一块权重/状态 |
|---|---|---|
| 4540.00 | 读取第 60 行 | `begin_weight_prefetch=1`，只取权重描述 |
| 4541.25 | 读取第 61 行 | `StreamPreloadWeight`，发出一个权重行读请求 |
| 4543.75 | 读取第 63 行 | 激活与预装载均就绪，交接下一块 |
| 4545.00 | 读取下一块第 0 行 | 激活连续，无原先的一拍空档 |

失败直接发生于 C 零标志的同拍更新，而非本次边界的 C 读请求被拒绝：

| 时间 ns | 前一条 MATMUL | 下一条 MATMUL |
|---|---|---|
| 4583.75 | C0 最后一行读取，`c_reg_zero_release_valid_o=1`、mask=1 | `output_meta_pop=1`，准备锁存第一个 K32 block 的 C 读取参数 |
| 同一时钟沿前 | `c_reg_zero_n_i=4'b1110`，C0 零标志尚未解除 | `output_kblock=0`，零旁路判断仍使用旧标志 |
| 4585.00 | C0 零标志已解除，`c_reg_zero_n_i=4'b1111` | `rd_zero_block_q` 已锁成 1，第 0 行不发 C 读请求 |

修复前的逻辑在 `output_meta_pop` 时执行：

```systemverilog
rd_zero_block_q <= !c_reg_zero_n_i[output_rd[1:0]] && !output_kblock;
```

两个寄存器在同一个时钟沿更新时，此处采样的是更新前的值。因此虽然
C0 零标志在下一拍已经解除，整块零旁路仍保持为 1。波形逐行确认：
第二条 MATMUL 的第一个 K32 block 共 64 个有效行，全部
`rd_zero_block_q=1` 且 `rd_read_valid_o=0`。它覆盖了原有 C 内容；随后
第二个 K32 block 累加，最终只剩本条命令 K[64:127] 的贡献。

例如 C[0][256]：前 K64 为 -0.006591796875，后 K64 为 0.22216796875，
期望 0.215576171875，实际为 0.22216796875。

经确认后，已在 `pe_ctrl.sv` 的零旁路锁存处加入本拍解除信号的前递：

```systemverilog
rd_zero_block_q <= !output_kblock &&
                   !(c_reg_zero_n_i[output_rd[1:0]] ||
                     (c_reg_zero_release_valid_o &&
                      c_reg_zero_release_mask_o[output_rd[1:0]]));
```

当本拍解除的正好是下一块使用的 C reg 时，下一块按非零 C 处理，正常
读取已有部分和；解除其他 C reg 不影响该判断。这次修复不增加气泡，
不修改权重预装载状态机，也不替代一般性的 C bank 冲突保护。

新增 `pe_ctrl_same_cycle_c_zero_release` 定向用例：连续两条 M64/N1/K32
命令累加同一个 C0，按真实时钟沿更新外部零标志，要求实际命中同拍
解除与元数据锁存，并逐元素检查两条命令的累加结果。用例还检查 C
读写 bank 不冲突，以隔离本次修复的问题。

用户已确认以下定向测试和原失败集成用例均通过，验证了本次零标志
前递修复。反压用例与完整控制器回归仍需单独验证；这两项通过不表示
一般性的 C bank 冲突已解决。

```bash
bazel test //tests/cocotb:pe_ctrl_standalone_pe_ctrl_same_cycle_c_zero_release \
  --test_output=streamed --nocache_test_results --test_timeout=300

bazel test //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_m65_n257_k128 \
  --test_output=streamed --nocache_test_results --test_timeout=900
```

用户随后确认同场景的 `_backpressure` 用例也通过。

## 25. 提前 STORE 调度的性能实测与顺序发射阻塞

2026-10-16，零标志前递修复后的 512x128x512 波形测试通过，测得
47,490 周期、706.558 logical MAC/cycle。功能检查、矩阵指令数量、
AXI 读写 beat 数均通过；接收未完成 MATMUL 峰值仍为 3，上游
`cmd_valid_i && !cmd_ready_o` 为 0 周期。

此前 831.337 对应 40,362 周期，但两次软件指令调度不同，不能把此次
下降直接归因于零标志前递，也不能据此认定此前成绩依赖错误零旁路。
前递本身没有新增状态或气泡。当前软件在每个 C 的最终 MATMUL 后
紧跟 STORE；在顺序发射处理器中，STORE 仍要先通过矩阵 scoreboard
才能发射，无法提前排入 DMA 等待同一 C 的 MATMUL 完成。等待 STORE
会挡住后续无关 C 的 B 加载和 MATMUL。

首个最终 K tile 的实测事件如下：

| 时间 ns | 事件 |
|---|---|
| 1815.00 | 接收使用 A2/B3、累加 C0 的最终 MATMUL |
| 2285.00 | 该命令的最后一行激活输入 |
| 2332.50 | 该 MATMUL 完成，scoreboard 可释放 C0 写依赖 |
| 2335.00 | 接收 STORE C0 |
| 2338.75 | 接收下一块 B0 payload load |
| 2342.50 | 接收下一块 B0 scale load |
| 2458.75 | 接收使用 A2/B0、累加 C1 的 MATMUL |
| 2503.75 | 恢复下一条命令的激活输入 |

因此 2286.25 至 2503.75 ns 之间有 174 个没有新激活行输入的周期。
该现象在每个 group 的最终 K tile 重复三次，共 16x3=48 次。
此处“无激活输入”不表示 PE 内部所有流水级都已空闲。

| 时间类别 | 周期 |
|---|---:|
| 激活行输入 | 32,768 |
| 最终 K tile 的三次组内等待 | 48x174 = 8,352 |
| 同一 M 内切换 N group | 8x352 = 2,816 |
| 切换 M tile | 7x397 = 2,779 |
| 启动与最终排空/写回 | 775 |
| 合计 | 47,490 |

当前主要优化对象是 STORE 的发射位置与下一块计算的交叠。软件可先
发出下一块 B load 和 MATMUL，再尽早发出前一块已完成全部 K 累加
的 STORE，不必回到四个 C 全部完成才集中 STORE。若要求 STORE 指令
必须紧跟自己的最终 MATMUL 且后续指令还能继续发射，则需要另行设计
硬件端的 STORE 排队及依赖等待机制；单纯改软件顺序无法做到。

本次只记录分析，没有修改软件调度或 RTL。本机产物位于
`/tmp/coral_matrix_gemm_512_zero_forward_wave`，其中
`gemm_perf_trace.json` 保存本次全波形抽取的激活输入区间及命令事件。

## 26. 下一块 B 加载提前到前一块 C 的 STORE 之前

按本次讨论，已修改 `include/coral_matrix_gemm.h` 的完整四块 N group
软件调度，不修改 RTL。只提前下一块 B 的 payload 和 scale 加载，
尚未把下一条 MATMUL 提前到 STORE 之前。

对于 512x128x512，每个 group 的最后一个 K tile 使用 A2，顺序为：

```text
LOAD B3 payload + scale
MATMUL A2, B3 -> C0
LOAD B0 payload + scale
STORE C0
MATMUL A2, B0 -> C1
LOAD B1 payload + scale
STORE C1
MATMUL A2, B1 -> C2
LOAD B3 payload + scale
STORE C2
MATMUL A2, B3 -> C3
STORE C3
```

这样，等待 C0 可读之前，独立的 B0 加载已经有机会发射，不再被
STORE C0 的 scoreboard 等待挡在后面。加载是否立即执行仍由 AB
寄存器依赖和 DMA 资源决定；例如第四块复用 B3，仍需硬件确保旧的
B3 使用已结束。STORE 仍可能阻塞其后的 MATMUL，因此不能预先保证
消除全部激活输入空档，性能需要重新测量。

该顺序同时用于最终 K tile 为偶数相位的完整四块 group。少于四块、
或含 N 尾块的 group 保持每块最终 MATMUL 后直接 STORE，避免下一块
改变 N 后使用错误的 STORE 维度。K 尾块仍使用既有补齐和维度规则。

主机调度模型检查覆盖 252 组 M/N/K：逐元素结果、输出 padding、
矩阵指令数量均通过；每个完整四块 group 要求恰好三次 B payload
及 scale 在前一块 C STORE 之前，且中间不允许插入下一条 MATMUL
或维度修改。该模型不模拟 RTL 时序，硬件仿真和性能实测待用户运行。

随后用户运行通过，512x128x512 实测为 42,690 周期、786.002 logical
MAC/cycle，比第 25 节减少 4,800 周期。波形显示最终 K tile 的组内
空档由每次 174 周期降到 74 周期，共 48 次；N/M tile 切换空档仍分别
为 8x352 和 7x397 周期。产物位于
`/tmp/coral_matrix_gemm_512_load_before_store_wave`。

## 27. 下一条 MATMUL 也提前到前一块 C 的 STORE 之前

在第 26 节的基础上，完整四块 N group 的最终 K tile 现在使用：

```text
LOAD B3 payload + scale
MATMUL A2, B3 -> C0
LOAD B0 payload + scale
MATMUL A2, B0 -> C1
STORE C0
LOAD B1 payload + scale
MATMUL A2, B1 -> C2
STORE C1
LOAD B3 payload + scale
MATMUL A2, B3 -> C3
STORE C2
STORE C3
```

STORE C0 等待 C0 完成时，C1 的 MATMUL 已先提交，有机会与该等待
重叠。STORE 仍逐块发出，没有集中等到四条 MATMUL 全部提交。
第四块复用 B3 的依赖仍由 scoreboard 保护。软件不插入等待指令，
不修改 RTL；也不能据此保证计算和 DMA 没有其他等待。

偶数 K 相位也应用相同顺序。若 K 只有一个 tile，下一块 C 的 MZERO
在其 MATMUL 前执行，清零的 C 与等待 STORE 的前一块 C 不同。
少于四块或含 N 尾块的 group 保持既有逐块 STORE，K 尾块规则不变。

主机调度模型允许最多两个完成 K 累加、尚未 STORE 的 C tile，要求
按顺序写回；每次提前加载 B 后，必须提交对应下一块 MATMUL 才能
STORE 前一块 C，禁止在此期间更改维度。继续检查 252 组维度的
逐元素结果、padding 和矩阵指令数量，252 组均通过。512x128x512 与
M65/N257/K128 程序的 RV32 编译通过，反汇编确认下一条 MATMUL
位于前一块 STORE 之前。新顺序的 RTL 仿真和性能待测。

用户随后运行性能测试通过，结果校验 `verified=true`，实测 39,138
周期、857.336 logical MAC/cycle，比第 26 节提升约 9.08%，减少
3,552 周期。128 条 MATMUL 的在途峰值仍为 3，矩阵指令数量与
AXI 读写 beat 数保持一致。

全波形抽取确认，每个 N group 的两个 K tile、共 8 条 MATMUL，激活
输入连续 2,048 周期，共 16 段；此前 48 次、每次 74 周期的组内
空档全部消除。这里连续指激活输入，不表示命令接收没有间隔。

| 时间类别 | 周期 |
|---|---:|
| 激活行输入 | 32,768 |
| 同一 M 内切换 N group | 8x352 = 2,816 |
| 切换 M tile | 7x397 = 2,779 |
| 启动与最终排空/写回 | 775 |
| 合计 | 39,138 |

目前主要剩余空档位于 group 边界。首个边界：最后一条 MATMUL 在
3,292.5 ns 完成，STORE C3 于 3,295 ns 接收；下一组 A0 payload
到 3,317.5 ns 才接收，B1 payload 到 3,330 ns 才接收。下一组首条
MATMUL 于 3,641.25 ns 接收，激活于 3,686.25 ns 恢复。下一步应
检查把下一组 A/B 预取提前到最后几条 STORE 之前的可行性，以及
新组 MZERO 与旧组 STORE 的依赖。M 尾块还需确保 LOAD/STORE 各自
捕获正确维度。此处仅记录后续方向，尚未改动跨组调度。

本次产物位于 `/tmp/coral_matrix_gemm_512_matmul_before_store_wave`，
`gemm_perf_trace.json` 保存激活输入区间及命令事件。

## 28. 跨组 A0/B1 预取提前到最后两条 STORE 前

本次继续只修改软件。当前组和下一组都包含完整四块 N tile、K 没有
尾块且最终 K tile 使用 A2 时，在提交最终 C3 MATMUL 后预取下一组
A0/B1，再发出当前组 STORE C2/C3。512x128x512 的每个适用边界为：

```text
MATMUL A2, B1 -> C2
STORE C1
LOAD current B3 payload + scale
MATMUL A2, B3 -> C3
LOAD next A0 payload + scale
LOAD next B1 payload + scale
STORE C2
STORE C3
# 下一组复用上述加载，不重复加载 A0/B1
MZERO C0
MATMUL A0, B1 -> C0
...
```

此时当前组已提交所有 MATMUL，后续不再使用 AB0/AB1。硬件 scoreboard
仍需等待 AB0 的旧 B0/C1 和 AB1 的旧 B1/C2 使用结束，软件没有跳过
依赖保护。AB2 中的 A2 保留给最后的 C3 计算。相较旧顺序，A0/B1
的加载有机会在 C3 计算期间执行，而非等待 STORE C3 发射后才开始。

若下一组 M 行数变化（例如 M65 的第二个 M tile 只有一行），仅 B1
及其 scale 提前；先发出旧的 STORE C2/C3，之后设置新 M 并加载 A0。
B 加载使用 N/K，不依赖 M；旧 STORE 则始终使用旧 M。跨两个同样
大小的 M tile 可以同时提前 A0/B1，既有 M 配置指令仍留在旧 STORE
之后。MZERO C0 仍由 scoreboard 等待旧 STORE C0 完成。

最终 K tile 使用 A0 时，下一组 A0/B1 与最后 C3 使用的寄存器重叠，
本次保留 STORE 后的预取。K 尾块、下一组不足四块或含 N 尾块时也
保持原路径。因此该优化不保证覆盖所有维度的组边界。

主机调度模型扩展到 336 组维度（新增 M128，覆盖相邻完整 M tile），
逐元素结果、padding、指令数量和跨组提前加载次数均通过。RV32
编译及反汇编顺序检查通过。新增以下 RTL 集成验证目标，待用户运行：

- `matrix_cpu_dma_gemm_any_c_api_elf_gemm_m3_n512_k128`：同一 M 内切组。
- `matrix_cpu_dma_gemm_any_c_api_elf_gemm_m65_n256_k128`：跨到一行 M 尾块。
- `matrix_cpu_dma_gemm_any_c_api_elf_gemm_m65_n256_k128_backpressure`：上述尾块及 AXI 反压。

性能测试仍使用 `run_matrix_gemm_wave.sh`，建议产物目录
`/tmp/coral_matrix_gemm_512_cross_group_prefetch_wave`，与 857.336
logical MAC/cycle 比较。新顺序的 RTL 功能和性能尚未确认。

## 29. A2 提前加载实验结论

曾尝试在完整四块 N group、K 为 128 的路径中，将偶数阶段的 A2
加载提前到 B2/C1 之后：

```text
MATMUL A0, B1 -> C0
MATMUL A0, B2 -> C1
LOAD A2 payload + scale
MATMUL A0, B3 -> C2
MATMUL A0, B1 -> C3
MATMUL A2, B3 -> C0
...
```

主机模型和编译检查都可以接受这个顺序，但 RTL 波形表明 A load
进行期间，后续独立的 MATMUL 也不能继续接收。A2 提前版的 MATMUL
间隔由约 101/106 周期增加到 671/672 周期，未退休 MATMUL 峰值从
3 降为 2，性能从 899.583 降到 807.451 logical MAC/cycle。

因此该重排已经撤销。当前软件继续在四条偶数阶段 MATMUL 提交后
加载 A2，优先保证后续 MATMUL 的发射。仅凭该实验不能认定必须增加
硬件缓冲：A2 与 B2 共用 AB2，提前覆盖需要等待 scoreboard 释放旧
使用者，而顺序发射会把这个等待传给后面的指令。后续应先核对完整
软件顺序与波形，区分寄存器依赖、DMA 排队和命令接收等待。

## 30. 恢复最终奇数 K tile 的跨组预取位置

2026-10-17，单独把偶数阶段的 A2 load 移回 C3 MATMUL 后，完整波形
测试仍为 40,922 周期、819.961 logical MAC/cycle，数值检查通过。
新旧波形的首组 C3 接收时间由 1420.00 ns 提前到 1211.25 ns，但首组
奇数阶段 C0 仍在 1851.25 ns 接收，整段执行周期没有减少。因此不能
把移动 A2 等同于已经恢复历史上 899.583 的完整软件顺序。

恢复后的波形为 `/tmp/coral_matrix_gemm_512_restore_899_wave/`。
其首组最终 K tile 的指令发射顺序仍有以下跨组阻塞：

| 时间 ns | 发射事件 |
|---|---|
| 2171.25 | 当前 MMACC C1，使用 A2/B0 |
| 2368.75 | STORE C0 |
| 2372.50 / 2376.25 | 当前 B1 payload / scale load |
| 2380.00 / 2383.75 | 当前 B3 payload / scale load |
| 2688.75 / 2695.00 | 下一组 A0 payload / scale load |
| 2697.50 | 当前 MMACC C2，使用 A2/B1 |
| 3108.75 / 3113.75 | 下一组 B1 payload / scale load |
| 3118.75 | STORE C1 |
| 3120.00 | 当前 MMACC C3，使用 A2/B3 |

下一组 A0 覆盖当前 C1 使用的 AB0，下一组 B1 覆盖当前 C2 使用的
AB1。scoreboard 按命令完成释放读依赖；把这些覆盖 load 放在当前
C2/C3 前面，会让顺序发射停在 load 上。寄存器容量与四个 N tile
的分组本身不是这两处等待的原因。第四块 B 也不能在第一块仍未使用
时提前覆盖同一个寄存器，不能把调度改成先装好四块 B 再计算。

本次只恢复软件中最终奇数 K tile 的顺序，与第 28 节记录一致：

```text
LOAD B3; MMACC A2, B3 -> C0
LOAD B0; MMACC A2, B0 -> C1
STORE C0
LOAD B1; MMACC A2, B1 -> C2
STORE C1
LOAD B3; MMACC A2, B3 -> C3
LOAD next A0  # 仅下一组形状允许时提前
LOAD next B1
STORE C2
STORE C3
```

仍保留四个 C tile、A0/A2 轮换、B 的复用和硬件依赖检查。下一组不足
四块、K 有尾块时仍走原有通用路径；M 行数变化时 A0 load 保留在旧
STORE 及新 M 配置之后。非最终奇数 K tile 的组内 lookahead 不在
此次恢复范围内。没有修改 RTL。

主机调度模型的 336 组维度已通过，覆盖输出值、padding、指令数量，
以及下一组预取不得出现在当前 C2/C3 MATMUL 之前的顺序约束。
512x128x512 程序的 Bazel RV32 编译已通过；反汇编确认最终奇数
阶段 C2/C3 MATMUL 分别在 PC 0x310/0x33c，下一组 A0/B1 的预取在
0x33c 后的分支路径中，随后才发 STORE C2/C3。PC 仅用于定位本次
构建，后续编译可能变化。
主机模型不模拟硬件等待；本次修改后的 RTL 功能与性能仍需重新测量，
不能预先承诺恢复到 899.583。性能复测命令：

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_matrix_gemm_wave.sh \
  /tmp/coral_matrix_gemm_512_restore_group_order_wave
```

## 31. 899.703 基线复测和输入空档定位

2026-10-18，恢复后的完整波形测试结果校验通过，耗时 37295 周期，
性能为 899.7032309961121 logical MAC/cycle。实际接收未完成 MATMUL
峰值为 3，128 条命令全部完成，512 对 block 描述符计数一致。

本轮最新日志确认 `n65`、`m65_n257_k128` 和反压版本通过；
`n129/n255/n257` 可见日志仍为 2026-10-16 的历史结果，不能算本轮复测。

波形分析发现每个 N group 内连续输入 2048 拍激活，包含两轮 K tile，
没有组内断流。主要输入空档在分组边界：同一 M tile 换 N group
通常为 124 拍，换 M tile 为 394 拍。下一组 A/B 已完成预取，M 边界
的长等待中存在 208 拍 ROB 满；旧 STORE C3 完成后才恢复标量发射。

详细时间表、统计口径和不重跑仿真的分析命令见
[899.703 MAC/cycle 波形分析](matrix_gemm_899_performance.md)。
本次只更新分析脚本、脚本单元测试和文档，没有修改 GEMM 调度或 RTL。

## 32. ROB 64 项对比配置和性能结果

2026-10-18，按用户要求将 `Parameters.retirementBufferSize` 从 48 改为
64，用于观察第 31 节 M tile 边界的 ROB 满等待能否缩短。GEMM 软件
顺序不变，矩阵 scoreboard 仍为 8 项，RVVI trace 仍为 16 路。

循环队列和 RVV 结果暂存使用的指针均按 ROB 容量计算。48 和 64 项
的指针都是 6 位；保存 0..64 的占用计数为 7 位。已有 advance 函数
在容量为 64 时采用低 6 位回绕，无需修改回绕逻辑。队列模型测试
同时覆盖 48/64 项的满容量、回绕、同时入出队、随机流量和 flush。
同时补齐 Verilator C++ 测试端的 `REPEAT_49..REPEAT_64`，保证 ROB
debug 端口绑定和退休指令监测能够覆盖新增的槽位。

64 项配置的 512x128x512 波形用例已通过功能和命令握手校验，性能为
901.710 MAC/cycle、37212 周期，相比 48 项的 37295 周期节省 83 拍。
换 M tile 的空档由 394 降为 384 拍，每次 ROB 满等待由 208 降为
198 拍，满时 PC 从 0x568 移至 0x5a8，仍需等待旧 STORE C3 完成。
同一 M tile 的 N group 间隔和组内连续输入保持不变，在途峰值仍为 3。
详见[ROB 对比分析](matrix_gemm_899_performance.md#rob-64-项对比结果)。
完整 Scala/标量/RVV 回归状态仍需单独确认；本例不能代替全部回归。
更大 ROB 只能增加可越过长延迟指令发射的指令窗口，不会消除寄存器
依赖或顺序发射阻塞。
面积、功耗和目标 28nm/500MHz 时序需要后续综合数据确认。

以下命令逐条运行；先确认前面的功能检查通过，再测性能。这里不限制
Bazel 构建 jobs，测试进程限制为一个。

```bash
cd /home/wjj/2-NPU/coralnpu
test_args=(--local_test_jobs=1 --test_output=errors --nocache_test_results --test_timeout=900)

bazel test //hdl/chisel/src/common:circular_buffer_multi_test "${test_args[@]}"
bazel test //hdl/chisel/src/coralnpu:coralnpu_scalar_tests "${test_args[@]}"
bazel test //hdl/chisel/src/coralnpu:coralnpu_rvv_tests "${test_args[@]}"
bazel test //hdl/chisel/src/coralnpu:coralnpu_matrix_decode_tests "${test_args[@]}"
bazel test //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_m65_n257_k128 "${test_args[@]}"
bazel test //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_m65_n257_k128_backpressure "${test_args[@]}"

bash tests/cocotb/run_matrix_gemm_wave.sh /tmp/coral_matrix_gemm_512_rob64_wave
```

## 33. 压缩跨 M tile 的标量准备

2026-10-18，在 ROB 64 项、901.710 MAC/cycle 基线上，只调整
`include/coral_matrix_gemm.h` 的软件遍历，不修改 RTL 或矩阵指令顺序。

原来每个 M tile 都重新进入一个 N 循环。性能用例使用的 GCC 15.1、
`-O1` 编译结果在 M 边界重新建立 B 地址和部分常量，产生较多栈读写。
现在改为一个分组循环，N 方向走完后将 n0 归零并推进 m0，继续使用
同一入口。完整 M tile、完整 N tile 和完整四 C 分组的条件在循环外
计算，让编译器消除完整尺寸下不需要的尾块判断。

```text
m0 = 0; n0 = 0
while m0 < M:
    tile_m = min(M - m0, 64)
    if n0 == 0 and 下一 M tile 的 M 尚未设置:
        set_tile_m(tile_m)
    按原顺序计算本 N group 的各 K tile
    按原顺序预取下一组 A0/B1，并发射余下 C store
    n0 += min(N - n0, 256)
    if n0 == N:
        n0 = 0
        m0 += tile_m
```

偶数 K tile 仍为 A0 + B1/B2/B3/B1，奇数 K tile 仍为
A2 + B3/B0/B1/B3。下一组 A0/B1 仍在当前 C3 MATMUL 之后、
STORE C2/C3 之前预取；M 尾块需要改变行数时，仍先发射旧 C store，
再设置新 M 并加载较短 A。当前和下一组行数相同时，下一组 C0 也可
在旧 STORE C2/C3 前发射；行数变化时仍保留保守顺序。

512x128x512 用例用现有 RV32 GCC、`-O1` 编译前后，按标量控制流
跟踪得到以下结果。这些是发射指令数量，不是硬件周期：

| 指标 | 修改前 | 修改后 |
|---|---:|---:|
| main 栈帧 | 112 字节 | 48 字节 |
| 跨 M：STORE C3 与下一 MATMUL 之间的标量指令 | 94 | 32 |
| 上述区间内栈读写 | 18 | 0 |
| 同一 M 内换 N group 的上述标量指令（通常） | 33 | 28 |
| 整个 main 执行的标量指令 | 2291 | 2241 |
| 整个 main 栈写 / 栈读 | 117 / 165 | 12 / 12 |

全部 579 条矩阵指令的编码、顺序、DMA 基址、stride 和 CONFIG 值
与修改前一致。总标量条数只小幅下降，因为编译器也重新安排了组内
的地址计算；不能把边界少掉的 62 条指令当作每组净节省或周期收益。

主机调度模型已通过 347 种尺寸，覆盖输出、padding、指令数量、
寄存器映射、预取和尾块维度。新增 M192/M193 与 N64/128/192/256/512
组合，以及原始 512x128x512 用例。主机布局检查也通过。
512x128x512 硬件波形仿真已通过功能和命令握手校验，实测
951.035 MAC/cycle、35282 周期。与同为 ROB 64 项的上一轮相比，
减少 1930 周期、吞吐提升约 5.47%，达到 1024 MAC/cycle 峰值的
92.87%。本次未观测到 CPU 队头 ROB 满停顿；该结论仅对应本次用例。

| 指标 | 优化前 | 优化后 |
|---|---:|---:|
| 同一 M tile 换 N group 的输入空档（通常） | 124 拍 | 117 拍 |
| 最后一次同 M 的 N group 切换 | 128 拍 | 109 拍 |
| 换 M tile 的输入空档 | 384 拍 | 125 拍 |
| 首次激活前 | 446 拍 | 398 拍 |
| 最后激活结束到 halted | 314 拍 | 313 拍 |
| 全程 CPU 队头 ROB 满计数 | 1386 拍 | 0 拍 |

全部 16 个 N group 内仍各连续输入 2048 拍激活，组内无断流。
128 条 MATMUL 全部接收并完成，在途峰值仍为 3，AXI 读写量不变。
余下通常的分组输入空档为：等待旧 C3 完成并发射 STORE C3 37 拍，
STORE C3 到下一 MATMUL 接收 44 拍（换 M 时 52 拍），然后启动
下一组激活 36 拍，包含 32 拍 PE 装权。这些输入空档不能全解释为
所有 PE 闲置。上述周期数据对应 951.035 基线；随后提前下一组
C0 的调度结果见下文，不能与这一基线混用。

主机模型已覆盖该扩展：当跨 M 后 `tile_m` 不变时，检查下一组 C0
确实在旧 C2/C3 STORE 前发射；较短 M 尾块则检查先写回再改变
`msettilem`。这一扩展不改变矩阵指令总数。

等行数跨 M 的扩展已通过 512x128x512 硬件输出和命令握手校验，
实测 1002.223 MAC/cycle、33480 周期。512 个内部 block 连续
输入，相邻起点全部间隔 64 拍，跨 M 和同 M 换 N group 都无输入
空档。总周期为 399 拍启动、32768 拍连续输入和 313 拍收尾。
这是端到端吞吐达到峰值的 97.87%，不是所有 PE 占用率的直接测量。
本次大矩阵结果不替代尾块和反压测试。详细结果见
[1002.223 性能记录](matrix_gemm_899_performance.md#等行数跨-m-提前-c0-后的-1002223-结果)。

波形和分析产物位于 `/tmp/coral_matrix_gemm_512_flat_group_wave/`。
详细对比见[软件循环优化结果](matrix_gemm_899_performance.md#软件循环优化后的-951035-结果)。

下面命令逐条运行，功能测试失败时先停止：

```bash
cd /home/wjj/2-NPU/coralnpu
bazel test //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_m65_n257_k128 \
  --test_output=errors --nocache_test_results --test_timeout=900
```

```bash
bazel test //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_m65_n257_k128_backpressure \
  --test_output=errors --nocache_test_results --test_timeout=900
```

```bash
bash tests/cocotb/run_matrix_gemm_wave.sh \
  /tmp/coral_matrix_gemm_512_flat_group_wave
```
