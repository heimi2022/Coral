load("//rules:coco_tb.bzl", "cocotb_test_suite", "verilator_cocotb_model")
load("//tests/cocotb:build_defs.bzl", "VERILATOR_BUILD_ARGS")

package(default_visibility = ["//tests/cocotb:__pkg__"])

# Keep functional regressions independent of the memory-heavy waveform model.
verilator_cocotb_model(
    name = "matrix_cpu_dma_model",
    trace = False,
    make_args = ["OPT_FAST=-O0"],
    make_jobs = 1,
    cflags = [flag for flag in VERILATOR_BUILD_ARGS if flag != "-DZVE32F_ON"] + ["-Wno-fatal"],
    hdl_toplevel = "MatrixCoreMiniAxi",
    verilog_source = "//hdl/chisel/src/coralnpu:MatrixCoreMiniAxi.sv",
)

# Reuse the original test cases without compiling waveform instrumentation.
cocotb_test_suite(
    name = "matrix_cpu_dma",
    simulators = ["verilator"],
    testcases = [
        "c_api_elf_matmul",
        "matrix_cfg_overlap",
        "matrix_cfg_overlap_backpressure",
        "matrix_cfg_overlap_n_boundary",
        "matmul_store_pending_scalar_rvv",
    ],
    verilator_model = ":matrix_cpu_dma_model",
    tests_kwargs = {
        "hdl_toplevel": "MatrixCoreMiniAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["//tests/cocotb:matrix_cpu_dma_test.py"],
        "deps": ["//coralnpu_test_utils:core_mini_axi_sim_interface"],
        "data": [
            "//tests/cocotb:matrix_c_api_dma_program",
            "//tests/cocotb:matrix_c_api_matmul_program",
            "//tests/cocotb:matrix_c_api_gemm_program",
        ],
        "size": "large",
    },
)
