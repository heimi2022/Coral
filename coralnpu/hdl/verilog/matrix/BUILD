load("@rules_hdl//verilog:providers.bzl", "verilog_library")

exports_files(
    srcs = [
        "MatrixCore.sv",
        "DW01_add.sv",
        "FPPA.sv",
        "accumulaters.sv",
        "fifo.sv",
        "matmul_tiling.sv",
        "pe_array.sv",
        "pe_ctrl.sv",
        "pe_ws.sv",
    ],
    visibility = ["//hdl/chisel/src/coralnpu:__pkg__", "//tests/cocotb:__pkg__"],
)

filegroup(
    name = "matrix_rtl",
    srcs = glob(["*.sv"], exclude = ["*_tb.sv"]),
    visibility = ["//hdl/chisel/src/coralnpu:__pkg__"],
)
