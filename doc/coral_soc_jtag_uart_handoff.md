# Coral RVV SoC JTAG/UART 交接文档

## 1. 当前验证目标

当前已经验证通过的链路是：

```text
FPGA 上电
  -> CoralSpiBootMaster 向 ITCM 写入等待桩
  -> 释放 Coral 的 reset/clock gate
  -> OpenOCD 通过 JTAG halt Coral
  -> OpenOCD 将 ELF 写入 ITCM/DTCM
  -> 设置 PC 为 0x00000000 并 resume
  -> Coral 执行 UART 程序
  -> UART1 输出 hello
```

本流程验证了以下模块可以协同工作：

- RVV Coral Core
- ITCM/DTCM
- SoC TL-UL 互连
- UART1
- RISC-V Debug Module
- DMI JTAG TAP
- SPI 自动启动等待桩
- OpenOCD ELF 下载和 resume

当前验证顶层为：

```text
/home/wjj/2-NPU/NPU/1-RTL/coral_jtag_uart_verified/rtl/CoralRvvSocJtagTop.sv
```

顶层模块名为 `CoralRvvSocJtagTop`。

## 2. 工程目录

### Chisel 工程

```text
/home/wjj/2-NPU/coralnpu
```

主要目录：

```text
hdl/chisel/src/coralnpu/       Coral Core、RVV、CSR、TCM 等 Chisel 代码
hdl/chisel/src/soc/            SoC crossbar 和 Chisel subsystem
hdl/verilog/rvv/               RVV 底层 Verilog
fpga/                          FPGA/Verilator 构建、软件和顶层封装
fpga/sw/                       运行在 Coral 上的 C/C++ 程序
fpga/BUILD                     SoC 和软件的 Bazel 目标
```

### FPGA 可交付 RTL

```text
/home/wjj/2-NPU/NPU/1-RTL/coral_jtag_uart_verified
```

关键文件：

```text
rtl/CoralRvvSocJtagTop.sv       FPGA 使用的最终顶层
rtl/CoralSpiBootMaster.sv       上电后写 ITCM 等待桩的模块
rtl/AxiDecerrSlave.sv           当前 DDR AXI 占位响应模块
deps/coral/coralnpu_soc.sv      SoC 外围封装
deps/coral/CoralNPUChiselSubsystem.sv
                                Chisel 生成并打包后的 RVV SoC RTL
deps/riscv_dbg/dmi_jtag.sv      DMI JTAG
deps/riscv_dbg/dmi_jtag_tap.sv  JTAG TAP
vivado_add_sources.tcl          Vivado 加入 RTL 文件的脚本
jtag_uart_hello.elf             已构建的 UART 验证程序
```

Vivado 工程应将 `CoralRvvSocJtagTop` 设置为顶层，不需要再加入独立的 `RvvCoreMiniAxi.sv`。完整 RVV Core 已经包含在 `CoralNPUChiselSubsystem.sv` 中。

## 3. SoC 的生成方式

### 3.1 Chisel subsystem

SoC 的核心 Chisel 生成入口位于：

```text
hdl/chisel/src/soc/CoralNPUChiselSubsystem.scala
```

Bazel 目标位于：

```text
hdl/chisel/src/soc/BUILD
```

默认 RVV SoC 的生成命令：

```bash
cd /home/wjj/2-NPU/coralnpu
bazel build //hdl/chisel/src/soc:coralnpu_chisel_subsystem_cc_library_emit_verilog
```

生成结果：

```text
bazel-bin/hdl/chisel/src/soc/CoralNPUChiselSubsystem.sv
```

这个文件包含 Chisel subsystem 的 Verilog/SystemVerilog 实现。FPGA 交付目录中的副本需要更新为：

```bash
cp bazel-bin/hdl/chisel/src/soc/CoralNPUChiselSubsystem.sv \
  /home/wjj/2-NPU/NPU/1-RTL/coral_jtag_uart_verified/deps/coral/CoralNPUChiselSubsystem.sv
```

