load("//rules:coco_tb.bzl", "cocotb_test_suite", "verilator_cocotb_model")
load("//tests/cocotb:build_defs.bzl", "VERILATOR_BUILD_ARGS")

verilator_cocotb_model(
    name = "matrix_gemm_model",
    trace = False,
    make_args = ["OPT_FAST=-O0"],
    make_jobs = 1,
    cflags = [flag for flag in VERILATOR_BUILD_ARGS if flag != "-DZVE32F_ON"] + ["-Wno-fatal"],
    hdl_toplevel = "MatrixCoreMiniAxi",
    verilog_source = "//hdl/chisel/src/coralnpu:MatrixCoreMiniAxi.sv",
    vlt_tpl = "matrix_gemm.vlt.tpl",
)

cocotb_test_suite(
    name = "matrix_gemm",
    simulators = ["verilator"],
    testcases = ["gemm_m65_n257_k65_backpressure_diagnostic"],
    verilator_model = ":matrix_gemm_model",
    tests_kwargs = {
        "hdl_toplevel": "MatrixCoreMiniAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["matrix_gemm_diagnostic_test.py"],
        "deps": ["//coralnpu_test_utils:core_mini_axi_sim_interface"],
        "data": [
            "//tests/cocotb:matrix_c_api_gemm_m65_n257_k65_program",
            "//tests/cocotb:matrix_cpu_dma_test.py",
        ],
        "size": "large",
        "tags": ["manual"],
    },
)
