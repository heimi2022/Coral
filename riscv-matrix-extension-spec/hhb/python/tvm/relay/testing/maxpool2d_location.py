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
# pylint: disable=invalid-name, unused-argument, too-many-lines, import-outside-toplevel
""" Testing maxpool2d_location op """
import tvm
from tvm import relay
from torch import tensor
from torch.nn import functional as fn
import numpy as np


def maxpool2d_location_model():
    data = relay.var("data", shape=(1, 3, 224, 224))
    out = relay.vision.max_pool2d_location(
        data, pool_size=(2, 2), strides=(2, 2), padding=(0, 0), layout="NCHW", ceil_mode=True
    )

    return relay.Function([data], out)


def maxpool2d_argmax_model():
    data = relay.var("data", shape=(1, 3, 224, 224))
    out = relay.nn.max_pool2d_with_argmax(
        data, pool_size=(2, 2), strides=(2, 2), padding=(0, 0), layout="NCHW", ceil_mode=True
    )

    return relay.Function([data], out)


def quant_maxpool2d_location_model(pool_size, strides, padding):
    """Quantize model"""
    data = relay.var("data", shape=(1, 3, 224, 224), dtype="uint8")
    q_params = [[1, 0], [1, 0]]
    out = relay.qnn.op.csi_maxpool2d_locat(
        data,
        strides=strides,
        padding=padding,
        pool_size=pool_size,
        ceil_mode=True,
        out_dtype="int32",
        layout="NCHW",
        q_params=q_params,
    )

    return relay.Function([data], out)


def quant_maxpool2d_argmax_model(
    input_scale, input_zero_point, output_scale, output_zero_point, pool_size, strides, padding
):
    """Quantize model"""
    data = relay.var("data", shape=(1, 3, 224, 224), dtype="uint8")
    q_params = [[input_scale, input_zero_point], [output_scale, output_zero_point]]
    out = relay.qnn.op.csi_maxpool2d_with_argmax(
        data,
        "int32",
        strides,
        padding,
        pool_size,
        ceil_mode=True,
        layout="NCHW",
        q_params=q_params,
    )

    return relay.Function([data], out)


def run_model(mod, data):
    with relay.build_config(opt_level=2):
        graph, lib, _ = relay.build(mod, target="llvm -device=csinn")

    m = tvm.contrib.graph_runtime.create(graph, lib, tvm.cpu())
    m.set_input(data=data)
    m.run()

    return m.get_output(0).asnumpy()


def get_quant_data(data):
    data = np.array(data)
    min_val = data.min()
    max_val = data.max()
    scale = (max_val - min_val) / 255
    zero_point = (np.round(-min_val / scale)).astype(np.int32)
    q_data = np.round(data / scale) + zero_point
    q_data = np.clip(q_data, 0, 255).astype(np.uint8)

    return q_data, scale, zero_point


def dequant_data(q_data, scale, zero_point):
    q_data = q_data.astype(np.float)

    return scale * (q_data - zero_point)


def get_input_data():
    np.random.seed(10)
    data = ((np.random.random((1, 3, 224, 224)) - 0.5) * 588.63).astype(np.float)
    t_data = tensor(data)
    return t_data


def test_maxpool2d_location():
    """Testing"""
    t_input = get_input_data()
    tvm_input = t_input.numpy()
    mod = maxpool2d_location_model()
    tvm_out = run_model(mod, tvm_input)
    _, torch_out = fn.max_pool2d_with_indices(
        t_input, kernel_size=2, stride=2, padding=0, ceil_mode=True
    )

    assert np.allclose(tvm_out, torch_out)


def test_quant_maxpool2d_location():
    """Testing"""
    t_input = get_input_data()
    q_input, _, _ = get_quant_data(t_input.numpy())
    pool_size = (2, 2)
    strides = (2, 2)
    padding = (0, 0)
    q_model = quant_maxpool2d_location_model(pool_size, strides, padding)
    tvm_out = run_model(q_model, q_input)
    _, torch_out = fn.max_pool2d_with_indices(
        t_input, kernel_size=2, stride=2, padding=0, ceil_mode=True
    )
    max_atol = (pool_size[0] - 1) * (q_input.shape[3] + 1)
    assert np.allclose(torch_out, tvm_out, atol=max_atol)


def test_maxpool2d_argmax():
    """Testing"""
    t_input = get_input_data()
    tvm_input = t_input.numpy()
    mod = maxpool2d_argmax_model()
    tvm_out = run_model(mod, tvm_input)
    torch_out, _ = fn.max_pool2d_with_indices(
        t_input, kernel_size=2, stride=2, padding=0, ceil_mode=True
    )

    assert np.allclose(tvm_out, torch_out)


def test_quant_maxpool2d_argmax():
    """Testing"""
    t_input = get_input_data()
    q_input, input_scale, input_zero_point = get_quant_data(t_input.numpy())
    pool_size = (2, 2)
    strides = (2, 2)
    padding = (0, 0)
    torch_out, _ = fn.max_pool2d_with_indices(
        t_input, kernel_size=2, stride=2, padding=0, ceil_mode=True
    )
    _, output_scale, output_zero_point = get_quant_data(torch_out)
    q_model = quant_maxpool2d_argmax_model(
        input_scale, input_zero_point, output_scale, output_zero_point, pool_size, strides, padding
    )
    q_out = run_model(q_model, q_input)
    tvm_out = dequant_data(q_out, output_scale, output_zero_point)

    assert np.allclose(torch_out, tvm_out, atol=input_scale)


if __name__ == "__main__":
    # maxpool2d_location
    test_maxpool2d_location()
    test_quant_maxpool2d_location()

    # maxpool2d_argmax
    test_maxpool2d_argmax()
    test_quant_maxpool2d_argmax()