### 3.2 RVV 配置

SoC 配置在 [`SoCChiselConfig.scala`](../coralnpu/hdl/chisel/src/soc/SoCChiselConfig.scala) 中打开 RVV：

```scala
enableRvv = true
```

当前 Coral RVV 参数在 [`Parameters.scala`](../coralnpu/hdl/chisel/src/coralnpu/Parameters.scala) 中定义：

```text
XLEN = 32 bit
VLEN = 128 bit
VLENB = 16 byte
```

FPGA Vivado 脚本中对应的宏定义为：

```text
VLEN_128
ZVE32F_ON
```

### 3.3 SoC 地址空间

默认配置的主要地址范围如下：

| 区域 | 地址范围 | 用途 |
|---|---:|---|
| ITCM | `0x0000_0000` 起 | 指令和程序入口 |
| DTCM | `0x0001_0000` 起 | 栈、数据和临时缓冲 |
| UART0 | `0x4000_0000` 起 | UART0 MMIO |
| UART1 | `0x4001_0000` 起 | UART1 MMIO |
| DDR 控制器 | `0x7000_0000` 起 | DDR 控制寄存器窗口 |
| DDR memory | `0x8000_0000` 起 | 外部 DDR 地址窗口 |

当前验证顶层中的 DDR AXI 端口由 `AxiDecerrSlave` 终止，访问 DDR 地址会返回错误响应，直到替换为实际 FPGA DDR 控制器和存储接口。

### 3.4 SoC 外围封装

Chisel subsystem 由 `coralnpu_soc.sv` 连接到 UART、ROM、SRAM、Debug Module 和外部端口。FPGA 验证顶层 `CoralRvvSocJtagTop.sv` 进一步完成：

```text
JTAG pins
  -> dmi_jtag
  -> SoC dm_req/dm_rsp
  -> Coral Debug Module
  -> ITCM/DTCM 访问和 hart 控制
```

```text
UART1 MMIO
  -> SoC UART1
  -> uart1_tx_o
```

```text
CoralSpiBootMaster
  -> SoC SPI 控制路径
  -> ITCM 等待桩
```

`vivado_add_sources.tcl` 会将完整 RTL 依赖加入 Vivado，并将 `CoralRvvSocJtagTop` 设置为 top：

```bash
source /home/wjj/2-NPU/NPU/1-RTL/coral_jtag_uart_verified/vivado_add_sources.tcl
```

## 4. FPGA 时钟和 reset

当前 FPGA 软件和 SoC 构建基线使用 80 MHz：

```text
fpga/BUILD: _CLOCK_FREQUENCY_MHZ = "80"
CoralRvvSocJtagTop: CLOCK_FREQUENCY_MHZ = 80
```

`CLOCK_FREQUENCY_MHZ` 是 UART 分频计算使用的参数，不会改变 FPGA 的物理时钟。物理时钟由 FPGA 顶层的 `clk_i` 和板级时钟约束决定。

如果把 FPGA 时钟改为其他频率，必须同时完成两件事：

1. 使 `clk_i` 实际运行在目标频率。
2. 使用相同频率重新编译 ELF，使 `uart_init(CLOCK_FREQUENCY_MHZ)` 生成正确的 UART NCO。

`CoralSpiBootMaster` 的作用是让 Coral 在 JTAG 接管之前停在安全等待状态。它向 ITCM 写入 WFI 等待桩，并通过 core-control CSR 释放必要的 reset/clock gate 控制。之后 OpenOCD 可以 halt hart、访问 TCM 并加载正式程序。

### 4.1 启动方式的修改

原始 Coral Core 的启动控制在 `CoreAxiCSR` 中完成。Core Control CSR 的定义为：

```text
CORE_CTRL_ADDR = 0x0003_0000
bit 0           core reset
bit 1           clock gate
reset value     3
```

