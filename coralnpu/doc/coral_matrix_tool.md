# CoralNPU 矩阵工具链入口

更新时间：2026-10-01

CoralNPU 当前冻结的矩阵编码有两个入口：独立的 Python
assembler/disassembler，以及 `include/coral_matrix.h` 提供的 C API。两者都
直接生成冻结的 `.word`，不依赖 GCC 是否已经集成 Coral 矩阵后端。

## 语法

```asm
msettileki 33
msettilem x5
msettileni 17

mzero c0
mzero4r c0
mmacc.w.b c0, b1, a2

mlae8  a0, (a0), a1
mlbe16 b1, (a0), a1
mlce32 c0, (a0), a1
msce32 c0, (a0), a1
mlme32 m0, (a0), x0
```

寄存器规则如下：

- `a0..a3` 和 `b0..b3` 编码为字段 `0..3`。
- `c0..c3` 编码为物理字段 `4..7`。
- `m0..m7` 直接指定 3 位原始矩阵寄存器字段。
- 标量寄存器支持 `x0..x31` 和标准 ABI 别名，例如 `a0`、`sp`。
- `mlme/msme` 是 whole-matrix 访存，`rs2` 必须为 `x0`。

## 使用

### C API

公共头文件可以直接包含到 freestanding C/C++ 程序中：

```c
#include "include/coral_matrix.h"

void matmul_tile(const int8_t *a, const int8_t *b, uint32_t *c,
                 uintptr_t a_stride, uintptr_t b_stride,
                 uintptr_t c_stride) {
  coral_mlae8(CORAL_A0, a, a_stride);
  coral_mlbe8(CORAL_B0, b, b_stride);
  coral_mzero(CORAL_C0);
  coral_mmacc_w_b(CORAL_C0, CORAL_B0, CORAL_A0);
  coral_msce32(CORAL_C0, c, c_stride);
}
```

C API 的内存操作约定如下：

- `base` 和 `stride` 是运行时 C 参数，分别搬到固定的 `a0` 和 `a1`。
- whole-matrix 操作没有 stride 参数，编码中的 `rs2` 固定为 `x0`。
- A/B tile API 只接受 `CORAL_A0..CORAL_A3` 或 `CORAL_B0..CORAL_B3`。
- C API 只接受 `CORAL_C0..CORAL_C3`，它们编码为原始字段 `4..7`。
- `coral_mzero*` 和 `coral_mmacc*` 的矩阵寄存器字段必须是编译期常量，
  这样最终指令字可以在编译期确定。
- `coral_mzero2r/4r/8r` 会在编译期检查起始寄存器对齐。

当前接口覆盖 A/B/C、whole、转置 A/B/C 的 8/16/32/64 位 load/store，
以及三种 tile shape 配置、四种 `mmacc.w.b` 变体和 `mzero`。

编译一个只包含矩阵指令的 probe：

```bash
cd /home/wjj/2-NPU/coralnpu
/opt/riscv/bin/riscv64-unknown-elf-gcc \
  -march=rv64gc -mabi=lp64d -O2 -ffreestanding -nostdlib \
  -I include -c tests/toolchain/coral_matrix_c_api_probe.c \
  -o /tmp/coral_matrix_c_api_probe.o
```

该 API 使用 `.word`，因此生成的对象文件可以直接进入现有 CoralNPU
程序的链接流程；它不会要求主机 GNU assembler 识别 Coral 专用助记符。

使用本地修改后的玄铁 GCC 验证 C API：

```bash
cd /home/wjj/2-NPU/coralnpu
XGCC=/home/wjj/2-NPU/xuantie-gcc-build/gcc/xgcc
XGCC_B=/home/wjj/2-NPU/xuantie-gcc-build/gcc
"$XGCC" -B"$XGCC_B" -march=rv64gc_xcoralmatrix -mabi=lp64d \
  -O2 -ffreestanding -nostdlib -I include \
  -S tests/toolchain/coral_matrix_c_api_probe.c \
  -o /tmp/coral_matrix_c_api_probe.s
grep -n '\.word' /tmp/coral_matrix_c_api_probe.s
```

这一步应生成包含 56 条矩阵内存 `.word` 的汇编，并且不会出现
`unknown or unsupported architecture` 或 `bad value for -march`。

验证修改后的 Binutils 助记符入口：

