package(default_visibility = ["//visibility:public"])

cc_test(
    name = "coral_matrix_gemm_schedule_test",
    srcs = ["coral_matrix_gemm_schedule_test.cc"],
    deps = ["//include:coral_matrix_gemm", "//include:coral_matrix_gemm_layout"],
)

cc_test(
    name = "coral_matrix_gemm_layout_test",
    srcs = ["coral_matrix_gemm_layout_test.cc"],
    deps = ["//include:coral_matrix_gemm", "//include:coral_matrix_gemm_layout"],
)

cc_test(
    name = "coral_matrix_tiling_test",
    srcs = ["coral_matrix_tiling_test.cc"],
    deps = ["//include:coral_matrix_tiling"],
)

cc_test(
    name = "coral_matrix_ab_allocator_test",
    srcs = ["coral_matrix_ab_allocator_test.cc"],
    deps = [
        "//include:coral_matrix_ab_allocator",
        "//include:coral_matrix_tiling",
    ],
)
