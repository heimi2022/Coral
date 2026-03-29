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
""" Testing unpooling op """
import tvm
from tvm import relay
from torch import tensor
from torch.nn import functional as fn
import numpy as np


def run_model(mod, tvm_input, tvm_mask):
    with relay.build_config(opt_level=2):
        graph, lib, _ = relay.build(mod, target="llvm -device=csinn")

    m = tvm.contrib.graph_runtime.create(graph, lib, tvm.cpu())
    m.set_input(data=tvm_input, mask=tvm_mask)
    m.run()
    return m.get_output(0).asnumpy()


def unpooling_model(scale_h, scale_w, pad_out_h, pad_out_w):
    data = relay.var("data", shape=(1, 3, 112, 112))
    mask = relay.var("mask", shape=(1, 3, 112, 112))
    out = relay.vision.unpooling(data, mask, scale_h, scale_w, pad_out_h, pad_out_w)

    return relay.Function([data, mask], out)


def quant_unpooling_model(
    scales,
    out_padding,
    input_scale,
    input_zero_point,
    output_scale,
    output_zero_point,
    out_dtype,
    layout,
):
    data = relay.var("data", shape=(1, 3, 112, 112), dtype="uint8")
    mask = relay.var("mask", shape=(1, 3, 112, 112), dtype="int32")
    q_params = [[input_scale, input_zero_point], [output_scale, output_zero_point]]
    out = relay.qnn.op.csi_unpooling(
        data,
        mask,
        scales,
        out_padding,
        out_dtype,
        layout,
        q_params,
    )

    return relay.Function([data, mask], out)


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
    np.random.seed(20)
    data = ((np.random.random((1, 3, 224, 224)) - 0.5) * 255).astype(np.float)
    t_data = tensor(data)
    t_input, t_mask = fn.max_pool2d_with_indices(t_data, kernel_size=2, stride=2, padding=0)

    return t_input, t_mask


def test_unpooling():
    t_input, t_mask = get_input_data()
    tvm_input, tvm_mask = t_input.numpy(), t_mask.numpy()
    mod = unpooling_model(scale_h=2, scale_w=2, pad_out_h=0, pad_out_w=0)
    tvm_out = run_model(mod, tvm_input, tvm_mask)
    torch_out = fn.max_unpool2d(t_input, t_mask, kernel_size=2, stride=2).numpy()

    assert np.allclose(torch_out, tvm_out)


def test_quant_unpooling():
    t_input, t_mask = get_input_data()
    tvm_input, tvm_mask = t_input.numpy(), t_mask.numpy()

    f_mod = unpooling_model(scale_h=2, scale_w=2, pad_out_h=0, pad_out_w=0)
    float_out = run_model(f_mod, tvm_input, tvm_mask)

    q_input, input_scale, input_zero_point = get_quant_data(tvm_input)
    _, out_scale, out_zero_point = get_quant_data(float_out)
    out_dtype = "uint8"
    layout = "NCHW"

    q_model = quant_unpooling_model(
        [2, 2], [0, 0], input_scale, input_zero_point, out_scale, out_zero_point, out_dtype, layout
    )

    q_out = run_model(q_model, q_input, tvm_mask.astype(np.int32))
    tvm_out = dequant_data(q_out, out_scale, out_zero_point)

    torch_out = fn.max_unpool2d(t_input, t_mask, kernel_size=2, stride=2).numpy()

    assert np.allclose(torch_out, tvm_out, atol=input_scale / 2)


if __name__ == "__main__":
    test_unpooling()
    test_quant_unpooling()
