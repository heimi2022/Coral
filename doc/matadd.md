# matadd 实验记录（已完成）

这次实验的目标不是实现真正的矩阵乘法，而是完整打通一条最小自定义指令链路：

- 指令名：`matadd`
- 第一版功能：`rd = rs1 + rs2`
- 路线：复用现有 ALU
- 验证目标：从 RTL 单测一直走到程序级 VCS cocotb 验证

## 指令定义

这一版把 `matadd` 定义成一条 **RISC-V custom-0** 指令，采用标准 R-type 格式：

- `opcode = 0001011` (`custom-0`)
- `funct3 = 000`
- `funct7 = 0101010` (`0x2A`)

编码格式：

```text
[31:25] funct7 = 0101010
[24:20] rs2
[19:15] rs1
[14:12] funct3 = 000
[11:7]  rd
[6:0]   opcode = 0001011
```

语义：

```text
x[rd] = (x[rs1] + x[rs2]) mod 2^32
```

例子：

- `matadd x3, x1, x2` -> `0x5420818b`
- `matadd x7, x5, x6` -> `0x5462838b`

## 实际改动点

这次实验最后落到 4 个核心位置：

1. `hdl/chisel/src/coralnpu/scalar/Alu.scala`
   - 在 `AluOp` 中新增 `MATADD`
   - 在 `MuxLookup` 中实现 `AluOp.MATADD -> (rs1 + rs2)`

2. `hdl/chisel/src/coralnpu/scalar/Decode.scala`
   - 在 `DecodedInstruction` 中新增 `matadd`
   - 增加解码规则：

   ```scala
   d.matadd := op === BitPat("b0101010_?????_?????_000_?????_0001011")
   ```

   - 在 ALU dispatch 中增加：

   ```scala
   d.matadd -> MakeValid(true.B, AluOp.MATADD)
   ```

   - 把 `d.matadd` 放进 `decoded = Cat(...)`

3. `hdl/chisel/src/coralnpu/scalar/AluTest.scala`
   - 新增 `MATADD` 单元测试

4. `hdl/chisel/src/coralnpu/scalar/DispatchTest.scala`
   - 新增 `DispatchV2` 测试
   - 直接验证 `matadd` 机器码是否被送到 `ALU`

## RTL 单元级验证

先跑标量单元测试：

```bash
bazel test //hdl/chisel/src/coralnpu:coralnpu_scalar_tests --test_output=all
```

最终结果：

- `AluSpec` 中 `MATADD` 通过
- `ScalarDispatchSpec` 中 `Dispatch MATADD to ALU` 通过
- 全部 `22 / 22` 测试通过

这一步说明两件事：

- `MATADD` 在 ALU 内部执行逻辑正确
- `matadd` 的机器码已经能被 `DispatchV2` 正确识别并派发到 `ALU`

## 程序级验证：`program.cc + .insn`

在 `tests/cocotb/tutorial/program.cc` 中，最终采用 `inline asm + .insn` 的方式从软件侧发射这条自定义指令，而不是先改 GCC/binutils。

核心写法如下：

```cpp
static inline uint32_t matadd(uint32_t a, uint32_t b) {
  uint32_t out;
  asm volatile(
      ".insn r 0x0b, 0x0, 0x2a, %0, %1, %2\n"
      : "=r"(out)
      : "r"(a), "r"(b));
  return out;
}
```

这里：

- `0x0b` 对应 `custom-0`
- `0x0` 对应 `funct3`
- `0x2a` 对应 `funct7`

### 补充理解：`.insn` 到底是什么

`.insn` 是 GNU 汇编器提供的一个伪指令，用来“手工描述并生成一条机器指令”。

它适合当前这种场景：

- 硬件里已经实现了自定义指令
- 但 GCC / binutils 还没有正式支持 `matadd` 这个助记符
- 这时可以先不改编译器，直接告诉汇编器按指定格式把机器码拼出来

这一句：

```cpp
.insn r 0x0b, 0x0, 0x2a, %0, %1, %2
```

含义是：

- `r`
  按 R-type 指令格式编码
- `0x0b`
  `opcode = custom-0`
- `0x0`
  `funct3`
- `0x2a`
  `funct7`
- `%0`
  放到 `rd`
- `%1`
  放到 `rs1`
- `%2`
  放到 `rs2`

也就是按下面这个 R-type 位布局去组一条指令：

```text
 31          25 24    20 19    15 14   12 11     7 6       0
+--------------+--------+--------+-------+---------+---------+
|   funct7     |  rs2   |  rs1   |funct3 |   rd    | opcode  |
|   0101010    |   %2   |   %1   | 000   |   %0    | 0001011 |
+--------------+--------+--------+-------+---------+---------+
```

