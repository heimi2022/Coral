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
"""SHL integration pooling tests."""

import numpy as np
import tvm
from tvm import relay, testing

from infrastructure import (
    Device,
    build_and_run,
    skip_codegen_test,
    skip_runtime_test,
    verify,
    verify_codegen,
)


def _get_pooling_model(
    shape, dtype, typef, sizes, strides, dilation, padding, ceil_mode, count_include_pad, var_names
):
    """Return a model and any parameters it may have."""
    if len(padding) == 2:
        padding = (padding[0], padding[1], padding[0], padding[1])
    out = relay.var(next(var_names), shape=shape, dtype=dtype)

    if typef == "nn.max_pool2d":
        out = relay.nn.max_pool2d(
            out,
            pool_size=sizes,
            strides=strides,
            dilation=dilation,
            padding=padding,
            ceil_mode=ceil_mode,
            layout="NCHW",
        )
    elif typef == "nn.avg_pool2d":
        out = relay.nn.avg_pool2d(
            out,
            pool_size=sizes,
            strides=strides,
            dilation=dilation,
            padding=padding,
            ceil_mode=ceil_mode,
            count_include_pad=count_include_pad,
            layout="NCHW",
        )
    else:
        raise ValueError("Function not supported")

    return out


def test_pooling():
    Device.load("test_config.json")

    if skip_runtime_test():
        return

    device = Device()
    np.random.seed(0)

    fp32_dtype = ("float32", -127, 128, 0.001, 0.001)
    # fmt: off
    trials = [
        ["nn.max_pool2d", fp32_dtype,  (3, 3), (2, 2), (1, 1), (0, 0), False, False, (512, 27, 27), (0, 1),],
        ["nn.max_pool2d", fp32_dtype,  (2, 2), (2, 2), (1, 1), (0, 0), False, True,  (16, 16, 16),  (0, 1),],
        ["nn.max_pool2d", fp32_dtype,  (3, 3), (2, 2), (1, 1), (0, 0), True,  True,  (16, 15, 15),  (0, 1),],
        ["nn.max_pool2d", fp32_dtype,  (2, 2), (2, 2), (1, 1), (0, 0), False, False, (16, 16, 16),  (0, 1),],
        ["nn.avg_pool2d", fp32_dtype,  (2, 2), (2, 2), (1, 1), (0, 0), False, False, (16, 16, 16),  (0, 1),],
        ["nn.avg_pool2d", fp32_dtype,  (2, 2), (2, 2), (1, 1), (0, 0), False, True,  (16, 16, 16),  (0, 1),],
        # ["nn.avg_pool2d", fp32_dtype,  (3, 3), (2, 2), (3, 2), (0, 0), True,  False, (15, 15, 16),  (1, 0),],
    ]
    # fmt: on
    for (
        typef,
        (dtype, low, high, atol, rtol),
        size,
        stride,
        dilation,
        pad,
        ceil_mode,
        count_include_pad,
        input_shape,
        (tvm_ops, shl_partitions),
    ) in trials:
        shape = (1, *input_shape)
        outputs = []
        inputs = {
            "a": tvm.nd.array(np.random.uniform(low, high, shape).astype(dtype)),
        }

        func = _get_pooling_model(
            shape,
            dtype,
            typef,
            size,
            stride,
            dilation,
            pad,
            ceil_mode,
            count_include_pad,
            iter(inputs),
        )

        config = {
            "size": size,
            "stride": stride,
            "shape": shape,
            "pooling type": typef,
            "dtype": dtype,
            "padding": pad,
            "dilation": dilation,
            "ceil_mode": ceil_mode,
            "count_include_pad": count_include_pad,
            "inputs": inputs,
        }
        verify_saturation = False
        for shl in [False, True]:
            outputs.append(
                build_and_run(
                    func,
                    inputs,
                    1,
                    None,
                    device,
                    enable_shl=shl,
                    tvm_ops=tvm_ops,
                    shl_partitions=shl_partitions,
                    config=config,
                )[0]
            )

        verify(outputs, atol=atol, rtol=rtol, config=config, verify_saturation=verify_saturation)


if __name__ == "__main__":
    test_pooling()
