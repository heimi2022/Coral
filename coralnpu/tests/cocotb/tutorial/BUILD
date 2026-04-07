# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("//rules:coco_tb.bzl", "cocotb_test_suite")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//rules:utils.bzl", "generate_cc_arrays")
load(
    "//tests/cocotb:build_defs.bzl",
    "VCS_BUILD_ARGS",
    "VCS_DEFINES",
    "VCS_TEST_ARGS",
)

# BEGIN_TESTCASES_FOR_tutorial
TUTORIAL_TESTCASES = [
    "core_mini_axi_tutorial",
]
# END_TESTCASES_FOR_tutorial

# BEGIN_TESTCASES_FOR_hello_world_float_core_mini_axi
HELLO_WORLD_TESTCASES = [
    "core_mini_axi_tutorial",
]
# END_TESTCASES_FOR_hello_world_float_core_mini_axi

# BEGIN_TESTCASES_FOR_matrix_cfg
MATRIX_CFG_TESTCASES = [
    "core_mini_axi_matrix_cfg",
]
# END_TESTCASES_FOR_matrix_cfg

# BEGIN_TESTCASES_FOR_matrix_csr
MATRIX_CSR_TESTCASES = [
    "core_mini_axi_matrix_csr",
]
# END_TESTCASES_FOR_matrix_csr

# BEGIN_TESTCASES_FOR_matrix_mmacc_rob
MATRIX_MMACC_ROB_TESTCASES = [
    "core_mini_axi_matrix_mmacc_rob",
]
# END_TESTCASES_FOR_matrix_mmacc_rob

# BEGIN_TESTCASES_FOR_matrix_mmacc_arith
MATRIX_MMACC_ARITH_TESTCASES = [
    "core_mini_axi_matrix_mmacc_arith",
]
# END_TESTCASES_FOR_matrix_mmacc_arith

cocotb_test_suite(
    name = "tutorial",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = TUTORIAL_TESTCASES,
    testcases_vname = "TUTORIAL_TESTCASES",
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "CoreMiniAxi",
        "seed": "42",
        "test_module": ["tutorial.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "@rules_python//python/runfiles",
        ],
        "data": [":coralnpu_v2_program"],
        "size": "small",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":coralnpu_v2_program",
        "//tests/cocotb:coverage_exclude.cfg",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:core_mini_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:core_mini_axi_model",
)

cocotb_test_suite(
    name = "hello_world_float_core_mini_axi",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = HELLO_WORLD_TESTCASES,
    testcases_vname = "HELLO_WORLD_TESTCASES",
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "CoreMiniAxi",
        "seed": "42",
        "test_module": ["hello_world_float_core_mini_axi.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": ["//examples:coralnpu_v2_hello_world_add_floats.elf"],
        "size": "small",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        "//examples:coralnpu_v2_hello_world_add_floats.elf",
        "//tests/cocotb:coverage_exclude.cfg",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:core_mini_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:core_mini_axi_model",
)

cocotb_test_suite(
    name = "matrix_cfg",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = MATRIX_CFG_TESTCASES,
    testcases_vname = "MATRIX_CFG_TESTCASES",
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "CoreMiniAxi",
        "seed": "42",
        "test_module": ["matrix_cfg.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "@rules_python//python/runfiles",
        ],
        "data": [":matrix_cfg_program"],
        "size": "small",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":matrix_cfg_program",
        "//tests/cocotb:coverage_exclude.cfg",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:core_mini_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:core_mini_axi_model",
)

cocotb_test_suite(
    name = "matrix_csr",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = MATRIX_CSR_TESTCASES,
    testcases_vname = "MATRIX_CSR_TESTCASES",
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "CoreMiniAxi",
        "seed": "42",
        "test_module": ["matrix_csr.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "@rules_python//python/runfiles",
        ],
        "data": [":matrix_csr_program"],
        "size": "small",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":matrix_csr_program",
        "//tests/cocotb:coverage_exclude.cfg",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:core_mini_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:core_mini_axi_model",
)

cocotb_test_suite(
    name = "matrix_mmacc_rob",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = MATRIX_MMACC_ROB_TESTCASES,
    testcases_vname = "MATRIX_MMACC_ROB_TESTCASES",
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "CoreMiniAxi",
        "seed": "42",
        "test_module": ["matrix_mmacc_rob.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "@rules_python//python/runfiles",
        ],
        "data": [":matrix_mmacc_rob_program"],
        "size": "small",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":matrix_mmacc_rob_program",
        "//tests/cocotb:coverage_exclude.cfg",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:core_mini_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:core_mini_axi_model",
)

cocotb_test_suite(
    name = "matrix_mmacc_arith",
    simulators = [
        "vcs",
    ],
    testcases = MATRIX_MMACC_ARITH_TESTCASES,
    testcases_vname = "MATRIX_MMACC_ARITH_TESTCASES",
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "CoreMiniAxi",
        "seed": "42",
        "test_module": ["matrix_mmacc_arith.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "@rules_python//python/runfiles",
        ],
        "data": [":matrix_mmacc_arith_program"],
        "size": "small",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":matrix_mmacc_arith_program",
        "//tests/cocotb:coverage_exclude.cfg",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:core_mini_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:core_mini_axi_model",
)

coralnpu_v2_binary(
    name = "coralnpu_v2_program",
    srcs = ["program.cc"],
)

coralnpu_v2_binary(
    name = "matrix_cfg_program",
    srcs = ["matrix_cfg_program.cc"],
)

coralnpu_v2_binary(
    name = "matrix_csr_program",
    srcs = ["matrix_csr_program.cc"],
)

coralnpu_v2_binary(
    name = "matrix_mmacc_rob_program",
    srcs = ["matrix_mmacc_rob_program.cc"],
)

coralnpu_v2_binary(
    name = "matrix_mmacc_arith_program",
    srcs = ["matrix_mmacc_arith_program.cc"],
)

coralnpu_v2_binary(
    name = "tflite_micro_test",
    srcs = [
        "hello_world_tflite_cc",
        "tflite_micro_test.cc",
    ],
    hdrs = ["hello_world_tflite.h"],
    itcm_size_kbytes = 1024,  # Highmem
    dtcm_size_kbytes = 1024,  # Highmem
    deps = [
        "@tflite_micro//tensorflow/lite/micro:micro_framework",
        "@tflite_micro//tensorflow/lite/micro:micro_log",
        "@tflite_micro//tensorflow/lite/micro:micro_profiler",
        "@tflite_micro//tensorflow/lite/micro:op_resolvers",
        "@tflite_micro//tensorflow/lite/micro:system_setup",
    ],
)

generate_cc_arrays(
    name = "hello_world_tflite_cc",
    src = "@tflite_micro//tensorflow/lite/micro/examples/hello_world/models:hello_world_int8.tflite",
    out = "hello_world_tflite.cc",
)

generate_cc_arrays(
    name = "hello_world_tflite_h",
    src = "@tflite_micro//tensorflow/lite/micro/examples/hello_world/models:hello_world_int8.tflite",
    out = "hello_world_tflite.h",
)