### 补充理解：`%0 / %1 / %2` 为什么正好对应 `rd / rs1 / rs2`

GCC inline asm 的写法是：

```cpp
asm volatile("..."
    : 输出操作数
    : 输入操作数
    : clobber);
```

在这段代码里：

```cpp
asm volatile(
    ".insn r 0x0b, 0x0, 0x2a, %0, %1, %2\n"
    : "=r"(out)
    : "r"(a), "r"(b));
```

操作数编号规则是“先输出，再输入”，所以：

- `%0` = 第 1 个输出操作数 = `out`
- `%1` = 第 1 个输入操作数 = `a`
- `%2` = 第 2 个输入操作数 = `b`

而约束字符串：

- `"=r"(out)`
  表示给 `out` 分配一个通用寄存器，并作为写输出
- `"r"(a)`
  表示给 `a` 分配一个通用寄存器
- `"r"(b)`
  表示给 `b` 分配一个通用寄存器

所以编译器实际做的事情就是：

- 给 `out` 分一个寄存器，作为 `rd`
- 给 `a` 分一个寄存器，作为 `rs1`
- 给 `b` 分一个寄存器，作为 `rs2`

换句话说，这段代码不是固定写死 `x3/x1/x2`，而是让编译器自由分配寄存器，再由 `.insn` 按 `rd/rs1/rs2` 的位置把它们编码进 `matadd` 指令。

先编译程序：

```bash
bazel build //tests/cocotb/tutorial:coralnpu_v2_program
```

编译成功后会生成：

- `coralnpu_v2_program.elf`
- `coralnpu_v2_program.bin`
- `coralnpu_v2_program.vmem`

这一步说明：

- `program.cc` 能被 CoralNPU 专用 toolchain 编译
- `.insn` 写法被当前工具链接受

```cpp
#include <stdint.h>

uint32_t input1_buffer[1] __attribute__((section(".data")));
uint32_t input2_buffer[1] __attribute__((section(".data")));
uint32_t output_buffer[1] __attribute__((section(".data")));

static inline uint32_t matadd(uint32_t a, uint32_t b)
{
    uint32_t out;
    asm volatile(
        ".insn r 0x0b, 0x0, 0x2a, %0, %1, %2\n"
        : "=r"(out)
        : "r"(a), "r"(b));
    return out;
}

int main(int argc, char **argv)
{
    output_buffer[0] = matadd(input1_buffer[0], input2_buffer[0]);
    return 0;
}

```

### 常用查看命令：反汇编与符号表

如果想看 ELF 里的汇编，可用：

```bash
/opt/riscv/bin/riscv64-unknown-elf-objdump -dS bazel-bin/tests/cocotb/tutorial/coralnpu_v2_program.elf | less
```

这里：

- `-d`
  反汇编
- `-S`
  把源码行和汇编穿插显示

如果只想看 `main` 附近：

```bash
/opt/riscv/bin/riscv64-unknown-elf-objdump -dS bazel-bin/tests/cocotb/tutorial/coralnpu_v2_program.elf | sed -n '/<main>:/,+12p'
```

这时通常能看到：

- `lw` 从 `input1_buffer/input2_buffer` 读数据
- 一条显示为 `.insn ...` 的未知指令
- 这条未知指令实际上就是自定义的 `matadd`

例如这次看到的是：

```text
154:   54d7070b                .insn   4, 0x54d7070b
```

如果想看符号表，可用：

```bash
/opt/riscv/bin/riscv64-unknown-elf-nm -n bazel-bin/tests/cocotb/tutorial/coralnpu_v2_program.elf
```

符号表最重要的作用是确认：

- `main` 在什么地址
- `input1_buffer`
- `input2_buffer`
- `output_buffer`

例如这次的结果里：

```text
00000144 T main
00010000 D input1_buffer
00010004 D input2_buffer
00010008 D output_buffer
```

这能直接帮助理解：

- `main` 的入口位置
- 三个全局 buffer 在 `.data` 段里的实际地址布局

## cocotb 验证

在 `tests/cocotb/tutorial/tutorial.py` 中，测试流程是：

1. 载入 `coralnpu_v2_program.elf`
2. 用 `lookup_symbol` 找到 `input1_buffer`、`input2_buffer`、`output_buffer`
3. 向 DTCM 写入输入数据 `3` 和 `5`
4. 从 ELF 入口启动程序
5. 等待 core halt
6. 读回 `output_buffer`
7. 断言结果等于 `8`