因此原始设计上电后默认处于：

```text
core reset 有效 + clock gate 有效
```

原始启动流程需要外部控制器通过 SPI 访问 `0x0003_0000`，写入控制值，依次释放 clock gate 和 core reset。

当前 FPGA 验证顶层增加了：

```text
/home/wjj/2-NPU/NPU/1-RTL/coral_jtag_uart_verified/rtl/CoralSpiBootMaster.sv
```

并在 `CoralRvvSocJtagTop.sv` 中默认打开：

```systemverilog
parameter bit AUTO_JTAG_BOOT = 1'b1;
```

这样，外部 SPI 控制器不再是启动 Coral 的必要条件。板级 `rst_ni` 释放后，顶层内部的 `CoralSpiBootMaster` 自动完成原来由外部控制器完成的 SPI 初始化操作。

当前启动顺序为：

```text
板级 rst_ni 释放
  -> CoralSpiBootMaster 开始工作
  -> 通过内部 SPI/TL-UL 路径向 ITCM 写入 WFI 等待桩
  -> 写 Core Control CSR，释放 clock gate 和 core reset
  -> Coral 执行等待桩并进入 WFI
  -> boot_done_o 置 1
  -> OpenOCD 通过 JTAG halt Coral
  -> OpenOCD 下载正式 ELF 到 ITCM/DTCM
  -> 设置 PC = 0x0000_0000
  -> resume 执行正式程序
```

等待桩包含 `wfi` 和 fallback 跳转。它的作用是让 Core 在正式 ELF 下载前停在安全位置。JTAG 发出 `haltreq` 后，Core 的 clock gate 逻辑允许调试请求唤醒 Core，因此 OpenOCD 可以完成 hart examine、halt、TCM 读写和 ELF 下载。

这不是把 Core 的 reset 永久绑到释放状态。准确地说，当前顶层仍然保留 CoreAxiCSR 的 reset/clock-gate 机制，只是把启动控制器从外部 SPI 控制器改成了 FPGA 顶层内部的 `CoralSpiBootMaster`。

如果设置：

```systemverilog
.AUTO_JTAG_BOOT(1'b0)
```

则内部自动启动模块被关闭，系统恢复为需要外部 SPI 控制器访问 Core Control CSR 的启动方式。

因此当前版本的启动特性是：

| 项目 | 原始设计 | 当前 FPGA 验证顶层 |
|---|---|---|
| Core Control 初始状态 | reset 和 clock gate 有效 | 相同 |
| reset/clock gate 释放者 | 外部 SPI 控制器 | 顶层内部 `CoralSpiBootMaster` |
| 是否需要外部 SPI 控制器启动 | 需要 | 默认不需要 |
| JTAG 下载前状态 | Core 可能仍被复位/门控 | Core 已进入 WFI 等待桩 |
| 是否上电直接执行正式程序 | 否 | 否，先等待 JTAG |
| 关闭自动启动 | 不适用 | `AUTO_JTAG_BOOT=0` |

## 5. 软件程序结构

### 5.1 UART 驱动

驱动文件：

```text
fpga/sw/uart.h
fpga/sw/uart.c
```

当前驱动使用 UART1：

```c
#define UART1_BASE 0x40010000
```

寄存器偏移：

```text
UART_CTRL_OFFSET   0x10
UART_STATUS_OFFSET 0x14
UART_RDATA_OFFSET  0x18
UART_WDATA_OFFSET  0x1c
```

发送流程是：

```text
uart_init(clock_frequency_mhz)
  -> 配置 115200 baud 的 UART NCO

uart_putc(c)
  -> 轮询 UART_STATUS 的 TX full 标志
  -> 向 UART_WDATA 写入一个字节

uart_puts(str)
  -> 逐字节调用 uart_putc
```

### 5.2 JTAG UART 最小程序

源文件：

