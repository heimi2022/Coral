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
# pylint: disable=logging-format-interpolation, multiple-statements
""" Testing single op of caffe"""
import time
import logging
import os
import gc

import numpy as np
import caffe
from caffe import layers as L, params as P
from caffe.proto import caffe_pb2
from PIL import Image
import tvm
from tvm import relay
from tvm.contrib import graph_runtime
from google.protobuf import text_format

__all__list = [
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
    "slice",
]

logging.basicConfig(level=20)


def image_preprocess(image_path, image_shape):

    image = Image.open(image_path).resize(image_shape)
    x = np.array(image) / 255
    r, g, b = np.split(x, 3, axis=2)
    x = np.concatenate([b, g, r], axis=2)
    x = np.expand_dims(x, axis=0)
    x = x.transpose((0, 3, 1, 2))
    x = x.astype("float32")
    return x


def get_top5(prediction):
    """return top5 index and value of input array"""
    length = np.prod(prediction.size)
    pre = np.reshape(prediction, [length])
    ind = np.argsort(pre)

    ind = ind[length - 5 :]
    value = pre[ind]

    ind = ind[::-1]
    value = value[::-1]
    res_str = ""
    logging.info("============ top5 ===========")
    for (i, v) in zip(ind, value):
        logging.info("{}:{}".format(i, v))
        res_str = res_str + "{}:{}".format(i, v) + "\n"
    return res_str


def create_solver(solver_path, model_path):
    """Create caffe solver"""
    s = caffe_pb2.SolverParameter()
    s.train_net = model_path
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

    with open(solver_path, "w") as f:
        f.write(str(s))


def run_tvm(image, proto_file=None, blob_file=None):
    """Exectute tvm"""
    if not proto_file:
        proto_file = "deploy.prototxt"
        blob_file = "deploy.caffemodel"

    init_net = caffe_pb2.NetParameter()
    predict_net = caffe_pb2.NetParameter()

    # load model
    with open(proto_file, "r") as f:
        text_format.Merge(f.read(), predict_net)
    # load blob
    with open(blob_file, "rb") as f:
        init_net.ParseFromString(f.read())

    shape_dict = {"data": image.shape}
    dtype_dict = {"data": "float32"}

    mod, params = relay.frontend.from_caffe(init_net, predict_net, shape_dict, dtype_dict)
    target = "llvm"
    target_host = "llvm"
    ctx = tvm.cpu(0)

    tvm_start = time.time()

    with relay.build_config(opt_level=2):
        graph, lib, params = relay.build(mod, target=target, target_host=target_host, params=params)

    dtype = "float32"
    m = graph_runtime.create(graph, lib, ctx)
    m.set_input("data", tvm.nd.array(image.astype(dtype)))
    m.set_input(**params)
    # execute
    m.run()
    tvm_end = time.time()
    tvm_output = []
    # get outputs
    for i in range(m.get_num_outputs()):
        tvm_output.append(m.get_output(i).asnumpy())
    return tvm_output, tvm_end - tvm_start


def run_caffe(
    image, input_shape, net_file=None, caffe_model=None, layer_op=None, caffe_out_blob=None
):
    """Execute caffe"""
    if not net_file:
        net_file = "deploy.prototxt"
        caffe_model = "deploy.caffemodel"

    if layer_op:
        net_file = "deploy.prototxt"
        caffe_model = "deploy.caffemodel"
        # create deploy prototxt
        create_model(layer_op, net_file, input_shape)
        # create solver
        create_solver("solver.prototxt", net_file)
        # save caffemodel
        solver = caffe.SGDSolver("solver.prototxt")
        solver.net.save(caffe_model)

    # load model
    caffe_start = time.time()
    net = caffe.Net(net_file, caffe_model, caffe.TEST)
    net.blobs["data"].data[...] = image
    out = net.forward()

    caffe_end = time.time()

    del net, caffe_model, net_file
    gc.collect()
    return out, caffe_end - caffe_start


def create_slice(input_shape):
    """create multiple output layer slice"""
    n = caffe.NetSpec()
    n.data = L.Input(input_param={"shape": {"dim": [1, 3, input_shape[0], input_shape[1]]}})
    n.out1, n.out2, _ = L.Slice(
        n.data, ntop=3, name="slice", slice_param=dict(slice_dim=1, slice_point=[1, 2])
    )
    return n


def create_model(layer, net_file, input_shape):
    """create caffe deploy net and write to prototxt"""
    multiple_output_layer = ["slice"]
    if layer in multiple_output_layer:
        n = globals()["create_" + layer](input_shape)

    else:
        n = caffe.NetSpec()
        n.data = L.Input(input_param={"shape": {"dim": [1, 3, input_shape[0], input_shape[1]]}})
        op_map = {
            "conv": L.Convolution(
                n.data,
                kernel_size=3,
                stride=1,
                pad=0,
                num_output=20,
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

    n.prob = op_map[layer]

    s = n.to_proto()
    with open(net_file, "w") as f:
        f.write(str(s))


def test_caffe_tvm(
    op=None, image=None, image_shape=(224, 224), prototxt=None, caffemodel=None, test_tvm=True
):
    """Compare caffe output and tvm output.Support single op and complete model.

    Parameters
    ----------
    image : str
        if image is None,random image will be used.
    image_shape : tuple
        shape of the net input.
    op :   str
        test layer name.
    prototxt : str
        Input caffe prototxt path.
    caffemodel : str
        Input caffe caffemodel path.
    get_top：bool
        get top5 flag

    Returns
    -------
    caffe_output : dict of caffe output
    tvm_output : list of tvm output
    """
    assert op or (prototxt and caffemodel), "op and prototxt cannot be empty at the same time !"

    # preprocess image
    if image:
        image = image_preprocess(image, image_shape)
    else:
        image = np.random.rand(1, 3, image_shape[0], image_shape[1])

    caffe_output, caffe_cost_time = run_caffe(
        image=image, input_shape=image_shape, layer_op=op, net_file=prototxt, caffe_model=caffemodel
    )
    logging.info(f"caffe cost time {caffe_cost_time} s")
    if test_tvm:
        tvm_output, tvm_cost_time = run_tvm(image=image, proto_file=prototxt, blob_file=caffemodel)
        logging.info(f"tvm cost time {tvm_cost_time} s")
    else:
        tvm_output = None

    # delete temp file
    if os.path.exists("deploy.prototxt"):
        os.remove("deploy.prototxt")
    if os.path.exists("deploy.caffemodel"):
        os.remove("deploy.caffemodel")

    return caffe_output, tvm_output
