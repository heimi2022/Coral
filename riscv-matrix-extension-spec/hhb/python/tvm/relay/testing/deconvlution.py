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
# pylint: disable=missing-function-docstring
""" Testing deconvolution op """
import tvm
from tvm import relay
from torch import tensor
from torch.nn import functional as fn
import numpy as np

np.set_printoptions(precision=7, suppress=True)


def run_model(mod, input_data, weight, bias=None):
    with relay.build_config(opt_level=2):
        graph, lib, _ = relay.build(mod, target="llvm -device=csinn")

    m = tvm.contrib.graph_runtime.create(graph, lib, tvm.cpu())
    if bias is None:
        m.set_input(data=input_data, weight=weight)
    else:
        m.set_input(data=input_data, weight=weight, bias=bias)
    m.run()
    return m.get_output(0).asnumpy()


def deconv_model(strides, padding, dilation, groups):
    data = relay.var("data", shape=(1, 3, 20, 20))
    weight = relay.var("weight", shape=(3, 5, 3, 3))
    out = relay.nn.conv2d_transpose(data, weight, strides, padding, dilation, groups)

    return relay.Function([data, weight], out)


def quant_deconv_model(
    input_scale,
    input_zero_point,
    kernel_scale,
    kernel_zero_point,
    output_scale,
    output_zero_point,
    strides,
    padding,
    dilation,
    groups,
    channels,
    kernel_size,
):
    data = relay.var("data", shape=(1, 3, 20, 20), dtype="uint8")
    weight = relay.var("weight", shape=(3, 5, 3, 3), dtype="uint8")
    bias = relay.var("bias", shape=(1, 5), dtype="int32")
    q_params = [
        [input_scale, input_zero_point],
        [kernel_scale, kernel_zero_point],
        [0, 0],
        [output_scale, output_zero_point],
    ]
    out = relay.qnn.op.csi_deconv2d(
        data,
        weight,
        bias,
        strides,
        padding,
        dilation,
        groups,
        channels,
        kernel_size,
        data_layout="NCHW",
        kernel_layout="OIHW",
        out_layout="NCHW",
        output_padding=(0, 0),
        out_dtype="uint8",
        q_params=q_params,
    )

    return relay.Function([data, weight, bias], out)


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
    np.random.seed(0)
    data = ((np.random.random((1, 3, 20, 20)) - 0.5) * 255).astype(np.float)
    weight = np.random.random((3, 5, 3, 3)).astype(np.float)
    bias = np.zeros((1, 5)).astype(np.int32)

    return tensor(data), tensor(weight), tensor(bias)


def test_deconv():
    t_input, t_weight, t_bias = get_input_data()
    tvm_input, tvm_weight, _ = t_input.numpy(), t_weight.numpy(), t_bias.numpy()
    mod = deconv_model(strides=(1, 1), padding=(0, 0), dilation=(1, 1), groups=1)
    tvm_out = run_model(mod, tvm_input, tvm_weight)
    torch_out = fn.conv_transpose2d(
        t_input, t_weight, stride=1, padding=0, output_padding=0, groups=1, dilation=1
    ).numpy()

    assert np.allclose(torch_out, tvm_out, atol=1e-4)


def test_quant_deconv():
    # get float input data
    t_input, t_weight, t_bias = get_input_data()
    tvm_input, tvm_weight, tvm_bias = t_input.numpy(), t_weight.numpy(), t_bias.numpy()

    # get quant data
    q_input, input_scale, input_zero_point = get_quant_data(tvm_input)
    q_weight, kernel_scale, kernel_zero_point = get_quant_data(tvm_weight)
    # mod = deconv_model(strides=(1, 1), padding=(0, 0), dilation=(1, 1), groups=1)
    # float_out = run_model(mod, tvm_input, tvm_weight)

    # torch out
    torch_out = fn.conv_transpose2d(
        t_input, t_weight, stride=1, padding=0, output_padding=0, groups=1, dilation=1
    ).numpy()
    _, output_scale, output_zero_point = get_quant_data(torch_out)

    # get quant model
    mod = quant_deconv_model(
        input_scale,
        input_zero_point,
        kernel_scale,
        kernel_zero_point,
        output_scale,
        output_zero_point,
        strides=(1, 1),
        padding=(0, 0),
        dilation=(1, 1),
        groups=1,
        channels=5,
        kernel_size=(3, 3),
    )
    # quant out
    q_out = run_model(mod, q_input, q_weight, tvm_bias)
    tvm_out = dequant_data(q_out, output_scale, output_zero_point)

    assert np.allclose(torch_out, tvm_out, atol=output_scale)


if __name__ == "__main__":
    test_deconv()
    test_quant_deconv()