```text
fpga/sw/jtag_uart_hello.cc
```

程序逻辑：

```cpp
int main() {
  uart_init(CLOCK_FREQUENCY_MHZ);
  uart_puts("hello\r\n");

  while (true) {
    asm volatile("wfi");
  }
}
```

它只验证程序下载、hart 启动和 UART1 输出，不包含 RVV 运算。发送完 `hello` 后进入 WFI，避免 PC 继续执行到未定义区域。

### 5.3 RVV UART 程序

当前用于 RVV 加法和 UART 输出的源文件为：

```text
fpga/sw/add_uint32_m1.cc
```

它使用：

```cpp
vuint32m1_t
__riscv_vle32_v_u32m1
__riscv_vadd_vv_u32m1
__riscv_vse32_v_u32m1
```

该程序执行 RVV 向量加法后通过 UART 输出固定的测试字符串。若需要检查运算结果，应在程序中增加 `out_buf` 的打印或比较逻辑。

## 6. 软件 ELF 构建

`coralnpu_v2_binary` 宏在 [`rules/coralnpu_v2.bzl`](../coralnpu/rules/coralnpu_v2.bzl) 中定义。它会：

1. 使用 Coral 专用 RISC-V 交叉工具链。
2. 根据 ITCM、DTCM 和 stack 参数生成 linker script。
3. 将代码放到 ITCM 地址空间。
4. 将数据、栈和全局变量放到 DTCM 地址空间。
5. 生成 ELF 和 bin 文件组。

构建最小 UART 程序：

```bash
cd /home/wjj/2-NPU/coralnpu
bazel build //fpga:jtag_uart_hello.elf
```

查询实际 ELF 路径：

```bash
bazel cquery --output=files //fpga:jtag_uart_hello.elf
```

通常可以通过以下路径访问：

```text
/home/wjj/2-NPU/coralnpu/bazel-bin/fpga/jtag_uart_hello.elf
```

当前已经保存的交接副本是：

```text
/home/wjj/2-NPU/NPU/1-RTL/coral_jtag_uart_verified/jtag_uart_hello.elf
```

构建 RVV 加法程序：

```bash
bazel build //fpga:add_uint32_m1
bazel cquery --output=files //fpga:add_uint32_m1.elf
```

如果时钟不是 80 MHz，需要让软件 target 使用对应的 `CLOCK_FREQUENCY_MHZ`，然后重新生成 ELF。不要直接复用 80 MHz ELF。

## 7. JTAG 下载和 UART 验证

### 7.1 仿真自动验证

自动验证脚本：

```text
fpga/run_autoboot_jtag_uart_test.sh
```

脚本会依次执行：

1. 构建 `//fpga:jtag_uart_hello.elf`。
2. 构建带 `--AutoJtagBoot=1` 的 Verilator SoC 仿真器。
3. 启动仿真器和虚拟 UART/JTAG。
4. 等待 `SPI auto boot completed`。
5. 启动 OpenOCD。
6. halt hart。
7. 使用 `load_image` 将 ELF 写入 TCM。
8. 从 `0x0000_0000` resume。
9. 等待 UART1 输出 `hello`。

运行命令：

```bash
cd /home/wjj/2-NPU/coralnpu
bash fpga/run_autoboot_jtag_uart_test.sh
```

脚本默认使用：

```text
OpenOCD: /tmp/openocd-0.12-src/src/openocd
JTAG 配置: jtag-sim.cfg
工作目录: /tmp/coral_autoboot_jtag_uart_test
UART 输出: /tmp/coral_autoboot_jtag_uart_test/uart1.log
```

### 7.2 手动 OpenOCD 流程

仿真或 FPGA 已经连接 JTAG 后，可以使用类似命令：

