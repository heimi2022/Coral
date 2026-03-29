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

"""Some test tools for Caffe frontend."""
# from ..frontend.caffe import OperatorConverter
import os

os.environ["GLOG_minloglevel"] = "2"
import caffe
from caffe.proto import caffe_pb2 as pb
from google.protobuf import text_format
from caffe import layers as L, params as P
import time
import numpy as np
import logging

logging.basicConfig(level=logging.ERROR)

from tvm.contrib import util, graph_runtime
from tvm import relay
import tvm

###############################################################################
#                                   Single layer                              #
###############################################################################


class LayerTest(object):
    def __init__(self, layer_type, input_shape):
        self._tmpdir = util.tempdir()
        self.net_file = self._tmpdir.relpath("model.prototxt")
        self.model_file = self._tmpdir.relpath("model.caffemodel")
        self.solver_file = self._tmpdir.relpath("solver.prototxt")
        self.layer_type = layer_type
        self.input_shape = input_shape

    def create_net(self):
        n = caffe.NetSpec()
        n.data = L.Input(input_param={"shape": {"dim": self.input_shape}})
        op_map = {
            "conv": L.Convolution(
                n.data,
                bias_term=False,
                kernel_size=3,
                group=1,
                stride=2,
                dilation=[1, 1],
                num_output=100,
                pad=0,
                weight_filler=dict(type="xavier"),
            ),
            "dense": L.InnerProduct(n.data, num_output=10, weight_filler=dict(type="xavier")),
            "softmax": L.Softmax(n.data),
            "pooling": L.Pooling(n.data, kernel_size=2, stride=2, pool=P.Pooling.MAX),
            "lrn": L.LRN(n.data, local_size=5, alpha=0.0001, beta=0.75),
            "relu": L.ReLU(n.data),
            "reshape": L.Reshape(n.data, reshape_param={"shape": {"dim": [1, -1]}}),
            "bn": L.BatchNorm(n.data, use_global_stats=True),
            "scale": L.Scale(n.data, bias_term=True),
            "concat": L.Concat(n.data, n.data, axis=1),
            "eltwise": L.Eltwise(n.data, n.data, operation=2),
            "prelu": L.PReLU(n.data, in_place=False),
            "sigmoid": L.Sigmoid(n.data),
            "tanh": L.TanH(n.data),
            "deconvolution": L.Deconvolution(
                n.data,
                param={"lr_mult": 1, "decay_mult": 1},
                convolution_param=dict(
                    num_output=1,
                    stride=2,
                    kernel_size=4,
                    bias_term=False,
                    weight_filler=dict(type="xavier"),
                    bias_filler=dict(type="constant", value=0),
                ),
            ),
        }
        n.output = op_map[self.layer_type]
        s = n.to_proto()
        with open(self.net_file, "w") as f:
            f.write(str(s))

    def create_solver(self):
        s = pb.SolverParameter()
        s.train_net = self.net_file
        s.base_lr = 0.01
        s.momentum = 0.9
        s.weight_decay = 0.0005
        s.lr_policy = "inv"
        s.gamma = 0.0001
        s.power = 0.75
        s.display = 1
        s.max_iter = 100000
        s.snapshot = 100000
        s.snapshot_prefix = "model.caffemodel"

        with open(self.solver_file, "w") as f:
            f.write(str(s))

    def save_model(self):
        self.create_net()
        self.create_solver()
        solver = caffe.SGDSolver(self.solver_file)
        solver.net.save(self.model_file)

    def run_caffe(self, input_data):
        caffe_start = time.time()

        input_data = input_data.astype(np.float32)
        net = caffe.Net(self.net_file, self.model_file, caffe.TEST)
        net.blobs["data"].data[...] = input_data
        out = net.forward()

        # res = []
        # for o in net.outputs:
        #     res.append(out[o])

        caffe_end = time.time()
        return out, caffe_end - caffe_start

    def run_tvm(self, input_data):

        init_net = pb.NetParameter()
        predict_net = pb.NetParameter()

        # load model
        with open(self.net_file, "r") as f:
            text_format.Merge(f.read(), predict_net)
        # load blob
        with open(self.model_file, "rb") as f:
            init_net.ParseFromString(f.read())

        shape_dict = {"data": input_data.shape}
        dtype_dict = {"data": "float32"}

        mod, params, model_outputs = relay.frontend.from_caffe(
            init_net, predict_net, shape_dict, dtype_dict
        )
        # print(mod)
        target = "llvm"
        target_host = "llvm"
        layout = "NCHW"
        # layout = 'NHWC'
        ctx = tvm.cpu(0)

        tvm_start = time.time()

        with relay.build_config(opt_level=2):
            graph, lib, params = relay.build(
                mod, target=target, target_host=target_host, params=params
            )
        dtype = "float32"
        m = graph_runtime.create(graph, lib, ctx)
        m.set_input("data", tvm.nd.array(input_data.astype(dtype)))
        m.set_input(**params)
        # execute
        m.run()
        tvm_end = time.time()
        tvm_output = dict()
        # get outputs
        for i in range(m.get_num_outputs()):
            tvm_output[model_outputs[i]] = m.get_output(i).asnumpy()
        return tvm_output, tvm_end - tvm_start

    def run_test(self, N):
        self.save_model()

        print(
            "==================== Testing {} layer in caffe: ========================".format(
                self.layer_type
            )
        )
        for i in range(N):
            print("time:[{}]".format(i))
            input_data = np.random.randint(256, size=self.input_shape)
            input_data = input_data.astype(np.float32)
            # input_data = input_data / 255.0

            caffe_out, caffe_time = self.run_caffe(input_data)
            tvm_out, tvm_time = self.run_tvm(input_data)

            assert len(caffe_out) == len(
                tvm_out
            ), "the output number of caffe model should be equal to tvm's"

            for i in tvm_out.keys():
                print("{} output{} start...".format("-" * 10, i))
                try:
                    np.testing.assert_allclose(caffe_out[i], tvm_out[i], rtol=1e-5, atol=1e-5)
                    print("{} pass!".format("-" * 10))
                except:
                    print("{} fail!".format("-" * 10))


if __name__ == "__main__":
    input_shape = [1, 3, 224, 224]
    N = 5

    to_test = [
        "conv",
        "dense",
        "softmax",
        "pooling",
        "lrn",
        "relu",
        "reshape",
        "bn",
        "concat",
        "scale",
        "eltwise",
        "prelu",
        "sigmoid",
        "tanh",
        "deconvolution",
    ]
    # to_test = ['bn']

    for i in to_test:
        layer = LayerTest(i, input_shape)
        layer.run_test(N)
