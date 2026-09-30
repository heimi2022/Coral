# Matrix Matmul 波形核对手册

本文用于核对测试：

```text
//tests/cocotb:matrix_cpu_dma_matmul_mx_m64_n33_k64
```

目标矩阵为：

```text
C[64][33] = A[64][64] * B[33][64]
```

测试同时覆盖两个 K block 和两个 N block：

```text
M = 64
N = 33 = 32 + 1
K = 64 = 32 + 32
```

## 1. 测试输入

测试文件为 `tests/cocotb/matrix_cpu_dma_test.py`，函数为 `exercise_matmul`。

矩阵布局如下：

```text
A: 64 行，每行 64 个 int8 元素
B: 33 行，每行 64 个 int8 元素
   B 的第 col 行表示原矩阵 B 的第 col 列，因此硬件读取 B[col][k]
A scale: 两组，每组 64 个 scale
B scale: 两组，每组 33 个 scale
```

每个 K block 只有前 4 个 lane 设置为非零，其余 lane 为 0。对行 `r`、列 `c`、K block `g` 和 lane `l`：

```python
A[r][32*g+l] = sign(r+l+g) * (8+r+l+2*g)
B[c][32*g+l] = sign(c+g) * (5+2*c+2*l+g)
```

其中：

```python
sign(x) = -1 if x 为奇数，否则为 +1
```

scale 为：

```python
A_scale[g][r] = 126 + (r + g) % 3
B_scale[g][c] = 126 + (c + 2*g) % 3
```

期望值使用：

```python
dot_g = sum(A[r][k] * B[c][k] for k in 32*g .. 32*g+31)
value_g = dot_g * 2 ** (A_scale[g][r] + B_scale[g][c] - 254 - 12)
C[r][c] = value_0 + value_1
```

`C` 的目标地址是 `BASE + 0xA000`，每行 stride 为 192 字节。N0 使用列 `0..31`，N1 使用列 `32`。

## 2. Tiling 顺序

当前 `matmul_tiling.sv` 对 `N=33,K=64` 生成四个 block，顺序固定为：

| block | N block | K block | 有效列 | 有效 K | `nblock` | `kblock` |
|---|---:|---:|---:|---:|---:|---:|
| 0 | N0 | K0 | 32 | 32 | 0 | 0 |
| 1 | N0 | K1 | 32 | 32 | 0 | 1 |
| 2 | N1 | K0 | 1 | 32 | 1 | 0 |
| 3 | N1 | K1 | 1 | 32 | 1 | 1 |

每个 block 都处理完整的 64 个 M 行。K1 block 需要读取 K0 已经写回的 C；K0 block 使用零初值。

## 3. 端口阶段

### 3.1 命令和 block 描述

先观察 `matmul_tiling` 和 `pe_ctrl` 的 block 顺序：

```text
cmd_valid_i / cmd_ready_o
stream_pop
weight_pop
tiling_act_nblock
tiling_act_psum_m_rows
tiling_psum_n_cols
tiling_act_col
tiling_act_psum_last
```

四个 block 应分别看到：

```text
(nblock, kblock, n_cols, m_rows) =
(0, 0, 32, 64)
(0, 1, 32, 64)
(1, 0,  1, 64)
(1, 1,  1, 64)
```

`tiling_act_col` 当前就是 K block 选择；`tiling_act_nblock` 是 N block 选择。

### 3.2 B 权重读取

每个 K block 开始时，观察：

```text
rs2_read_valid_o
rs2_addr_o
rs2_col_o
rs2_data_valid_i
load_weight_ping
load_weight_pong
weight_bank_sel
```

预期：

- K0 装入一个 weight bank，`rs2_col_o=0`。
- K1 装入另一个 weight bank，`rs2_col_o=1`。
- B 的 N0 block 读取 32 行；N1 block 只读取 1 行。
- 权重读完成后，`weight_bank_sel` 应切换到刚装好的 bank。

### 3.3 A 激活读取

观察：

```text
rs1_read_valid_o
rs1_addr_o
rs1_col_o
rs1_data_valid_i
stream_count
stream_m_rows
stream_start_age_q
stream_start_pending_q
```

每个 block 的 A 行地址应为：

```text
0, 1, 2, ..., 63
```

6 周期限制只延迟新 block 的第一行 A 读取。一个 block 的首行开始后，剩余 63 行应连续输入，除非存在原有的边界 bubble。

### 3.4 PE 阵列输出

观察阵列底部：

```text
u_pe_array.psum_valid_o
u_pe_array.psum_pre_valid_o
u_pe_array.psum_bottom_o
```

或在顶层观察：

```text
psum_valid
psum_pre_valid
psum_bottom
pe_array_o
```

`psum_bottom` 是未经 C 累加的 K block 部分和。它不是最终 C 值。

对同一个输出元素，K0 和 K1 的 `psum_bottom` 应分别对应两个 K block 的结果。

### 3.5 C 读取

C 读请求观察：

```text
rd_read_valid_o
rd_read_o
rd_read_addr_o
rd_read_nblock_o
rd_data_valid_i
rd_data_i
```

K0 block：

```text
rd_read_valid_o = 0
```

因为 K0 使用零初值旁路。

K1 block：

```text
rd_read_valid_o = 1
rd_read_addr_o  = 0..63
rd_read_nblock_o = 当前 N block
```

注意：`rd_read_addr_o` 是当前发出的读请求地址，不是当前 `psum_bottom` 已经绑定的地址。CMatrixReg 为同步读，必须将请求地址和下一拍的 `rd_data_valid_i/rd_data_i` 配对观察。