```bash
openocd \
  -f /home/wjj/2-NPU/coralnpu/jtag-sim.cfg \
  -c 'riscv set_command_timeout_sec 300' \
  -c 'init' \
  -c 'halt' \
  -c 'load_image /home/wjj/2-NPU/NPU/1-RTL/coral_jtag_uart_verified/jtag_uart_hello.elf' \
  -c 'resume 0x00000000' \
  -c 'shutdown'
```

真实 FPGA 使用硬件 JTAG adapter 时，将 `jtag-sim.cfg` 替换为对应 adapter 的 OpenOCD 配置；ELF 下载和 `halt/resume` 流程保持不变。

### 7.3 预期结果

UART1 应输出：

```text
hello
```

验证脚本最终输出：

```text
PASS: JTAG-loaded firmware printed hello through UART1
```

此前 JTAG TCM 读写验证也已经通过，验证了通过 Debug Module 访问 ITCM/DTCM 的链路。

## 8. Vivado 加载流程

创建 Vivado RTL project 后执行：

```tcl
source /home/wjj/2-NPU/NPU/1-RTL/coral_jtag_uart_verified/vivado_add_sources.tcl
```

然后确认：

```text
Top module: CoralRvvSocJtagTop
Clock: clk_i
Reset: rst_ni
JTAG: jtag_tck_i, jtag_tms_i, jtag_trst_ni, jtag_tdi_i, jtag_tdo_o
UART: uart1_tx_o, uart1_rx_i
```

板级集成时至少需要约束实际时钟、reset、JTAG 和 UART1。未使用的输入应按顶层注释和板级设计接到稳定电平。

`CLOCK_FREQUENCY_MHZ` 必须等于 `clk_i` 的真实频率。该参数可以通过 Verilog parameter 或 Vivado generic 设置，但仅修改参数不会改变时钟源本身。

## 9. 修改后需要重新生成什么

### 修改 Chisel 或 RVV RTL

重新生成 subsystem：

```bash
cd /home/wjj/2-NPU/coralnpu
bazel build //hdl/chisel/src/soc:coralnpu_chisel_subsystem_cc_library_emit_verilog
cp bazel-bin/hdl/chisel/src/soc/CoralNPUChiselSubsystem.sv \
  /home/wjj/2-NPU/NPU/1-RTL/coral_jtag_uart_verified/deps/coral/CoralNPUChiselSubsystem.sv
```

然后在 Vivado 中重新综合和实现。

### 只修改 C/C++ 软件

不需要重新生成硬件 RTL，只需要重新生成 ELF：

```bash
bazel build //fpga:jtag_uart_hello.elf
```

然后通过 JTAG 重新下载 ELF。

### 修改 UART 时钟参数

需要重新编译软件 ELF，并同步设置顶层参数：

```text
软件：CLOCK_FREQUENCY_MHZ
硬件：CoralRvvSocJtagTop.CLOCK_FREQUENCY_MHZ
```

如果只修改其中一处，UART 波特率会不匹配。

### 修改 FPGA 顶层或外围连接

需要重新运行 Vivado 综合、实现和 bitstream 生成。修改 `CoralRvvSocJtagTop.sv` 后不需要重新运行 Chisel；修改 `CoralNPUChiselSubsystem.sv` 的来源逻辑后需要先重新生成 Chisel RTL。

## 10. 当前边界和后续扩展

- 当前验证重点是 ITCM/DTCM、JTAG 和 UART1。
- `0x7000_0000` DDR 控制窗口和 `0x8000_0000` DDR memory 窗口在交付顶层中由 `AxiDecerrSlave` 占位。
- 真正接入 DDR 时，需要替换对应 AXI 占位模块，并检查 AXI 数据宽度、时钟域和地址映射。
- `i_sram` 是 SoC 总线上的片上 SRAM，当前可作为额外工作区，但它不是 DTCM，也不是外部 DDR。
- `jtag_uart_hello.cc` 只验证串口链路；RVV 算法验证应使用或扩展 `fpga/sw/add_uint32_m1.cc`。
