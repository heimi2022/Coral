# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

import sys

import numpy as np
import pytest
import scipy
from scipy import special

import tvm
import tvm.testing
import tvm.topi.testing

from tvm import te, topi
from tvm.topi import utils


def test_util():
    x = tvm.tir.const(100, "int32")
    assert utils.get_const_int(x) == 100
    assert utils.get_const_tuple((x, x)) == (100, 100)


ewise_operations = {
    "floor": {"topi": topi.floor, "ref": np.floor, "input_range": (-100, 100)},
    "ceil": {"topi": topi.ceil, "ref": np.ceil, "input_range": (-100, 100)},
    "sign": {
        "topi": topi.sign,
        "ref": np.sign,
        "input_range": (-100, 100),
        "skip_name_check": True,
    },
    "trunc": {"topi": topi.trunc, "ref": np.trunc, "input_range": (-100, 100)},
    "fabs": {"topi": topi.abs, "ref": np.fabs, "input_range": (-100, 100)},
    "round": {"topi": topi.round, "ref": np.round, "input_range": (-100, 100), "check_round": True},
    "exp": {"topi": topi.exp, "ref": np.exp, "input_range": (-1, 1)},
    "tanh": {
        "topi": topi.tanh,
        "ref": np.tanh,
        "input_range": (-10, 10),
        "shape": (128, 128),
        "dtype": ["float32", "float64"],
    },
    "sigmoid": {
        "topi": topi.sigmoid,
        "ref": lambda x: 1 / (1 + np.exp(-x)),
        "input_range": (-1, 1),
    },
    "log": {"topi": topi.log, "ref": np.log, "input_range": (0, 100)},
    "sqrt": {"topi": topi.sqrt, "ref": np.sqrt, "input_range": (0, 100)},
    "rsqrt": {
        "topi": topi.rsqrt,
        "ref": lambda x: np.ones_like(x) / np.sqrt(x),
        "input_range": (0, 100),
        "skip_name_check": True,
    },
    "cos": {"topi": topi.cos, "ref": np.cos, "input_range": (-2.0 * np.pi, 2.0 * np.pi)},
    "tan": {
        "topi": topi.tan,
        "ref": np.tan,
        "input_range": (-2.0 * np.pi, 2.0 * np.pi),
        "dtypes": ["float32", "float64"],
    },
    "sin": {"topi": topi.sin, "ref": np.sin, "input_range": (-2.0 * np.pi, 2.0 * np.pi)},
    "erf": {"topi": topi.erf, "ref": scipy.special.erf, "input_range": (-0.1, 0.1)},
    "isnan": {
        "topi": topi.isnan,
        "ref": np.isnan,
        "input_range": (-1, 1),
        "replace_with_nan": True,
    },
    "isfinite": {
        "topi": topi.isfinite,
        "ref": np.isfinite,
        "input_range": (0, 1),
        "shape": (8, 8),
        "skip_name_check": True,
        "replace_with_nan": True,
        "replace_with_inf": True,
        "dtypes": ["float32", "float64", "int32", "int16"],
    },
    "isinf": {
        "topi": topi.isinf,
        "ref": np.isinf,
        "input_range": (0, 1),
        "shape": (8, 8),
        "skip_name_check": True,
        "replace_with_nan": True,
        "replace_with_inf": True,
        "dtypes": ["float32", "float64", "int32", "int16"],
    },
    "fast_exp": {
        "topi": topi.fast_exp,
        "ref": np.exp,
        "skip_name_check": True,
        "input_range": (-88, 88),
        "step": 0.01,
    },
    "fast_erf": {
        "topi": topi.fast_erf,
        "ref": scipy.special.erf,
        "skip_name_check": True,
        "input_range": (-10, 10),
        "step": 0.01,
        "dtypes": ["float32", "float16"],
        "cast_output": True,
        "tolerance": [1e-5, 1e-1],
    },
    "fast_tanh": {
        "topi": topi.fast_tanh,
        "ref": np.tanh,
        "skip_name_check": True,
        "input_range": (-10, 10),
        "step": 0.01,
    },
}

topi_name, dtype, tolerance = tvm.testing.parameters(
    *[
        (name, dtype, config.get("tolerance", [1e-5] * len(dtype))[i])
        for name, config in ewise_operations.items()
        for i, dtype in enumerate(config.get("dtypes", ["float32"]))
    ]
)