真实 CMatrixReg 内部还应检查：

```text
u_c_regfile.rd_accept_w
u_c_regfile.rd_valid_o
u_c_regfile.rd_wr_conflict_w
u_c_regfile.rd_dma_conflict_w
```

如果 `rd_accept_w=0`，才说明 C 读请求被拒绝。不能只根据 `rd_read_addr_o` 推断冲突。

### 3.6 累加器四级流水

当前 `accumulaters.sv` 的 valid 流水为：

```text
valid_i -> s1_valid_q -> s2_valid_q -> s3_valid_q -> valid_o
```

对应数据阶段：

| 阶段 | 主要内容 | 观察信号 |
|---|---|---|
| 输入 | PE 部分和与 C 数据进入累加器 | `valid_i`, `add_pe_i`, `add_rd_i`, A/B scale valid |
| S1 | 对 PE 部分和、C 做指数比较和对齐 | `s1_valid_q`, `s1_*` |
| S2 | 完成尾数加法和舍入选择 | `s2_valid_q`, `s2_sum_q`, `s2_exp_q` |
| S3 | 规格化并寄存尾数/指数 | `s3_valid_q`, `s3_sig_q`, `s3_exp_q` |
| 输出 | 打包成定制 FP32 | `valid_o`, `sum_o` |

重点检查每个 K1 元素：

```text
add_pe_i
add_rd_i
valid_i
valid_o
sum_o
```

`add_rd_i` 必须是对应 K0 的 C 写回值，不能是上一行、下一行或另一个 N block 的值。

### 3.7 C 写回

观察：

```text
rd_write_valid_o
rd_write_o
rd_write_addr_o
rd_write_nblock_o
pe_array_o
accum_valid
accum_sum_o
```

对于每个 block：

```text
rd_write_addr_o = 0..63
```

N0 写回时：

```text
rd_write_nblock_o = 0
rd_write_n_cols = 32
```

N1 写回时：

```text
rd_write_nblock_o = 1
rd_write_n_cols = 1
```

N1 的写回只应修改 lane 0，lane 1 到 31 必须被屏蔽。

## 4. C[34,1] 具体核对值

`C[34,1]` 位于 N0 block，使用 `nblock=0`、列 lane 1。

### K0

输入：

```text
A[34][0:3] = [42, -43, 44, -45]
B[1][0:3]  = [-7, -9, -11, -13]
A scale    = 127
B scale    = 127
```

PE 部分和：

```text
42*(-7) + (-43)*(-9) + 44*(-11) + (-45)*(-13) = 194
```

定制浮点结果：

```text
194 * 2^(127+127-254-12) = 0.04736328125
bits = 0x3D420000
```

K0 写回 C 时，预期：

```text
rd_write_addr_o = 34
rd_write_nblock_o = 0
pe_array_o[1] = 0x3D420000
```

### K1

输入：

```text
A[34][32:35] = [-44, 45, -46, 47]
B[1][32:35]  = [8, 10, 12, 14]
A scale      = 128
B scale      = 126
```

PE 部分和：

```text
(-44)*8 + 45*10 + (-46)*12 + 47*14 = 204
```

K1 开始时，C 读请求必须取得 K0 的值：

```text
rd_read_addr_o = 34
rd_read_nblock_o = 0
rd_data_valid_i = 1
rd_data_i[1] = 0x3D420000
```

累加结果：

```text
204 * 2^(128+126-254-12) = 0.0498046875
0.04736328125 + 0.0498046875 = 0.09716796875
bits = 0x3DC70000
```

累加器对应 lane 1 应观察到：

```text
add_pe_i[1] = 204
add_rd_i[1] = 0x3D420000
sum_o[1]   = 0x3DC70000
```

最后写回：

```text
rd_write_addr_o = 34
rd_write_nblock_o = 0
pe_array_o[1] = 0x3DC70000
```

## 5. 排查顺序

建议严格按下面顺序检查：

1. 确认四个 block 的 `nblock/kblock/n_cols/m_rows` 顺序正确。
2. 确认 K0 的 C 写回地址为 `0..63`，且 `nblock=0` 或 `1` 正确。
3. 确认 K1 的 C 读请求地址为 `0..63`，且读返回数据与请求相差一拍。
4. 确认 `rd_data_valid_i` 与累加器实际消费 C 数据的 valid 对齐。
5. 确认 `add_pe_i` 是当前行的 K1 部分和。
6. 确认 `add_rd_i` 是相同 row、相同 lane、相同 N block 的 K0 结果。
7. 确认累加器 `sum_o` 的 bits 与 Python 期望一致。
8. 最后再检查 C 写回地址、N block 和 lane mask。

## 6. 运行测试

完整测试：

```bash
bazel test \
  //tests/cocotb:matrix_cpu_dma_matmul_mx_m64_n33_k64 \
  --test_output=streamed \
  --nocache_test_results
```

独立 PE 控制测试：

```bash
bazel test \
  //tests/cocotb:pe_ctrl_standalone \
  --test_filter=pe_ctrl_m64_n33_k64_debug \
  --test_output=streamed \
  --nocache_test_results
```

完整测试 target 已开启波形；运行后可查找：

```bash
find "$(bazel info output_base)" \
  -path '*matrix_cpu_dma_matmul_mx_m64_n33_k64*' \
  \( -name '*.fst' -o -name '*.vcd' \) -print
```