注意：GCC 的 `gcc/as` 是一个包装脚本，它调用 GCC 配置阶段记录的
`riscv64-unknown-elf-as`。仅重新构建 GCC 不会把 Coral 指令表编译进
assembler；必须先构建本目录对应的 `riscv-binutils`，再用
`--with-as` 和该 assembler 重新配置 GCC。例如：

```bash
export CORAL_BINUTILS_SRC=/home/wjj/2-NPU/riscv-matrix-extension-spec/xuantie-gnu-toolchain/riscv-binutils
export CORAL_BINUTILS_BUILD=/home/wjj/2-NPU/xuantie-binutils-build
export CORAL_BINUTILS_PREFIX=/home/wjj/2-NPU/xuantie-binutils-install

mkdir -p "$CORAL_BINUTILS_BUILD"
cd "$CORAL_BINUTILS_BUILD"
"$CORAL_BINUTILS_SRC/configure" \
  --target=riscv64-unknown-elf \
  --prefix="$CORAL_BINUTILS_PREFIX" \
  --disable-nls --disable-werror \
  --disable-gdb --disable-gdbserver --disable-sim
make -j1
make install
```

然后在 GCC 构建目录中重新配置并构建：

```bash
cd /home/wjj/2-NPU/xuantie-gcc-build
/home/wjj/2-NPU/riscv-matrix-extension-spec/xuantie-gnu-toolchain/riscv-gcc/configure \
  --target=riscv64-unknown-elf \
  --enable-languages=c \
  --disable-bootstrap --disable-nls --disable-multilib \
  --without-headers --disable-libssp --disable-libgomp \
  --disable-libquadmath --disable-libvtv --disable-libstdcxx \
  --with-as="$CORAL_BINUTILS_PREFIX/bin/riscv64-unknown-elf-as" \
  --with-ld="$CORAL_BINUTILS_PREFIX/bin/riscv64-unknown-elf-ld"
make -j1
```

完成后再运行下面的 GCC 汇编命令。gas 接收到的架构字符串应包含
`xcoralmatrix1p0`，并且能够识别 `coral.*` 助记符。

```bash
"$XGCC" -B"$XGCC_B" -march=rv64gc_xcoralmatrix -mabi=lp64d \
  -c tests/toolchain/coral_matrix_gas.s \
  -o /tmp/coral_matrix_gas.o
readelf -h /tmp/coral_matrix_gas.o | grep 'Machine:'
readelf -x .text /tmp/coral_matrix_gas.o
```

这里使用 `tests/toolchain/coral_matrix_gas.s`，因为它采用 Binutils 注册的
`coral.*` 助记符和标准 `stride, 0(base)` 内存操作数格式；
`tests/toolchain/coral_matrix_asm.s` 仍然保留给项目自带 Python assembler。

将矩阵汇编转换成可被普通 RISC-V 工具链接受的 `.word`：

```bash
cd /home/wjj/2-NPU/coralnpu
python3 tests/toolchain/coral_matrix_as.py \
  tests/toolchain/coral_matrix_asm.s \
  -o /tmp/coral_matrix_generated.S
```

生成对象文件并查看原始指令：

```bash
/opt/riscv/bin/riscv64-unknown-elf-gcc \
  -march=rv64gc -mabi=lp64d -c /tmp/coral_matrix_generated.S \
  -o /tmp/coral_matrix_generated.o
/opt/riscv/bin/riscv64-unknown-elf-objdump -s -j .text \
  /tmp/coral_matrix_generated.o
```

也可以输出十六进制或裸 little-endian 字节：

```bash
python3 tests/toolchain/coral_matrix_as.py input.s --format hex
python3 tests/toolchain/coral_matrix_as.py input.s --format binary -o matrix.bin
python3 tests/toolchain/coral_matrix_dis.py matrix.bin --binary
```

## 回归检查

推荐使用统一入口执行工具链回归。它会串联参考编码、独立
assembler/disassembler、修改后的 GCC/Binutils、RV64/RV32 ELF 属性和
RVV + Matrix 编译检查：

```bash
cd /home/wjj/2-NPU/coralnpu
python3 tests/toolchain/check_coral_matrix_toolchain.py
```

默认使用以下本机构建产物：

```text
RV64 GCC:      /home/wjj/2-NPU/xuantie-gcc-coral-build/gcc/xgcc
RV64 Binutils: /home/wjj/2-NPU/xuantie-binutils-install/bin
RV32 GCC:      /home/wjj/2-NPU/xuantie-gcc-rv32-coral-build/gcc/xgcc
RV32 Binutils: /home/wjj/2-NPU/xuantie-binutils-rv32-install/bin
```

