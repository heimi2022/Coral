# Coral Matrix Gather 与 MIDX0 设计提案

状态：设计提案，尚未修改 RTL、编译器或正式矩阵扩展规范。

## 1. 目标

为每行起始地址不同、但行内元素连续的 Tile 增加矩阵侧索引加载能力。目标地址为：

```text
address(i, j) = base + row_offset[i] + j * element_bytes
```

适用场景包括 Expert/Token Buffer 等不规则布局。现有使用统一行 stride 的矩阵加载指令无法描述这种地址模式。

第一版不包含元素级 mask，当前 Tile 形状内的元素都必须有效。尾块由 `msettilem`、`msettilek` 和 `msettilen` 配置处理。

## 2. 架构状态：MIDX0

增加一个矩阵侧行偏移寄存器 `MIDX0`。每项是有符号 64 位字节偏移：

```text
MIDX0[i] = row_base[i] - base
```

寄存器项数必须覆盖实现支持的最大 Tile 行数。例如，4 行需要 256 bit，8 行需要 512 bit。A 操作使用 `mtilem` 项，B 操作使用 `mtilen` 项。

现有 `tr0`-`tr3` 继续保存 A/B Tile，`acc0`-`acc3` 继续保存 C Tile。`MIDX0` 独立于 AB Reg，不占用矩阵计算寄存器。

## 3. 指令定义

本提案复用现有 32 位 custom-1 矩阵 Load/Store 格式。新增操作均为 load，要求 `ls=0`、`func3=000`、`rs2=0`。

### 3.1 加载行偏移

```asm
mldidx.a (rs1)       # 加载 mtilem 个 64 位偏移到 MIDX0
mldidx.b (rs1)       # 加载 mtilen 个 64 位偏移到 MIDX0
```

`rs1` 指向连续存放的有符号 64 位字节偏移数组：

```text
for i in [0, row_count):
    MIDX0[i] = signed_load64(rs1 + i * 8)
```

`mldidx.a` 的 `row_count=mtilem`，`mldidx.b` 的 `row_count=mtilen`。偏移数组是连续访问，可走常规 MatrixCore/TCM 读路径；`mldidx` 本身不执行 gather。

### 3.2 Gather A/B Tile

```asm
mgather.a.u8  md, (rs1)
mgather.a.u16 md, (rs1)
mgather.a.u32 md, (rs1)
mgather.a.u64 md, (rs1)
mgather.b.u8  md, (rs1)
mgather.b.u16 md, (rs1)
mgather.b.u32 md, (rs1)
mgather.b.u64 md, (rs1)
```

`md` 选择 `tr0`-`tr3`，`rs1` 是共享数据基地址。A gather 读取 `mtilem x mtilek`；B gather 读取 `mtilen x mtilek`。地址计算为：

```text
A[i][j] 地址 = x[rs1] + MIDX0[i] + j * element_bytes
B[i][j] 地址 = x[rs1] + MIDX0[i] + j * element_bytes
```

读取结果按照现有 A/B Tile 布局写入目标矩阵寄存器。B 内存布局仍遵循现有转置 B 约定：按 `[N][K]` 存放，每行 K 个元素连续。

第一版不支持 C gather/scatter；C 继续使用现有规则 Store 指令。

## 4. 暂定 32 位编码

现有 Load/Store 格式：

```text
31:28 func4 | 27:26 uop | 25 ls | 24:20 rs2 | 19:15 rs1 |
14:12 func3 | 11:10 d_size | 9:7 md/ms3 | 6:0 custom-1 opcode
```

以下编码仅为暂定，定稿前须核对已分配和预留编码：

| 指令 | `func4` | `uop` | `ls` | `d_size` | `md` | `rs2` |
|---|---:|---:|---:|---:|---|---|
| `mldidx.a` | `0111` | `01` | `0` | `11` | `000` | `00000` |
| `mldidx.b` | `1000` | `01` | `0` | `11` | `000` | `00000` |
| `mgather.a` | `1001` | `01` | `0` | 元素宽度 | `tr0`-`tr3` | `00000` |
| `mgather.b` | `1010` | `01` | `0` | 元素宽度 | `tr0`-`tr3` | `00000` |

对 `mldidx`，`d_size=11` 表示偏移固定为 64 bit；对 `mgather`，`d_size` 沿用现有 8/16/32/64 位元素宽度编码。`func4` 具体取值尚未定稿。

## 5. MIDX0 快照与依赖

单个 MIDX0 能够复用的前提是：gather 在 MIDX0 被覆盖前捕获当前偏移。

当 `MGATHER` 被 MatrixCore 命令队列接收时，硬件把当前有效的 MIDX0 项复制到该命令描述符。后续 gather 使用描述符副本，不再读取实时 MIDX0。这样可连续复用寄存器：

```asm
mldidx.a       (a_offsets)
mgather.a.u8   tr0, (a_base)     # 捕获本条命令的 MIDX0
mldidx.b       (b_offsets)       # 此时可覆盖 MIDX0
mgather.b.u8   tr1, (b_base)     # 捕获新的 MIDX0
```

Scoreboard 必须保证 `MLDIDX -> MGATHER`。前一条 `mldidx` 完成前不能有后一条 `mldidx` 覆盖 MIDX0。`mgather` 对 MIDX0 的依赖只持续到偏移复制完成；复制后即可复用。

