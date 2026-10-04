# Matrix ISA 编码基线

更新时间：2026-10-01

本文是工具链接入计划第一步的核对结果。当前编码以 CoralNPU RTL 的实际
解码行为为规范基线，参考 spec 文档和参考实现位于
`tests/toolchain/matrix_encode_reference.py`。

## 结论

截至 2026-10-01，玄铁 release `v0.3.0` 的预构建工具链已经完成实测。
工具链压缩包的 MD5 为 `15e6fe82825664494310a1a671b73d6a`，与
`riscv-matrix-extension-spec/demos/env.sh` 中的记录一致。工具链版本为
GCC 10.2.0、Binutils 2.35，版本字符串为
`Xuantie-900 ... V2.6.1-matrix-0.3`。

实测结果表明，该 release 不是当前 `instruction_list.adoc` 所描述 ISA
的另一种助记符写法，而是另一套较早/不同版本的 T-Head Matrix ISA：

| 项目 | 实测结果 |
| --- | --- |
| 配置助记符 | `mcfgm`、`mcfgn`、`mcfgk`，不是 `msettilemi` 等 |
| 清零助记符 | `mzero m4`，机器码为 `0xa002002b` |
| 乘法助记符 | `mmaqa.b`、`mmaqau.b` 等，不是 `mmacc.w.b` |
| 访存助记符 | `mldb`、`mld1mb`、`mst1mw` 等，不是 `mlce32` 等 |
| 架构选项 | `-march=rv64g_xtheadmatrix` |

例如该工具链生成的机器码字段如下。字段列仅使用通用位切片帮助定位
差异，不表示这些指令可以按当前 spec 的字段语义解码：

```text
mrelease             0x7e00002b  func=0111 uop=11 ctrl=1
mzero m4             0xa002002b  func=1010 uop=00 25:23=000
mldb m4,a1,(a0)      0x08b5022b  func=0000 uop=10 25:23=001
mld1mb m4,(a0)       0x2805022b  func=0010 uop=10 25:23=000
mmaqa.b m4,m2,m1     0x2046002b  func=0010 uop=00 25:23=000
```

因此，这个 release 不能直接作为 CoralNPU 当前矩阵指令的编码来源。
它可以作为“玄铁旧版 Matrix 扩展工具链”的独立参考，但不能直接生成
当前 CoralNPU 支持的 `msettile*`、`mmacc.w.b`、`ml{a,b,c}*` 指令。

配置指令、`mzero` 和矩阵访存的主要字段位置与 CoralNPU 当前
`MatrixDecode.scala` 一致。矩阵乘存在一个必须先解决的编码差异：

| 类别 | spec `instruction_list.adoc` | CoralNPU `MatrixDecode.scala` | 结论 |
| --- | --- | --- | --- |
| 配置 | `uop=00` | `uop=00` | 一致 |
| `mzero` | `uop=11` | `uop=11` | 主要字段一致 |
| 访存 | `uop=01` | `uop=01` | 一致 |
| `mmacc.w.b` 等四种整数乘 | spec 表格为 `uop=01` | `uop=10` | CoralNPU 固定采用 `uop=10` |

此外，spec 的 `inst32_format.adoc` 第 64 行文字把矩阵乘描述为
`uop=10`，而 `instruction_list.adoc` 的矩阵乘表写成了 `uop=01`。
经过与当前 CoralNPU RTL、已有矩阵测试和编码参考的核对，项目决定冻结
CoralNPU 矩阵乘编码为 `uop=10`。后续工具链、汇编器、测试和文档都必须
使用这个值；`instruction_list.adoc` 中的 `uop=01` 只作为上游 spec
版本差异保留，不再作为 CoralNPU 的实现依据。

### CoralNPU 冻结规则

以下规则是 CoralNPU 当前矩阵 ISA 的规范性约束：

1. 矩阵乘 `mmacc.w.b`、`mmaccu.w.b`、`mmaccus.w.b`、`mmaccsu.w.b`
   的 `uop` 固定为 `10`。
2. 配置指令的 `uop` 固定为 `00`。
3. 矩阵访存指令的 `uop` 固定为 `01`。
4. `mzero` 的 `uop` 固定为 `11`。
5. 新工具链实现必须先匹配本节规则，再讨论与其他 Matrix ISA 版本的
   兼容性；不得为了适配玄铁 `v0.3.0` 而隐式修改 CoralNPU RTL。

本步骤没有修改 MatrixCore、PE 或 MatrixDecode RTL。`uop=10` 的决定是
对当前已有 RTL 和测试行为的正式冻结，不代表本次修改了 RTL。

## 字段核对

### 配置

格式：

```text
31:28 func     27:26 uop=00  25 ctrl  24:20 rs2
19:15 rs1      14:12 func3=000  11:7=0  6:0 opcode=0x2b
```