也可以通过 `CORAL_RV64_CC`、`CORAL_RV64_CC_B`、`CORAL_RV64_BINUTILS`、
`CORAL_RV32_CC`、`CORAL_RV32_CC_B` 和 `CORAL_RV32_BINUTILS` 覆盖路径。
`--skip-rv32-elf` 只跳过链接后的 RV32 ELF 检查，不会跳过 RV32 RVV 编译
检查。RV32 ELF 默认生成到 `/tmp/coral_matrix_toolchain_rv32.elf`，也可用
`--rv32-elf-output` 指定路径。

```bash
python3 tests/toolchain/check_coral_matrix_roundtrip.py
python3 tests/toolchain/matrix_encode_reference.py
python3 tests/toolchain/check_coral_matrix_probe.py
PYTHONPATH=tests/toolchain \
python3 tests/toolchain/check_coral_matrix_c_api_programs.py
```

round-trip 检查覆盖配置、四种 `mmacc.w.b`、`mzero` 的四种数量编码、
A/B/C 与 whole/transposed load/store。C API probe 另外验证 56 条内存
编码及编译期寄存器类别约束。矩阵乘的 `uop=10` 由参考编码器和反汇编
回归共同锁定；工具不会采用玄铁旧工具链中的矩阵编码。

`check_coral_matrix_c_api_programs.py` 使用已构建的 Coral GCC 编译并链接
三个实际 cocotb C API 程序：DMA、单次 MatMul 和两段 K 的 GEMM。当前 Coral
GCC 构建只启用了 C 前端，因此脚本对这些 C-compatible 的 `.cc` 源显式使用
`-x c`。脚本检查目标文件和链接后 ELF 的 `ELF64 RISC-V` 属性、
`xcoralmatrix1p0` 架构属性以及矩阵指令顺序。

这一步验证的是 RV64 freestanding 工具链产物，不代表它已经能直接加载到
当前 CoralNPU 的 RV32 仿真路径。将其接入现有 ELF 仿真前，还需要提供
`riscv32-unknown-elf` 的 Coral Binutils/GCC 构建，并核对启动代码、ABI 和
链接脚本。

## RV32 工具链验证

当前 CoralNPU 仿真使用 RV32，因此已经单独构建 RV32 Coral Binutils/GCC：

```text
Binutils: /home/wjj/2-NPU/xuantie-binutils-rv32-install
GCC:      /home/wjj/2-NPU/xuantie-gcc-rv32-coral-build/gcc/xgcc
```

RV32 汇编器和 GCC 的最小验证命令如下：

```bash
cd /home/wjj/2-NPU/coralnpu
export PATH=/home/wjj/2-NPU/xuantie-binutils-rv32-install/bin:$PATH
export XGCC=/home/wjj/2-NPU/xuantie-gcc-rv32-coral-build/gcc/xgcc
export XGCC_B=/home/wjj/2-NPU/xuantie-gcc-rv32-coral-build/gcc

"$XGCC" -B"$XGCC_B" \
  -march=rv32gc_xcoralmatrix -mabi=ilp32 \
  -c tests/toolchain/coral_matrix_gas.s \
  -o /tmp/coral_matrix_gas_rv32.o

/home/wjj/2-NPU/xuantie-binutils-rv32-install/bin/riscv32-unknown-elf-readelf \
  -h -A /tmp/coral_matrix_gas_rv32.o
```

完整 RV32 C API/ELF 检查使用同一个脚本，通过环境变量切换目标位宽：

```bash
export RISCV_CC="$XGCC"
export RISCV_CC_B="$XGCC_B"
export RISCV_MARCH=rv32gc_xcoralmatrix
export RISCV_MABI=ilp32
export RISCV_ELF_CLASS=ELF32
export RISCV_OBJCOPY=/home/wjj/2-NPU/xuantie-binutils-rv32-install/bin/riscv32-unknown-elf-objcopy
export RISCV_READELF=/home/wjj/2-NPU/xuantie-binutils-rv32-install/bin/riscv32-unknown-elf-readelf
PYTHONPATH=tests/toolchain \
  python3 tests/toolchain/check_coral_matrix_c_api_programs.py
```

该检查已验证 DMA、MatMul 和两段 K 的 GEMM，分别包含 4、10、15 条冻结
矩阵编码。当前 GCC 仍会报告 `__riscv_xcoralmatrix` 宏重复定义警告，但不
影响生成结果。该 warning 来自外部 GCC 目标宏初始化流程，不是 C API
重复定义，也不代表 ELF 属性或指令编码错误。若需要修复 warning，应在
GCC 源码中修正目标宏只注册一次，然后重新构建 GCC；项目侧不使用
`-Wno-builtin-macro-redefined` 隐藏它。