若硬件无法在命令接收时快照 MIDX0，也可将其保持占用直到 gather 退休，但这会限制命令重叠，不推荐。

MatrixCore 命令描述符需要索引快照字段：

```text
gather command = { 类型, 目标寄存器, 基地址, 元素宽度, 行偏移 }
```

只保存当前命令实际使用的行偏移，不保存完整的逐元素地址表。

## 6. Tile 维度与尾块

有效 Tile 维度仍由以下配置决定：

```asm
msettilem  actual_m
msettilek  actual_k
msettilen  actual_n
```

```text
A gather: 行数 = mtilem，列数 = mtilek
B gather: 行数 = mtilen，列数 = mtilek
```

没有 mask 时，尾块必须使用实际维度，或由软件补齐到支持的完整 Tile 形状。硬件不得读取有效维度以外的元素。

## 7. 软件使用示例

假设行起始地址为 `0x2000`、`0x5000`、`0x9000`、`0xc000`。选择共享基地址 `0x1000` 后，偏移数组为：

```text
base = 0x1000
offsets = { 0x1000, 0x4000, 0x8000, 0xb000 }
```

A Tile：

```asm
# x10 -> offsets[]；x11 = 共享数据基地址
msettilem  4
msettilek  32
mldidx.a   (x10)
mgather.a.u8 tr0, (x11)
```

B Tile：

```asm
# x12 -> B 行偏移数组；x13 = B 的共享数据基地址
msettilen  4
mldidx.b   (x12)
mgather.b.u8 tr1, (x13)
```

之后可使用普通矩阵运算指令：

```asm
mmacc.w.b acc0, tr0, tr1
```

第一版可提供如下 intrinsic：

```c
coral_mldidx_a(row_offsets);
coral_mgather_a_u8(tr0, base);
coral_mldidx_b(row_offsets);
coral_mgather_b_u8(tr1, base);
```

应在指令语义和 RTL 行为稳定后再加入编译器、汇编器支持。

## 8. TCM 与存储器要求

### 8.1 MIDX0 加载

偏移数组连续存储。4 个 64 位偏移共 256 bit，256 bit TCM 读端口可在一个数据 beat 中填满 MIDX0。8 项共 512 bit，512 bit 端口一个 beat 可完成，256 bit 端口需要两个 beat。

`mldidx` 的 TCM 路径需要按字节寻址、至少 64 位数据支持、对齐连续读取、将响应写入 MIDX0，并检查偏移数组的访问范围。加载偏移数组本身不需要任意地址读取能力。

### 8.2 Gather 矩阵数据

若 `mgather` 从 TCM 读取矩阵数据，TCM 必须处理多个不同的行起始地址。建议使用多 bank TCM，使不同的行能够并行读取。单端口 TCM 在功能上可行，但可能串行处理各行、降低性能。

第一版功能实现可以使用现有 MatrixCore 存储器路径；预期的高性能路径为：

```text
DDR DMA -> TCM/Tile Buffer -> MGATHER -> AB Reg
```

这样可避免每次不规则行访问都成为一次随机 DDR 访问。

## 9. 异常与对齐

没有 mask 时，当前 Tile 形状内的元素均有效。第一版建议每个有效地址按元素宽度自然对齐；未对齐或不可访问地址遵循现有矩阵内存指令的异常策略。

RTL 实现前，正式规范还需明确：

* 访问异常时目标 AB Reg 是否保持不变；
* 偏移是否必须为有符号，或允许无符号；
* 地址按 XLEN 回绕，还是溢出时产生异常；
* `mtilem` 和 `mtilen` 的最大支持值。

建议采用有符号 64 位字节偏移，并在异常时整体不更新目标寄存器。该建议仍需结合现有 MatrixCore 存储器接口确认。

## 10. 实现与验证计划

### 阶段一：架构定义

1. 进行矩阵 ISA 设计评审。
2. 确定最大行偏移数和 MIDX0 宽度。
3. 确定最终编码与异常行为。
4. 增加汇编器/反汇编器编码测试。

### 阶段二：RTL 功能路径

1. 在 MatrixCore 状态中增加 MIDX0。
2. 解码 `mldidx.a/b` 并实现连续偏移加载。
3. 解码 `mgather.a/b` 并生成 `row_base + column_offset` 地址。
4. 在 gather 命令入队时快照 MIDX0。
5. 增加 MIDX0 和 AB Reg 目标寄存器的 scoreboard 依赖。

### 阶段三：验证

1. 测试 4 行起始地址不同、但行内连续的数据。
2. 覆盖 A/B gather 的 8/16/32/64 位宽度。
3. 覆盖 `msettile*` 配置的 A/B 尾块。
4. 测试 gather 入队后立即覆盖 MIDX0。
5. 测试多条 gather 在途时的反压。
6. 测试未对齐访问与存储器异常。
7. 执行 gather 加载后矩阵乘法，并与软件参考结果比较。

## 11. 当前提案的决定

* 第一版没有元素级 mask。
* 增加一个矩阵专用索引寄存器 `MIDX0`，每行保存一个有符号 64 位偏移。
* 行内连续地址由硬件生成。
* `MGATHER` 入 MatrixCore 命令队列时快照 MIDX0。
* A 使用 `mtilem` 个偏移，B 使用 `mtilen` 个偏移。
* 第一版仅支持 A/B gather；C 继续使用现有规则 Store。
* 本提案不包含 RTL、编译器、汇编器或正式规范修改。
