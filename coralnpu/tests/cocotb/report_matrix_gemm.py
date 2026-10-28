#!/usr/bin/env python3
"""Write a GEMM performance report from verified DRAMsim3 run artifacts."""

import argparse
import configparser
import hashlib
import json
import math
from pathlib import Path


def write_report(directory, started_ns=0):
    directory = Path(directory)
    metrics_path = directory / "gemm_metrics.json"
    backend_path = directory / "dramsim3_backend.json"
    for path in (metrics_path, backend_path):
        if not path.is_file() or path.stat().st_mtime_ns < started_ns:
            raise ValueError(f"Missing fresh run artifact: {path}")
    metrics = json.loads(metrics_path.read_text())
    backend = json.loads(backend_path.read_text())
    memory = metrics["memory"]
    if metrics.get("verified") is not True or memory["model"] != "dramsim3":
        raise ValueError("Report requires functionally verified DRAMsim3 metrics")
    config_path = Path(backend["config"])
    config_hash = hashlib.sha256(config_path.read_bytes()).hexdigest()
    if config_hash != backend["config_sha256"]:
        raise ValueError("DRAMsim3 config changed after the run")
    if Path(memory["config"]).resolve() != config_path.resolve():
        raise ValueError("Metrics and backend metadata refer to different configs")
    config = configparser.ConfigParser()
    config.read(config_path)
    tck = config.getfloat("timing", "tCK")
    shared_peak = (config.getint("system", "channels") *
                   config.getint("system", "bus_width") / 8 * 2 / tck)
    if not math.isclose(shared_peak, memory["ddr_peak_gb_per_s_shared"]):
        raise ValueError("Config bandwidth disagrees with measured model metadata")
    cycles = metrics["elapsed_cycles"]
    clock_ns = metrics["clock_ns"]
    macs = metrics["m"] * metrics["k"] * metrics["n"]
    if cycles <= 0 or clock_ns <= 0 or macs != metrics["logical_macs"]:
        raise ValueError("Invalid GEMM dimensions, timing or MAC count")
    macs_per_cycle = macs / cycles
    if not math.isclose(macs_per_cycle, metrics["logical_macs_per_cycle"]):
        raise ValueError("MAC/cycle disagrees with cycle and MAC counts")
    duration_ns = cycles * clock_ns
    read_bytes = metrics["axi_read_bytes"]
    write_bytes = metrics["axi_write_bytes"]
    text = f"""# MatrixCore GEMM / DRAMsim3 性能报告

功能校验：PASS（输出、AXI 事务和矩阵指令计数由测试校验）。

| 实验条件 | 配置 |
| --- | --- |
| 矩阵形状 M / K / N | {metrics['m']} / {metrics['k']} / {metrics['n']} |
| 核 / AXI 时钟 | {1000 / clock_ns:g} MHz，{clock_ns:g} ns/cycle |
| AXI 数据宽度 | {memory['axi_bus_bits']} bit |
| DDR 读写共享物理峰值 | {shared_peak:g} GB/s（十进制） |
| DDR 通道数 / 每通道宽度 / BL | {memory['ddr_channels']} / {memory['ddr_bus_bits_per_channel']} bit / {memory['ddr_burst_length']} |
| DDR tCK | {tck:g} ns |
| DDR 地址映射 | `{config['system']['address_mapping']}` |
| 输入数据 | {'dense' if metrics['dense'] else 'sparse deterministic'} |
| 测试额外注入 AXI 背压 | {metrics['stalled']} |

| 实测指标 | 结果 |
| --- | ---: |
| Logical MAC 总数 | {macs:,} |
| 总执行周期 | {cycles:,} |
| 执行时间 | {duration_ns / 1000:.3f} us |
| Logical MACs/cycle | **{macs_per_cycle:.3f}** |
| 相对 32×32 PE、1024 MAC/cycle 的端到端利用率 | **{macs_per_cycle / 1024 * 100:.2f}%** |
| Logical MAC 吞吐量 | {macs_per_cycle / clock_ns:.3f} GMAC/s |
| AXI 读流量 | {read_bytes:,} B，{metrics['axi_read_beats']:,} beat |
| AXI 写流量 | {write_bytes:,} B，{metrics['axi_write_beats']:,} beat |
| 执行窗口内平均 AXI 读速率 | {read_bytes / duration_ns:.3f} GB/s |
| 执行窗口内平均 AXI 写速率 | {write_bytes / duration_ns:.3f} GB/s |
| 执行窗口内平均 AXI 合计速率 | {(read_bytes + write_bytes) / duration_ns:.3f} GB/s |
| 已发射且未退休 MATMUL 峰值 | {metrics['peak_dispatched_unretired_matmuls']} |

测量窗口：{metrics['measurement']}。包含启动、标量控制、DMA 和 C 写回。
Logical MAC 按完整 M×K×N 计数；sparse 输入不代表稀疏加速。
利用率是逻辑吞吐量相对阵列峰值的比值，不是逐 PE 活跃时间统计。
平均 AXI 速率不是物理 DDR 总线忙碌占比。共享峰值不保证 C 写回时
仍持续提供同等读带宽。DRAMsim3 写回调可能先于物理 WRITE 完成，
本指标不额外包含后端物理写队列排空时间。这是仿真结果。

配置：`{config_path}`

配置 SHA256：`{config_hash}`

后端：`{backend['backend']}`

后端 SHA256：`{backend['backend_sha256']}`

原始指标：`{metrics_path}`；运行日志：`{directory / 'test.log'}`。
"""
    output = directory / "gemm_report.md"
    output.write_text(text)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--started-ns", type=int, default=0)
    args = parser.parse_args()
    print("GEMM report:", write_report(args.directory, args.started_ns))


if __name__ == "__main__":
    main()