@tvm.testing.fixture(cache_return_value=True)
def ewise_ref_data(topi_name, dtype):
    config = ewise_operations[topi_name]

    input_range = config["input_range"]
    shape = config.get("shape", (20, 3))

    a_np = np.random.uniform(*input_range, size=shape).astype(dtype)

    if dtype.startswith("float"):
        if config.get("replace_with_nan", False):
            a_np.ravel()[np.random.choice(a_np.size, int(a_np.size * 0.5), replace=False)] = np.nan
        if config.get("replace_with_inf", False):
            a_np.ravel()[
                np.random.choice(a_np.size, int(a_np.size * 0.5), replace=False)
            ] = np.infty

    # avoid round check too close to boundary
    if topi_name == "round":
        a_np += ((np.abs(np.fmod(a_np, 1)) - 0.5) < 1e-6) * 1e-4

    b_np = config["ref"](a_np)

    if config.get("cast_output", False):
        b_np = b_np.astype(dtype)

    return a_np, b_np


def test_ewise(target, dev, topi_name, dtype, tolerance, ewise_ref_data):
    target = tvm.target.Target(target)
    if target.kind.name == "vulkan" and topi_name in ["tan", "erf", "isnan", "isfinite", "isinf"]:
        pytest.xfail(f"Vulkan runtime doesn't support {topi_name} yet")

    topi_op = ewise_operations[topi_name]["topi"]
    skip_name_check = ewise_operations[topi_name].get("skip_name_check", False)

    m = te.var("m")
    l = te.var("l")
    A = te.placeholder((m, l), dtype=dtype, name="A")

    B = topi_op(A)
    assert tuple(B.shape) == tuple(A.shape)
    if not skip_name_check:
        assert B.op.body[0].op.name == "tir." + topi_name

    a_np, b_np = ewise_ref_data

    with tvm.target.Target(target):
        s = tvm.topi.testing.get_injective_schedule(target)(B)
    foo = tvm.build(s, [A, B], target, name=topi_name)
    a = tvm.nd.array(a_np, dev)
    b = tvm.nd.array(np.zeros_like(b_np), dev)
    foo(a, b)
    tvm.testing.assert_allclose(b.numpy(), b_np, rtol=tolerance, atol=tolerance)


from_dtype, to_dtype = tvm.testing.parameters(
    ("int32", "float32"),
    ("int32", "float64"),
    ("int32", "bool"),
    ("float32", "int32"),
    ("float32", "float64"),
    ("float32", "bool"),
    ("bool", "float32"),
    ("bool", "int32"),
)


@tvm.testing.fixture(cache_return_value=True)
def cast_ref_data(from_dtype, to_dtype):
    shape = (5, 4)
    input_range = (-100, 100)

    if from_dtype == "bool":
        a_np = np.random.choice([True, False], size=shape)
    else:
        a_np = np.random.uniform(*input_range, size=shape).astype(from_dtype)

    if to_dtype == "bool":
        a_np = a_np - a_np[2, 3]
    b_np = a_np.astype(to_dtype)

    return a_np, b_np


def test_cast(target, dev, cast_ref_data, from_dtype, to_dtype):
    m = te.var("m")
    l = te.var("l")
    A = te.placeholder((m, l), dtype=from_dtype, name="A")
    B = topi.cast(A, to_dtype)

    a_np, b_np = cast_ref_data

    with tvm.target.Target(target):
        s = tvm.topi.testing.get_injective_schedule(target)(B)
    foo = tvm.build(s, [A, B], target)
    a = tvm.nd.array(a_np, dev)
    b = tvm.nd.empty(b_np.shape, dtype=to_dtype, device=dev)
    foo(a, b)
    tvm.testing.assert_allclose(b.numpy(), b_np)


def verify_segment(name, np_data, np_segment_ids, np_out):
    device = "llvm"
    ctx = tvm.context(device, 0)
    print("Running on target: %s" % device)
    data = te.placeholder(np_data.shape)
    segment_ids = te.placeholder(np_segment_ids.shape, dtype="int32")
    num_out = np_segment_ids[-1] + 1
    with tvm.target.Target(device):
        fcompute, fschedule = tvm.topi.testing.dispatch(
            device,
            {
                "generic": (topi.segment_op, topi.generic.schedule_segment_op),
            },
        )
        out = fcompute(data, segment_ids, num_out, name)
        s = fschedule(out)
        f = tvm.build(s, [data, segment_ids, out], device)
        tvm_data = tvm.nd.array(np_data, ctx=ctx)
        tvm_segment_ids = tvm.nd.array(np_segment_ids, ctx=ctx)
        tvm_out = tvm.nd.empty(ctx=ctx, shape=out.shape, dtype=out.dtype)
        f(tvm_data, tvm_segment_ids, tvm_out)
        tvm.testing.assert_allclose(tvm_out.asnumpy(), np_out, rtol=1e-4)