`ctrl=0` 时，`24:15` 是 `uimm10`；`ctrl=1` 时，spec 要求
`24:20=0`，`19:15` 是 `rs1`。当前解码器的六个 pattern 覆盖了这两种形式，
并通过 `inst[25]` 产生标量寄存器读取信号。立即数的实际写入路径在
`Decode.scala` 中从 `inst[24:15]` 形成。

### `mzero`

格式：

```text
31:28 func=0000  27:26 uop=11  25:23 uimm3
22:20 ms2=0      19:18 s_size=00  17:15 ms1=0
14:12 func3=000  11:10 d_size=00  9:7 md  6:0 opcode=0x2b
```

`uimm3` 的 spec 语义为：

```text
000 -> 1 个寄存器
001 -> 2 个寄存器
011 -> 4 个寄存器
111 -> 8 个寄存器
```

起始 `md` 必须按寄存器数量对齐。当前 CoralNPU 先将固定字段匹配的
编码归为 MISC，再由 `isZeroLegal()` 处理数量和对齐；因此保留的
`uimm3` 编码不会被当作合法的清零发射。

### 四种整数矩阵乘

按 `instruction_list.adoc`：

```text
31:28 func=0001  27:26 uop=01  25:23 size_sup
22:20 ms2        19:18 s_size=00  17:15 ms1
14:12 func3=000  11:10 d_size=10  9:7 md/ms3
6:0 opcode=0x2b
```

`size_sup` 映射为：

```text
011 -> mmacc.w.b
000 -> mmaccu.w.b
001 -> mmaccus.w.b
010 -> mmaccsu.w.b
```

当前 CoralNPU pattern 唯一不同之处是把 `27:26` 写成 `10`。例如，
同样取 `ms2=2, ms1=5, md=4`：

```text
spec mmacc.w.b : 0x15a28a2b  (uop=01)
Coral pattern  : 0x19a28a2b  (uop=10)
```

这两个值不会被同一个当前 `MatrixDecode.scala` pattern 同时识别。

### 访存

格式：

```text
31:28 func     27:26 uop=01  25 ls  24:20 rs2
19:15 rs1      14:12 func3=000  11:10 d_size
9:7 md/ms3     6:0 opcode=0x2b
```

`func` 映射为：

```text
0 A       1 B       2 C       3 whole
4 A^T     5 B^T     6 C^T
```

`ls=0` 是 load，`ls=1` 是 store；`d_size=00/01/10/11` 对应
8/16/32/64 bit。对于 `whole`，spec 要求 `rs2=0`；当前 RTL 的
分类 pattern 没有额外约束 `rs2`，但 `readRs2` 被置为 0。这个差异属于
保留字段检查，不改变正常 whole 指令的编码。

## 参考脚本用法

```bash
cd /home/wjj/2-NPU/coralnpu
python3 tests/toolchain/matrix_encode_reference.py
```

脚本会：

1. 对配置、`mzero`、四种整数矩阵乘以及 7 个访存 family 的 load/store
   组合进行 round-trip 自检。
2. 输出代表性机器码及字段解码结果。
3. 对保留的 `mzero` 数量编码和错误对齐直接拒绝，避免把非法参数误当作
   可发射指令。

## 玄铁 release 实测方法

下载并校验工具链：

```bash
curl -L -o /tmp/Xuantie-gcc-linux-glibc-x86_64-matrix.tar.gz \
  https://github.com/XUANTIE-RV/riscv-matrix-extension-spec/releases/download/v0.3.0/Xuantie-gcc-linux-glibc-x86_64-matrix.tar.gz
md5sum /tmp/Xuantie-gcc-linux-glibc-x86_64-matrix.tar.gz
```

最小 C 样例使用玄铁头文件中的 builtin/intrinsic 生成配置、`mzero`、
矩阵 load 和 `mmaqa.b`，再用下面的命令读取真实机器码：

```bash
riscv64-unknown-linux-gnu-objdump -d -M no-aliases matrix_probe.o
```

直接把当前 spec 助记符交给同一 assembler 时，例如
`mmacc.w.b m4,m2,m1` 和 `msettileki 32`，assembler 报告
`unrecognized opcode`。这不是同一指令的操作数语法差异。

## 当前状态

1. 玄铁 release assembler/GCC 已完成独立对照；其指令族和当前 spec 不同，
   不能用它裁决当前 Coral 矩阵乘 `uop`。
2. Coral 专用 assembler/disassembler 已完成，入口位于
   `tests/toolchain/coral_matrix_as.py` 和
   `tests/toolchain/coral_matrix_dis.py`。
3. 25 条配置、mzero、四种矩阵乘、A/B/C、whole 和 transposed 访存样例
   已通过 round-trip，`.word` 经 `/opt/riscv` 汇编后的 `.text` 字节也已
   与参考编码一致。
4. 本阶段没有修改 CoralNPU RTL。后续只有在要求 GCC/Binutils 原生识别
   Coral mnemonic 时，才需要把相同 opcode 表移植到 GNU 工具链。
