"""Record PE decisions before each active edge without changing the RTL."""

import csv
import importlib.util
import os
from pathlib import Path

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly
from cocotb.utils import get_sim_time
from bazel_tools.tools.python.runfiles import runfiles


PE_SIGNALS = """
rst_n state cmd_valid_i cmd_ready_o cmd_rob_age_i cmd_accept cmd_retire
cfg_m_i cfg_n_i cfg_k_i rs1_i rs2_i rd_i
age_full age_empty cmd_decode_busy tiling_start_q
stream_pop stream_active stream_issue_active stream_count stream_last
stream_rd stream_rs1 stream_act_col stream_m_rows
stream_boundary_bubble_q stream_start_pending_q next_stream_ready
stream_start_age_q stream_overlap_done weight_overlap_done
tiling_weight_empty tiling_act_psum_empty tiling_act_psum_last
tiling_rd tiling_act_col tiling_act_nblock tiling_act_psum_m_rows
weight_pop weight_load_active weight_load_start weight_read_last
weight_done_now stream_done_now weight_count weight_n_rows
weight_bank_available weight_banks_busy_q
rd_read_valid_o rd_read_o rd_read_addr_o rd_read_nblock_o
rd_data_valid_i rd_data_i rd_zero_block_q
rd_write_valid_o rd_write_o rd_write_addr_o rd_write_nblock_o
pe_array_o cmd_writeback_done done_valid_o done_ready_i done_rob_age_o
""".split()

C_SIGNALS = """
rd_en_i rd_accept_w rd_wr_conflict_w rd_dma_conflict_w
rd_reg_i rd_addr_i rd_nblock_i rd_valid_o rd_data_o
wr_en_i wr_accept_w wr_reg_i wr_addr_i wr_nblock_i wr_data_i
dma_wr_en_i dma_wr_reg_i dma_wr_addr_i dma_wr_half_i
c_reg_zero_n
""".split()

MEM_SIGNALS = """
mem_valid_i mem_ready_o mem_rob_age_i mem_op_i mem_reg_i
mem_base_i mem_stride_i mem_rows_i mem_cols_i
done_valid_o done_rob_age_o done_is_mem_o zero_valid_i zero_ready_o
""".split()


@cocotb.test()
async def gemm_m65_n257_k65_backpressure_diagnostic(dut):
    helper_path = runfiles.Create().Rlocation(
        "coralnpu_hw/tests/cocotb/matrix_cpu_dma_test.py")
    spec = importlib.util.spec_from_file_location("matrix_cpu_dma_test", helper_path)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    matrix = dut.core.matrixCore.matrixCore
    pe = matrix.u_pe_ctrl
    c_regs = matrix.c_regfile
    handles = {}
    for prefix, scope, names in (
            ("pe", pe, PE_SIGNALS), ("c", c_regs, C_SIGNALS),
            ("mem", matrix, MEM_SIGNALS)):
        handles.update((f"{prefix}.{name}", getattr(scope, name)) for name in names)
    scoreboard = dut.core.score.matrixScoreboard
    handles.update((f"sb.{handle._name}", handle)
                   for handle in scoreboard if handle._name.startswith("io_"))

    output_dir = Path(os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR", "."))
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / "matrix_gemm_cycles.csv"
    collisions = []

    async def record(writer):
        cycle = 0
        while True:
            await FallingEdge(dut.io_aclk)
            await ReadOnly()
            values = {name: int(handle.value) for name, handle in handles.items()}
            ns = float(get_sim_time(unit="ns"))
            writer.writerow({"cycle": cycle, "ns": ns, **values})
            if (values["pe.rst_n"] and values["c.rd_en_i"] and
                    values["c.rd_wr_conflict_w"]):
                event = (cycle, ns, values["c.rd_reg_i"],
                         values["c.rd_addr_i"], values["c.wr_addr_i"])
                collisions.append(event)
                dut._log.warning(
                    "C read rejected: cycle=%d ns=%.3f C=%d read_row=%d write_row=%d",
                    *event)
            cycle += 1

    with path.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=["cycle", "ns", *handles])
        writer.writeheader()
        task = cocotb.start_soon(record(writer))
        try:
            await helper._run_c_api_elf_multicreg_gemm(
                dut, 65, 257, 65, "matrix_c_api_gemm_m65_n257_k65_program",
                dense=True, stalled=True)
        finally:
            task.cancel()
            dut._log.info("PE cycle trace: %s; rejected C reads=%s", path, collisions)