def test_segment():
    # segmet_max, segmet_min, segmet_mean, segmet_sum, segmet_prod
    np_data = np.array([0, 0.8, 1, 20, -25, 45, 1, 0.7, -30, 60, 50, 80]).astype("float32")
    segment_ids = np.array([0, 1, 1, 2, 2, 2, 3, 4, 5, 5, 5, 6]).astype("int32")
    np_result = np.array([0, 1, 45, 1, 0.7, 60, 80])
    verify_segment("max", np_data, segment_ids, np_result)

    np_data = np.array(
        [
            [0, 0.8, 1, 20, -25, 45],
            [1, 0.7, 30, 60, 50, 80],
            [0, 0.4, 4, 21, 19, 40],
            [2, -0.9, 35, 61, 52, 79],
            [1, 0.5, 100, 60, 70, 110],
        ]
    ).astype("float32")
    segment_ids = np.array([0, 0, 1, 1, 2]).astype("int32")
    np_result = np.array(
        [
            [1, 0.8, 30, 60, 50, 80],
            [2, 0.4, 35, 61, 52, 79],
            [1, 0.5, 100, 60, 70, 110],
        ]
    )
    verify_segment("max", np_data, segment_ids, np_result)

    np_data = np.array([0, 0.8, 1, 20, -25, 45, 1, 0.7, -30, 60, 50, 80]).astype("float32")
    segment_ids = np.array([0, 1, 1, 2, 2, 2, 3, 4, 5, 5, 5, 6]).astype("int32")
    np_result = np.array([0, 0.8, -25, 1, 0.7, -30, 80])
    verify_segment("min", np_data, segment_ids, np_result)

    np_data = np.array(
        [
            [0, 0.8, 1, 20, -25, 45],
            [1, 0.7, 30, 60, 50, 80],
            [0, 0.4, 4, 21, 19, 40],
            [2, -0.9, 35, 61, 52, 79],
            [1, 0.5, 100, 60, 70, 110],
        ]
    ).astype("float32")
    segment_ids = np.array([0, 0, 1, 1, 2]).astype("int32")
    np_result = np.array(
        [
            [0.0, 0.7, 1.0, 20.0, -25.0, 45.0],
            [0.0, -0.9, 4.0, 21.0, 19.0, 40.0],
            [1.0, 0.5, 100.0, 60.0, 70.0, 110.0],
        ]
    )
    verify_segment("min", np_data, segment_ids, np_result)

    np_data = np.array([0, 0.8, 1, 20, -25, 45, 1, 0.7, -30, 60, 50, 80]).astype("float32")
    segment_ids = np.array([0, 1, 1, 2, 2, 2, 3, 4, 5, 5, 5, 6]).astype("int32")
    np_result = np.array([0.0, 0.9, 13.333333, 1.0, 0.7, 26.666666, 80.0])
    verify_segment("mean", np_data, segment_ids, np_result)

    np_data = np.array(
        [
            [0, 0.8, 1, 20, -25, 45],
            [1, 0.7, 30, 60, 50, 80],
            [0, 0.4, 4, 21, 19, 40],
            [2, -0.9, 35, 61, 52, 79],
            [1, 0.5, 100, 60, 70, 110],
        ]
    ).astype("float32")
    segment_ids = np.array([0, 0, 1, 1, 2]).astype("int32")
    np_result = np.array(
        [
            [0.5, 0.75, 15.5, 40.0, 12.5, 62.5],
            [1.0, -0.25, 19.5, 41.0, 35.5, 59.5],
            [1.0, 0.5, 100.0, 60.0, 70.0, 110.0],
        ]
    )
    verify_segment("mean", np_data, segment_ids, np_result)

    np_data = np.array([0, 0.8, 1, 20, -25, 45, 1, 0.7, -30, 60, 50, 80]).astype("float32")
    segment_ids = np.array([0, 1, 1, 2, 2, 2, 3, 4, 5, 5, 5, 6]).astype("int32")
    np_result = np.array([0.0, 1.8, 40.0, 1.0, 0.7, 80.0, 80.0])
    verify_segment("sum", np_data, segment_ids, np_result)

    np_data = np.array(
        [
            [0, 0.8, 1, 20, -25, 45],
            [1, 0.7, 30, 60, 50, 80],
            [0, 0.4, 4, 21, 19, 40],
            [2, -0.9, 35, 61, 52, 79],
            [1, 0.5, 100, 60, 70, 110],
        ]
    ).astype("float32")
    segment_ids = np.array([0, 0, 1, 1, 2]).astype("int32")
    np_result = np.array(
        [
            [1.0, 1.5, 31.0, 80.0, 25.0, 125.0],
            [2.0, -0.5, 39.0, 82.0, 71.0, 119.0],
            [1.0, 0.5, 100.0, 60.0, 70.0, 110.0],
        ]
    )
    verify_segment("sum", np_data, segment_ids, np_result)

    np_data = np.array([0, 0.8, 1, 20, -25, 45, 1, 0.7, -30, 60, 50, 80]).astype("float32")
    segment_ids = np.array([0, 1, 1, 2, 2, 2, 3, 4, 5, 5, 5, 6]).astype("int32")
    np_result = np.array([0.0, 0.8, -22500.0, 1.0, 0.7, -90000, 80])
    verify_segment("prod", np_data, segment_ids, np_result)

    np_data = np.array(
        [
            [0, 0.8, 1, 20, -25, 45],
            [1, 0.7, 30, 60, 50, 80],
            [0, 0.4, 4, 21, 19, 40],
            [2, -0.9, 35, 61, 52, 79],
            [1, 0.5, 100, 60, 70, 110],
        ]
    ).astype("float32")
    segment_ids = np.array([0, 0, 1, 1, 2]).astype("int32")
    np_result = np.array(
        [
            [0.0, 0.56, 30.0, 1200.0, -1250.0, 3600.0],
            [0.0, -0.36, 140.0, 1281.0, 988.0, 3160.0],
            [1.0, 0.5, 100.0, 60.0, 70, 110],
        ]
    )
    verify_segment("prod", np_data, segment_ids, np_result)


