load("@rules_hdl//verilog:providers.bzl", "verilog_library")

exports_files(
    srcs = glob(["*.sv"]),
    visibility = ["//visibility:public"],
)

verilog_library(
    name = "matrix_regfile",
    srcs = ["MatrixRegFile.sv"],
    visibility = ["//visibility:public"],
)

verilog_library(
    name = "matrix_pe32_int8",
    srcs = ["MatrixPE32Int8.sv"],
    visibility = ["//visibility:public"],
)

verilog_library(
    name = "matrix_mac_array",
    srcs = ["MatrixMacArray.sv"],
    visibility = ["//visibility:public"],
    deps = [
        ":matrix_pe32_int8",
    ],
)

verilog_library(
    name = "matrix_core",
    srcs = ["MatrixCore.sv"],
    visibility = ["//visibility:public"],
    deps = [
        ":matrix_mac_array",
        ":matrix_regfile",
    ],
)
