load("@rules_hdl//verilog:providers.bzl", "verilog_library")

exports_files(
    srcs = ["MatrixCore.sv"],
    visibility = ["//hdl/chisel/src/coralnpu:__pkg__"],
)

filegroup(
    name = "matrix_rtl",
    srcs = glob(["*.sv"], exclude = ["*_tb.sv"]),
    visibility = ["//hdl/chisel/src/coralnpu:__pkg__"],
)
