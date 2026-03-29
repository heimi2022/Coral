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
# pylint: disable=unused-variable, no-else-return, eval-used, multiple-statements
# pylint: disable=consider-using-enumerate, logging-format-interpolation
# pylint: disable=no-else-continue
"""Kaldi frontend."""
import logging
import numpy as np
import tvm
from tvm.ir import IRModule
from .. import analysis
from .. import expr as _expr
from .. import function as _function
from ... import nd as _nd
from .common import ExprTable
from .common import infer_shape as _infer_shape
from .common import AttrCvt

__all__ = ["from_kaldi"]


class OperatorConverter(object):
    """Operator Converted for converting Caffe ops to Relay ops"""

    def __init__(self, predict_layer, exp_tab):
        self.predict_layer = predict_layer
        self.exp_tab = exp_tab
        self.get_input = lambda x: x - 1 if x - 1 != 0 else "input"
        self.unavailable_frames = 0

        self.convert_map = {
            "AffineTransform": self.dense,
            "ParametricRelu": self.prelu,
            "LinearTransform": self.dense,
            "Fsmn": self.fsmn,
            "DeepFsmn": self.dfsmn,
            "Softmax": self.softmax,
            "ReLu": self.relu,
        }

    def fsmn(self, op):
        """Convert Unsample layer"""
        inputs = self.get_input(op["index"])
        in_expr = self.exp_tab.get_expr(inputs)

        l_memory = op["data"][0]
        r_memory = op["data"][1]

        assert op["size_settings"][0] == op["size_settings"][1]
        l_filter = self.exp_tab.new_const(
            l_memory.reshape([-1, op["size_settings"][0]]), dtype="float32"
        )
        r_filter = self.exp_tab.new_const(
            r_memory.reshape([-1, op["size_settings"][1]]), dtype="float32"
        )

        params = dict()
        params["l_stride"] = op["other_settings"]["LStride"]
        params["r_stride"] = op["other_settings"]["RStride"]
        params["l_order"] = op["other_settings"]["LOrder"]
        params["r_order"] = op["other_settings"]["ROrder"]
        params["unavailable_frames"] = self.unavailable_frames

        sequence_len = op["size_settings"][0]

        sequence_size = (
            (params["l_order"] - 1) * params["l_stride"]
            + 1
            + params["r_order"] * params["r_stride"]
        )
        init_sequence = np.zeros([sequence_size, sequence_len], "float32")
        frame_sequence = self.exp_tab.new_const(init_sequence, dtype="float32")
        frame_counter = self.exp_tab.new_const(np.zeros([1], "int32"), dtype="int32")

        self.unavailable_frames += params["r_order"]

        return AttrCvt(op_name="fsmn")(
            [in_expr, l_filter, r_filter, frame_sequence, frame_counter], params
        )

    def dfsmn(self, op):
        """Convert DFSMN layer"""
        raise Exception("Don't support DFSMN now!")

    def softmax(self, op):
        """Convert Softmax layer"""
        inputs = self.get_input(op["index"])
        in_expr = self.exp_tab.get_expr(inputs)

        params = {"axis": 1}

        out = AttrCvt(op_name="softmax")([in_expr], params)

        return out

    def dense(self, op):
        """Convert InnerProduct layer"""
        inputs = self.get_input(op["index"])
        assert op["other_settings"]["LearnRateCoef"] == 1

        params = dict()
        params["num_output"] = op["size_settings"][0]
        params["bias"] = (
            op["other_settings"]["BiasLearnRateCoef"]
            if "BiasLearnRateCoef" in op["other_settings"]
            else None
        )

        # process weight and bias blobs
        weight, bias = None, None
        if params["bias"]:
            weight = op["data"][0]
            # Only support 2D InnerProduct
            params["axis"] = 1
            bias = op["data"][1]
        else:
            weight = op["data"][0]

        if weight.shape[0] == params["num_output"]:
            weight_shape = weight.shape
        else:
            raise Exception(
                f"weight shape does not matc of layer {op['index']} {op['token']} in kaldi model"
            )

        weight_expr = self.exp_tab.new_const(weight, dtype="float32")

        in_expr = self.exp_tab.get_expr(inputs)
        out = AttrCvt(op_name="dense", extras={"units": params["num_output"]})(
            [in_expr, weight_expr], {}
        )

        if bias is not None:
            bias_expr = self.exp_tab.new_const(bias.reshape(-1), dtype="float32")
            out = AttrCvt(op_name="bias_add")([out, bias_expr], {"axis": params["axis"]})
        return out

    def relu(self, op):
        """Convert ReLU layer"""
        inputs = self.get_input(op["index"])
        in_expr = self.exp_tab.get_expr(inputs)

        out = AttrCvt(op_name="relu")([in_expr], {})

        return out

    def prelu(self, op):
        """Convert PReLU layer"""
        inputs = self.get_input(op["index"])
        in_expr = self.exp_tab.get_expr(inputs)

        p_coef = op["data"][0]
        n_coef = op["data"][1]
        if (p_coef == 1).all() and (n_coef == 0).all():
            return AttrCvt(op_name="relu")([in_expr], {})
        else:
            raise tvm.error.OpNotImplemented("ParametricRelu operators are not supported.")

    def check_unsupported_ops(self):
        """Check unsupported Kaldi ops in our converter."""
        logging.debug("check unsupported ops")
        unsupported_ops_set = set()

        for pl in self.predict_layer:
            op_name = pl["token"]
            if op_name not in self.convert_map:
                unsupported_ops_set.add(op_name)

        if unsupported_ops_set:
            msg = "The following operators are not supported in frontend " "Caffe: {}"
            ops = str(list(unsupported_ops_set)).strip("[,]")
            raise tvm.error.OpNotImplemented(msg.format(ops))

    def convert_op_to_relay(self):
        """Convert Kaldi ops to relay ops"""
        logging.debug("convert op to relay")

        for i, pl in enumerate(self.predict_layer):
            op_type = pl["token"]
            pl["index"] = i + 1
            ret = self.convert_map[op_type](pl)

            self.exp_tab.set_expr(pl["index"], ret)
            logging.debug(
                "layer_name:{}, output_name:{}, shape:{}".format(pl["token"], i, _infer_shape(ret))
            )


def from_kaldi(predict_net, shape_dict, dtype_dict):
    """Convert from kaldi model into compatible relay Function.

    Parameters
    ----------
    predict_net : dict
        kaldi layer dict
    shape_dict : dict of str to int list/tuple
        Input shapes of the model.
    dtype_dict : dict of str to str
        Input types of the model.

    Returns
    -------
    mod : tvm.relay.Module
        The relay module for compilation.

    params : dict of str to tvm.NDArray
        The parameter dict to be used by relay
    """
    logging.debug("kaldi frontend")

    exp_tab = ExprTable()

    in_name = "input"
    shape = shape_dict[in_name] if in_name in shape_dict else None
    dtype = dtype_dict[in_name] if in_name in dtype_dict else "float32"
    exp_tab.set_expr(in_name, _expr.var(in_name, shape=shape, dtype=dtype))

    # op code in model
    op_converter = OperatorConverter(predict_net, exp_tab)
    op_converter.check_unsupported_ops()
    op_converter.convert_op_to_relay()

    # params and outputs
    params = {k: _nd.array(np.array(v)) for k, v in exp_tab.params.items()}
    outputs = exp_tab.get_expr(len(op_converter.predict_layer))
    func = _function.Function(analysis.free_vars(outputs), outputs)
    mod = IRModule.from_expr(func)

    return mod, params