## 完整工具链回归

构建好 RV64/RV32 Coral GCC 和对应 Binutils 后，可用一个入口执行全部
工具链检查：

```bash
cd /home/wjj/2-NPU/coralnpu
tests/toolchain/run_coral_matrix_toolchain.sh
```

默认路径来自当前工作区的上一级目录。其他环境只需设置
`CORAL_TOOLCHAIN_ROOT`，或分别设置 `CORAL_RV64_CC`、
`CORAL_RV64_CC_B`、`CORAL_RV64_BINUTILS`、`CORAL_RV32_CC`、
`CORAL_RV32_CC_B` 和 `CORAL_RV32_BINUTILS`。

冻结前可采集源码 commit、dirty 状态和工具版本：

```bash
python3 tests/toolchain/collect_coral_matrix_manifest.py \
  --output /tmp/coral_matrix_toolchain_manifest.json
```

manifest 中的 `dirty` 字段必须在发布前变为 `false`，并且应保存统一
回归命令的通过结果。

## 其他开发者配置工具链

CoralNPU 主仓库不把完整 GCC 和 Binutils 源码复制进来。仓库内保存了
两个固定基线上的 patch，因此其他开发者 clone 仓库后可以自动准备相同的
工具链源码：

```bash
cd /path/to/coralnpu
tests/toolchain/prepare_coral_matrix_sources.sh
```

脚本默认将源码放在 CoralNPU 同级的
`riscv-matrix-extension-spec/xuantie-gnu-toolchain`，也可以指定位置：

```bash
export CORAL_TOOLCHAIN_SOURCE_ROOT=/path/to/xuantie-gnu-toolchain
tests/toolchain/prepare_coral_matrix_sources.sh
```

脚本固定以下版本：

- XuanTie GCC 分支 `xuantie-gcc-14.3.0` 加 Coral Matrix patch。
- XuanTie Binutils 分支 `xuantie-binutils-gdb-2.42` 加 Coral Matrix patch。

源码准备完成后，分别构建 RV64 和 RV32 Binutils，再构建对应 GCC。GCC
的 `--with-as`、`--with-ld` 和 `--with-build-time-tools` 必须指向同一
位宽的 Binutils 安装目录。构建完成后设置 `CORAL_RV64_CC`、
`CORAL_RV64_CC_B`、`CORAL_RV64_BINUTILS`、`CORAL_RV32_CC`、
`CORAL_RV32_CC_B` 和 `CORAL_RV32_BINUTILS`，然后运行统一回归。

## 外部 RV32 工具链生成可执行 ELF

RV32 汇编和 C API 编码验证通过后，可使用独立脚本生成一份带最小启动代码
的 CoralNPU ELF。该脚本使用 `tests/toolchain/coral_matrix_rv32_start.S` 设置
栈、调用 `main`，再执行 `wfi`；`coral_matrix_rv32.ld` 使用 CoralNPU 的
ITCM `0x0`、DTCM `0x10000` 和外部内存区域。它不修改 Bazel 默认工具链，
也不把本机工具链路径写入 BUILD 文件。

```bash
cd /home/wjj/2-NPU/coralnpu
export RISCV_CC=/home/wjj/2-NPU/xuantie-gcc-rv32-coral-build/gcc/xgcc
export RISCV_CC_B=/home/wjj/2-NPU/xuantie-gcc-rv32-coral-build/gcc
export RISCV_OBJCOPY=/home/wjj/2-NPU/xuantie-binutils-rv32-install/bin/riscv32-unknown-elf-objcopy
export RISCV_READELF=/home/wjj/2-NPU/xuantie-binutils-rv32-install/bin/riscv32-unknown-elf-readelf
export RISCV_MARCH=rv32gc_xcoralmatrix
export RISCV_MABI=ilp32
python3 tests/toolchain/build_coral_matrix_rv32_elf.py
```

脚本检查最终链接产物为 ELF32 RISC-V、入口为 `0x0`、包含
`xcoralmatrix1p0` 属性，并按顺序检查 C API MatMul 的 10 条冻结编码。
这一步验证“外部工具链 -> 启动代码 -> 链接脚本 -> 可加载 ELF”；实际
MatrixCore 执行仍由现有 Cocotb/VCS ELF 测试负责。
