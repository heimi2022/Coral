# DRAMsim3 后端粒度配置

这份说明用于区分两件事：

- 前端 AXI beat 宽度
- DRAMsim3 后端一次 transaction 的目标粒度

在 DRAMsim3 里，后端请求粒度由下面这个公式决定：

```text
request_size_bytes = bus_width / 8 * BL
```

对应源码位置：

- `coralnpu/hdl/DRAMsim3/src/configuration.cc`

## 已生成的三档配置

路径都在：

- `coralnpu/hdl/verilog/SIM/dramsim3/configs/`

三档分别是：

- `ST-1.2x_32B.ini`
  - `bus_width = 64`
  - `BL = 4`
  - 后端粒度 = `32B = 256b`

- `ST-1.2x_64B.ini`
  - `bus_width = 64`
  - `BL = 8`
  - 后端粒度 = `64B = 512b`

- `ST-1.2x_128B.ini`
  - `bus_width = 64`
  - `BL = 16`
  - 后端粒度 = `128B = 1024b`
  - 这一档更适合当“后端抽象目标粒度”，不是常见 DDR3 默认配置

## 推荐对应关系

如果想让当前这版 `Axi4DdrDramsim3Slave` 语义最顺：

- 32B 后端粒度，建议配 `AXI_DATA_W = 256`
- 64B 后端粒度，建议配 `AXI_DATA_W = 512`
- 128B 后端粒度，建议配 `AXI_DATA_W = 1024`

原因是当前 wrapper 还是按“一个前端 mem beat 对应一笔后端事务”来走。
所以当前最严格、最干净的用法，是让：

```text
AXI beat bytes == DRAMsim3 request_size_bytes
```

## 使用方式

`Axi4DdrDramsim3Slave.sv` 已经支持通过 plusarg 切换配置：

```text
+dramsim3_ini=/home/wjj/2-NPU/coralnpu/hdl/verilog/SIM/dramsim3/configs/ST-1.2x_64B.ini
```

也可以直接改模块参数 `DEFAULT_CONFIG_FILE`。

如果 `DEFAULT_CONFIG_FILE == ""`，当前代码会按 `DRAM_BACKEND_GRAN_BYTES`
自动选择配置文件，优先级如下：

1. `+dramsim3_ini=...`
2. `DEFAULT_CONFIG_FILE`
3. `DRAM_BACKEND_GRAN_BYTES` 自动选择

当前默认映射是：

- `DRAM_BACKEND_GRAN_BYTES = 32` -> `ST-1.2x_32B.ini`
- `DRAM_BACKEND_GRAN_BYTES = 64` -> `ST-1.2x_64B.ini`
- `DRAM_BACKEND_GRAN_BYTES = 128` -> `ST-1.2x_128B.ini`

在 `Axi4DdrDramsim3Slave.sv` / `matrix_dmem_dramsim3.sv` / 编译 harness
里，还额外给了一个默认启发式：

- `AXI_DATA_W < 512` 默认映射到 `32B`
- `512 <= AXI_DATA_W < 1024` 默认映射到 `64B`
- `AXI_DATA_W >= 1024` 默认映射到 `128B`

## 当前边界

当前这版已经能做到：

- 切换 32B / 64B / 128B 三档后端 transaction 粒度
- 用同一套 DRAMsim3 本体代码运行

当前这版还没有做到：

- 当 `AXI beat bytes` 和 `后端 request_size_bytes` 不相等时，自动做严格的 split / merge

如果后面要支持：

- `128b AXI` 对 `64B/128B 后端`
- `512b AXI` 对 `32B 后端`

那就要继续在 `Axi4DdrDramsim3Slave.sv` 或 DPI bridge 里补事务拆分/聚合逻辑。