_cum_implement = {
    "cumsum": {"generic": (topi.cumsum, topi.generic.schedule_cumsum)},
    "cumprod": {"generic": (topi.cumprod, topi.generic.schedule_cumprod)},
}


def verify_cum_op(name, np_data, np_result, axis, exclusive):

    attrs = {"axis": axis, "exclusive": exclusive}
    device = "llvm"
    ctx = tvm.context(device, 0)
    print("Running on target: %s" % device)
    data = te.placeholder(np_data.shape)
    with tvm.target.create(device):
        fcompute, fschedule = tvm.topi.testing.dispatch(device, _cum_implement[name])
        out = fcompute(data, **attrs)
        s = fschedule(out)
        f = tvm.build(s, [data, out], device)
        tvm_data = tvm.nd.array(np_data, ctx=ctx)
        tvm_out = tvm.nd.empty(ctx=ctx, shape=out.shape, dtype=out.dtype)
        f(tvm_data, tvm_out)
        tvm.testing.assert_allclose(tvm_out.asnumpy(), np_result, rtol=1e-4)


def test_cum_op():
    np_data = np.array([0, 0.8, 1, 20, -25, 45]).astype("float32")
    np_result = np.array([0, 0.8, 1.8, 21.8, -3.200001, 41.8])
    verify_cum_op("cumsum", np_data, np_result, axis=0, exclusive=False)

    np_data = np.array(
        [
            [-31.24, -2.53, -2.73, 14.58],
            [12.0, 16.17, -24.3, 13.35],
        ],
        dtype=np.float32,
    )
    np_result = np.array(
        [
            [-31.24, -2.53, -2.73, 14.58],
            [-19.24, 13.64, -27.029999, 27.93],
        ],
        dtype=np.float32,
    )
    verify_cum_op("cumsum", np_data, np_result, axis=0, exclusive=False)

    np_data = np.array([[8.64, 66.99, 49.6, -7.47], [-28.7, -34.8, 50.16, -61.1]], dtype=np.float32)
    np_result = np.array(
        [[8.64, 75.63, 125.229996, 117.759995], [-28.7, -63.5, -13.34, -74.44]], dtype=np.float32
    )
    verify_cum_op("cumsum", np_data, np_result, axis=1, exclusive=False)

    np_data = np.array(
        [[18.15, 3.41, -77.08, -11.22], [-3.1, 81.78, -29.25, -34.3]], dtype=np.float32
    )

    np_result = np.array([[0.0, 0.0, 0.0, 0.0], [18.15, 3.41, -77.08, -11.22]], dtype=np.float32)
    verify_cum_op("cumsum", np_data, np_result, axis=0, exclusive=True)

    np_data = np.array(
        [[71.54, 13.32, -74.88, 64.78], [-0.09, 21.28, 32.5, 1.32]], dtype=np.float32
    )
    np_result = np.array(
        [[0.0, 71.54, 84.86, 9.980003], [0.0, -0.09, 21.19, 53.690002]], dtype=np.float32
    )
    verify_cum_op("cumsum", np_data, np_result, axis=1, exclusive=True)

    np_data = np.array(
        [
            [
                [[4.41, 57.23, -15.84, -6.48], [1.04, 27.54, 46.5, -27.16]],
                [[-22.5, -13.8, -28.32, -25.37], [67.16, -13.94, -26.65, -59.52]],
                [[-9.5, -7.5, 0.8, -43.7], [36.0, -1.44, 41.58, 71.76]],
            ],
            [
                [[15.12, -0.33, 0.0, -7.59], [-8.55, -15.17, 29.92, 2.82]],
                [[-17.16, 0.0, 15.4, 21.6], [63.99, -62.64, 33.8, -3.43]],
                [[-65.55, 9.88, -9.66, -15.51], [10.32, 28.29, 22.08, 20.4]],
            ],
            [
                [[24.38, -4.13, -3.3, -15.2], [0.0, 7.7, -21.76, 40.92]],
                [[42.78, -18.0, 10.83, -3.06], [-52.46, -18.04, -61.44, 24.78]],
                [[-14.11, 53.6, 56.1, -0.74], [-84.28, -0.6, 2.85, 1.71]],
            ],
        ],
        dtype=np.float32,
    )

    np_result = np.array(
        [
            [
                [[4.41, 57.23, -15.84, -6.48], [1.04, 27.54, 46.5, -27.16]],
                [[-18.09, 43.43, -44.16, -31.85], [68.200005, 13.600001, 19.85, -86.68]],
                [[-27.59, 35.93, -43.36, -75.55], [104.200005, 12.160002, 61.43, -14.919998]],
            ],
            [
                [[15.12, -0.33, 0.0, -7.59], [-8.55, -15.17, 29.92, 2.82]],
                [[-2.04, -0.33, 15.4, 14.01], [55.440002, -77.81, 63.72, -0.61000013]],
                [[-67.590004, 9.55, 5.74, -1.5], [65.76, -49.519997, 85.8, 19.789999]],
            ],
            [
                [[24.38, -4.13, -3.3, -15.2], [0.0, 7.7, -21.76, 40.92]],
                [[67.159996, -22.130001, 7.5299997, -18.26], [-52.46, -10.340001, -83.2, 65.7]],
                [
                    [53.049995, 31.469997, 63.629997, -19.0],
                    [-136.73999, -10.9400015, -80.35, 67.409996],
                ],
            ],
        ],
        dtype=np.float32,
    )
    verify_cum_op("cumsum", np_data, np_result, axis=1, exclusive=False)

    np_data = np_data = np.array([1.62, -0.09, 0.06, -1.38, 1.46], dtype=np.float32)
    np_result = np_result = np.array(
        [1.62, -0.14580001, -0.008748, 0.01207224, 0.01762547], dtype=np.float32
    )
    verify_cum_op("cumprod", np_data, np_result, axis=0, exclusive=False)

    np_data = np.array([[-0.6, -1.94, -0.48, 0.51], [-0.82, -2.82, -0.52, -0.17]], dtype=np.float32)
    np_result = np.array(
        [[-0.6, -1.94, -0.48, 0.51], [0.492, 5.4708, 0.24959998, -0.0867]], dtype=np.float32
    )
    verify_cum_op("cumprod", np_data, np_result, axis=0, exclusive=False)

    np_data = np.array([[-0.74, 0.0, -0.75, 0.0], [1.72, 0.0, 1.66, 0.27]], dtype=np.float32)
    np_result = np.array([[-0.74, -0.0, 0.0, 0.0], [1.72, 0.0, 0.0, 0.0]], dtype=np.float32)
    verify_cum_op("cumprod", np_data, np_result, axis=1, exclusive=False)

    np_data = np.array([[1.1, -0.54, -1.78, -0.16], [0.3, -1.58, -2.7, 1.34]], dtype=np.float32)
    np_result = np.array([[1.0, 1.0, 1.0, 1.0], [1.1, -0.54, -1.78, -0.16]], dtype=np.float32)
    verify_cum_op("cumprod", np_data, np_result, axis=0, exclusive=True)

    np_data = np.array([[-0.96, -0.84, -0.51, -0.12], [0.16, -0.3, 1.34, -0.61]], dtype=np.float32)
    np_result = np.array(
        [[1.0, -0.96, 0.80639994, -0.41126397], [1.0, 0.16, -0.048, -0.06432001]], dtype=np.float32
    )
    verify_cum_op("cumprod", np_data, np_result, axis=1, exclusive=True)

    np_data = np.array(
        [
            [
                [[-0.76, 0.04, 0.88, 1.38], [-0.61, 1.58, -0.18, 0.0]],
                [[0.0, -2.34, -0.69, 0.59], [-0.03, 0.0, 0.98, 0.98]],
                [[0.38, 0.0, 0.7, -1.5], [0.0, 0.6, 0.94, 1.94]],
            ],
            [
                [[-1.06, 0.54, -0.96, 0.0], [-0.57, 0.0, 0.0, -0.75]],
                [[0.0, -0.39, -0.46, -0.1], [-0.46, -1.23, 0.32, 1.54]],
                [[0.0, -0.37, 0.65, -1.28], [-0.32, -0.62, -1.11, 0.0]],
            ],
        ],
        dtype=np.float32,
    )
    np_result = np.array(
        [
            [
                [[-0.76, 0.04, 0.88, 1.38], [-0.61, 1.58, -0.18, 0.0]],
                [[0.0, -2.34, -0.69, 0.59], [-0.03, 0.0, 0.98, 0.98]],
                [[0.38, 0.0, 0.7, -1.5], [0.0, 0.6, 0.94, 1.94]],
            ],
            [
                [[0.8055999, 0.0216, -0.8448, 0.0], [0.3477, 0.0, -0.0, -0.0]],
                [[0.0, 0.9125999, 0.3174, -0.059], [0.0138, -0.0, 0.3136, 1.5092]],
                [[0.0, -0.0, 0.45499998, 1.92], [-0.0, -0.372, -1.0434, 0.0]],
            ],
        ],
        dtype=np.float32,
    )

    verify_cum_op("cumprod", np_data, np_result, axis=0, exclusive=False)

    np_data = np.array(
        [
            [
                [[0.94, 1.46, 0.95, 0.1], [1.84, 1.16, 0.16, 0.32]],
                [[1.58, 1.9, 0.08, 1.72], [0.96, 1.48, 0.66, 0.18]],
                [[0.63, 0.01, 0.49, 1.86], [0.29, 1.22, 0.52, 0.68]],
            ],
            [
                [[0.79, 0.02, 1.62, 0.9], [0.92, 1.14, 0.94, 0.56]],
                [[0.68, 1.48, 0.28, 0.14], [0.42, 1.66, 0.19, 0.68]],
                [[0.11, 0.36, 1.06, 0.28], [0.16, 0.98, 0.77, 0.45]],
            ],
        ],
        dtype=np.float32,
    )
    np_result = np.array(
        [
            [
                [[1.0, 1.0, 1.0, 1.0], [1.0, 1.0, 1.0, 1.0]],
                [[1.0, 1.0, 1.0, 1.0], [1.0, 1.0, 1.0, 1.0]],
                [[1.0, 1.0, 1.0, 1.0], [1.0, 1.0, 1.0, 1.0]],
            ],
            [
                [[0.94, 1.46, 0.95, 0.1], [1.84, 1.16, 0.16, 0.32]],
                [[1.58, 1.9, 0.08, 1.72], [0.96, 1.48, 0.66, 0.18]],
                [[0.63, 0.01, 0.49, 1.86], [0.29, 1.22, 0.52, 0.68]],
            ],
        ],
        dtype=np.float32,
    )
    verify_cum_op("cumprod", np_data, np_result, axis=0, exclusive=True)


if __name__ == "__main__":
    tvm.testing.main()
