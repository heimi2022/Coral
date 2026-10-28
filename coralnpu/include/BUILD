exports_files(["coral_matrix.h", "coral_matrix_ab_allocator.h",
               "coral_matrix_gemm.h", "coral_matrix_gemm_layout.h",
               "coral_matrix_tiling.h"])

cc_library(
    name = "coral_matrix_gemm_layout",
    hdrs = ["coral_matrix_gemm_layout.h"],
    deps = [":coral_matrix_tiling"],
    includes = ["."],
    visibility = ["//visibility:public"],
)

cc_library(
    name = "coral_matrix_gemm",
    hdrs = ["coral_matrix.h", "coral_matrix_gemm.h"],
    deps = [":coral_matrix_tiling"],
    includes = ["."],
    visibility = ["//visibility:public"],
)

cc_library(
    name = "coral_matrix_ab_allocator",
    hdrs = ["coral_matrix_ab_allocator.h"],
    includes = ["."],
    visibility = ["//visibility:public"],
)

cc_library(
    name = "coral_matrix_tiling",
    hdrs = ["coral_matrix_tiling.h"],
    includes = ["."],
    visibility = ["//visibility:public"],
)