```python
import cocotb
import numpy as np

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface

@cocotb.test()
async def core_mini_axi_tutorial(dut):
    """Testbench to run your CoralNPU program."""
    # Test bench setup
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/tutorial/coralnpu_v2_program.elf")
    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        inputs1_addr = core_mini_axi.lookup_symbol(f, "input1_buffer")
        inputs2_addr = core_mini_axi.lookup_symbol(f, "input2_buffer")
        outputs_addr = core_mini_axi.lookup_symbol(f, "output_buffer")

    await core_mini_axi.write(inputs1_addr, np.array([3], dtype=np.uint32))
    await core_mini_axi.write(inputs2_addr, np.array([5], dtype=np.uint32))

    await core_mini_axi.execute_from(entry_point)
    await core_mini_axi.wait_for_halted()

    rdata = (await core_mini_axi.read(outputs_addr, 4)).view(np.uint32)
    print(f"I got {rdata}")
    assert rdata[0] == 8
```
## Verilator 与 VCS 运行命令

### Verilator

```bash
bazel run //tests/cocotb/tutorial:tutorial
```

运行结果打印：

```text
I got [8]
```

### VCS

这个仓库默认在 `.bazelrc` 里屏蔽了 `vcs` tag，所以跑 VCS 时必须显式加 `--config=vcs`：

```bash
bazel test --config=vcs //tests/cocotb/tutorial:vcs_tutorial_core_mini_axi_tutorial --test_output=all
```

实际运行结果：

```text
Running on Chronologic Simulation VCS Release version ...
I got [8]
tutorial.core_mini_axi_tutorial passed
```

这一步说明：

- 程序级 `matadd` 验证已经在 **VCS** 上通过
- 从软件发射自定义指令到 RTL 执行再到结果读回，链路完整正确

## VCS + Verdi 波形观察

为了在 Verdi 里看到 `matadd` 的实际执行波形，需要重新运行一次 VCS，并保留 `sim_build`：

```bash
bazel test --config=vcs //tests/cocotb/tutorial:vcs_tutorial_core_mini_axi_tutorial --test_output=all --sandbox_debug --cache_test_results=no
```

波形文件可以用下面命令定位：

```bash
find ~/.cache/bazel/_bazel_$USER -path '*vcs_tutorial_core_mini_axi_tutorial_cocotb_runner.sh.runfiles/coralnpu_hw/sim_build/novas.fsdb'
```

进入 `sim_build` 后，用 Verdi 打开：

```bash
verdi -dbdir simv.daidir -ssf novas.fsdb &
```

这次观察最有用的一组信号是：

- `io_debug_dispatch_0_instInst`
- `decodedInsts_0_matadd`
- `_dispatch_io_alu_0_bits_op`
- `_regfile_io_readData_0_data`
- `_regfile_io_readData_1_data`
- `_alu_0_io_rd_bits_data`
- `io_debug_regfile_writeData_0_bits_data`

当前 `program.cc` 生成出来的那条 `matadd` 指令字，在这次实验里实际观察到的是：

- `0x54d7070b`

在波形里可以按下面这条链确认 `matadd` 已经真正跑通：

- `io_debug_dispatch_0_instInst == 32'h54d7070b`
- `decodedInsts_0_matadd == 1`
- `_dispatch_io_alu_0_bits_op == 5'h1`
- `_regfile_io_readData_0_data == 3`
- `_regfile_io_readData_1_data == 5`
- `_alu_0_io_rd_bits_data == 8`
- `io_debug_regfile_writeData_0_bits_data == 8`

这一步的意义是：不仅程序级结果正确，而且已经能在 `VCS + Verdi` 下直接看到 `matadd` 从取指、解码、派发、ALU 执行到写回的完整波形链路。

## 最终结论

这次 `matadd` 第一版实验已经完成了完整闭环：

- 自定义指令编码已定义
- Decode / Dispatch / ALU / Writeback 已接通
- 标量 RTL 单测通过
- `program.cc + .insn` 软件侧发射成功
- Verilator cocotb 程序级验证通过
- VCS cocotb 程序级验证通过

换句话说，这已经不只是“代码改好了”，而是：

**这个自定义指令已经被真实地编译、加载、执行，并且在 VCS 中验证得到正确结果 `8`。**

## 下一步建议

`matadd` 第一版已经完成教学闭环，接下来不建议继续在普通 `ALU` 里堆更多“伪矩阵指令”，而是正式开始 matrix extension 主线。

推荐顺序：

1. 先把 `matrix v1` 范围冻结下来
   - 只做最小 `subset`
   - 先把 CSR、decode、dispatch、执行通路打通
2. 先建立独立 `MatrixUnit`
   - 不再把 matrix 语义长期留在 `ALU`
3. 先让 `matadd` 成为 matrix 通路入口
   - 后面再逐步扩展到 `msettile* / mld / mst / mmacc`
4. 最后再考虑软件工具链
   - GCC / binutils / intrinsic / 编译器适配放到 RTL 闭环之后
