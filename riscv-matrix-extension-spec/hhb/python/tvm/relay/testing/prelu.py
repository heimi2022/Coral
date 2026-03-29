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
""" Testing prelu op """
import tvm
from tvm import relay
from torch import tensor
from torch.nn import functional as fn
import numpy as np

np.set_printoptions(precision=7, suppress=True)


def run_model(mod, input_data, alpha):
    with relay.build_config(opt_level=2):
        graph, lib, _ = relay.build(mod, target="llvm -device=csinn")

    m = tvm.contrib.graph_runtime.create(graph, lib, tvm.cpu())
    m.set_input(data=input_data, alpha=alpha)
    m.run()
    return m.get_output(0).asnumpy()


def prelu_model():
    data = relay.var("data", shape=[1, 32, 224, 224])
    alpha = relay.var("alpha", shape=[32])
    out = relay.nn.prelu(data, alpha, axis=1)

    return relay.Function([data, alpha], out)


def quant_prelu_model(
    input_scale, input_zero_point, alpha_scale, alpha_zero_point, output_scale, output_zero_point
):
    """Quantize model"""
    data = relay.var("data", shape=(1, 32, 224, 224), dtype="uint8")
    alpha = relay.var("alpha", shape=[32], dtype="uint8")
    axis = 1
    q_params = [
        [input_scale, input_zero_point],
        [alpha_scale, alpha_zero_point],
        [output_scale, output_zero_point],
    ]
    out = relay.qnn.op.csi_prelu(
        data,
        alpha,
        axis,
        "float32",
        q_params,
    )

    return relay.Function([data, alpha], out)


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
    data = (np.random.random((1, 32, 224, 224)) - 255).astype(np.float)
    alpha = np.random.random([32]).astype(np.float)

    return tensor(data), tensor(alpha)


def test_prelu():
    t_input, t_alpha = get_input_data()
    tvm_input, tvm_alpha = t_input.numpy(), t_alpha.numpy()

    mod = prelu_model()
    tvm_out = run_model(mod, tvm_input, tvm_alpha)
    torch_out = fn.prelu(t_input, t_alpha).numpy()

    assert np.allclose(torch_out, tvm_out, atol=1e-4)


def test_quant_prelu():
    """Main testing code"""
    # get float input data
    t_input, t_alpha = get_input_data()
    tvm_input, tvm_alpha = t_input.numpy(), t_alpha.numpy()

    # get quant data
    q_input, input_scale, input_zero_point = get_quant_data(tvm_input)
    q_alpha, alpha_scale, alpha_zero_point = get_quant_data(tvm_alpha)

    # torch out
    torch_out = fn.prelu(t_input, t_alpha).numpy()

    _, output_scale, output_zero_point = get_quant_data(torch_out)

    # get quant model
    mod = quant_prelu_model(
        input_scale,
        input_zero_point,
        alpha_scale,
        alpha_zero_point,
        output_scale,
        output_zero_point,
    )

    # quant out
    q_out = run_model(mod, q_input, q_alpha)
    tvm_out = dequant_data(q_out, output_scale, output_zero_point)

    # input_max = tvm_input.min()
    # alpha_max = tvm_alpha.max()

    assert np.allclose(torch_out, tvm_out, atol=1)


if __name__ == "__main__":
    np.random.seed(0)

    test_prelu()
    test_quant_prelu()
