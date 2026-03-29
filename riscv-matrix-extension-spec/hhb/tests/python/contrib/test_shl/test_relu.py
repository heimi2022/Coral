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
"""SHL integration relu tests."""

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


def _get_relu_model(shape, dtype, var_names):
    """Return a model and any parameters it may have."""
    out = relay.var(next(var_names), shape=shape, dtype=dtype)

    out = relay.nn.relu(
        out,
    )

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
        [fp32_dtype, (512, 27, 27), ],
        [fp32_dtype, (16, 16, 16),  ],
        [fp32_dtype, (16, 15, 15),  ],
        [fp32_dtype, (16, 16, 16),  ],
    ]
    # fmt: on
    for (
        (dtype, low, high, atol, rtol),
        input_shape,
    ) in trials:
        shape = (1, *input_shape)
        outputs = []
        inputs = {
            "a": tvm.nd.array(np.random.uniform(low, high, shape).astype(dtype)),
        }

        func = _get_relu_model(
            shape,
            dtype,
            iter(inputs),
        )

        config = {
            "shape": shape,
            "dtype": dtype,
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
                    config=config,
                )[0]
            )

        verify(outputs, atol=atol, rtol=rtol, config=config, verify_saturation=verify_saturation)


if __name__ == "__main__":
    test_pooling()
