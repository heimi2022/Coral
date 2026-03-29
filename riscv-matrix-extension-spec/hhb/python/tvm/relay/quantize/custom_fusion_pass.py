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
# pylint: disable=invalid-name, unused-argument, missing-docstring, unused-import
# pylint: disable=import-outside-toplevel
"""Custom fusion pass."""
import tvm
import numpy as np
from tvm import relay
from ..dataflow_pattern import DFPatternCallback
from ..dataflow_pattern import is_constant, is_var
from ..dataflow_pattern import wildcard, is_op
from ..dataflow_pattern import rewrite, is_tuple
from ..frontend.common import infer_shape
from ..transform import function_pass
from ._convert_to_csi import _qnn_attrs


def conv2python(data):
    return [conv2python(x) if isinstance(x, tvm.ir.container.Array) else int(x) for x in data]


@function_pass(opt_level=1)
class FuseCacheMatMul:
    r"""
    (Cache)
    Gather   Other
       \      /
        Concat
          |
        MatMUl               --> CacheMatMul
          |
         Add
          |
       Reshape
          |
       Transpose
    """

    def transform_function(self, func, mod, ctx):
        """patten and convert op"""

        class MyCallback(DFPatternCallback):
            def __init__(self):
                super(MyCallback, self).__init__()
                # Gathe
                self.input = wildcard()
                # concat
                self.concat = is_op("concatenate")(self.input)
                # Matmul
                self.weight = wildcard()
                self.dense = is_op("nn.dense")(self.concat, self.weight)
                self.b = wildcard()
                self.reshape2 = is_op("reshape")(self.dense)
                self.add = is_op("add")(self.reshape2, self.b)
                self.reshape3 = is_op("reshape")(self.add)
                # transpose
                self.transpose = is_op("transpose")(self.reshape3)
                self.pattern = self.transpose

            def callback(self, pre, post, node_map):
                """taget op"""
                cache, in_node = node_map[self.input][0]
                weight = node_map[self.weight][0]
                bias = node_map[self.b][0]
                t_dims = conv2python(node_map[self.transpose][0].attrs.axes)

                cache_shape = infer_shape(cache)
                reshape = infer_shape(node_map[self.reshape3][0])

                new_node = relay.op.custom_op.cache_matmul(
                    in_node, weight, bias, cache_shape, reshape, t_dims
                )
                return new_node

        out = rewrite(MyCallback(), mod["main"].body)
        res = tvm.IRModule.from_expr(out)

        return res["main"]


@function_pass(opt_level=1)
class FuseCacheConv1d:
    r"""
    (Cache)    Input
      |          |
    Gather   Transpose
       \        /
         Concat               --> CacheConv1d
           |
         Conv1d
           |
        BiasAdd
    """

    def transform_function(self, func, mod, ctx):
        """patten and convert op"""

        class MyCallback(DFPatternCallback):
            def __init__(self):
                super(MyCallback, self).__init__()
                # Input
                self.input = wildcard()
                # Gather
                self.gather = is_op("take")(is_var(), wildcard())
                # Transpose
                self.transpose = is_op("transpose")(self.input)
                # Concat
                self.tup = is_tuple([self.gather, self.transpose])
                self.concat = is_op("concatenate")(self.tup)
                # Conv1d
                self.weight = wildcard()
                self.conv1d = is_op("nn.conv1d")(self.concat, self.weight)
                # BiasAdd
                self.bias = wildcard()
                self.bias_add = is_op("nn.bias_add")(self.conv1d, self.bias)
                self.pattern = self.bias_add

            def callback(self, pre, post, node_map):
                """taget op"""
                in_node = node_map[self.input][0]
                weight = node_map[self.weight][0]
                bias = node_map[self.bias][0]
                cache_shape = infer_shape(node_map[self.gather][0])
                new_node = relay.op.custom_op.cache_conv1d(in_node, weight, bias, cache_shape)
                return new_node

        out = rewrite(MyCallback(), mod["main"].body)
        res = tvm.IRModule.from_expr(out)

        return res["main"]


@function_pass(opt_level=1)
class FuseLayerNormal:
    r"""
        input
       /     \
      |     Mean
       \     /
         Sub
       /     \
      |      Power
              |
      |      Mean
              |
      |      Add               --> LayNormal
              |
      |      Sqrt
       \     /
         Div
          |
         Mul
          |
         Add

    """

    def transform_function(self, func, mod, ctx):
        """patten and convert op"""

        class MyCallback(DFPatternCallback):
            def __init__(self):
                super(MyCallback, self).__init__()
                # input
                self.input = wildcard()
                # mean1
                self.mean1 = is_op("mean")(self.input)
                # sub
                self.sub = is_op("subtract")(self.input, self.mean1)
                # power
                self.power_val = is_constant()
                self.power = is_op("power")(self.sub, self.power_val)
                # mean2
                self.mean2 = is_op("mean")(self.power)
                # add1
                self.add1_val = is_constant()
                self.add1 = is_op("add")(self.mean2, self.add1_val)
                # sqrt
                self.sqrt = is_op("sqrt")(self.add1)
                # div
                self.div = is_op("divide")(self.sub, self.sqrt)
                # mul
                self.mul_val = is_constant()
                self.mul = is_op("multiply")(self.div, self.mul_val)
                # add2
                self.add2_val = is_constant()
                self.add2 = is_op("add")(self.mul, self.add2_val)

                self.pattern = self.add2

            def callback(self, pre, post, node_map):
                """taget op"""
                in_node = node_map[self.input][0]
                axis = int(node_map[self.mean1][0].attrs.axis[0])
                eps = node_map[self.add1_val][0].data.asnumpy().tolist()
                gamma = node_map[self.mul_val][0]
                beta = node_map[self.add2_val][0]

                new_node = relay.op.nn.layer_norm(in_node, gamma, beta, axis, eps)
                return new_node

        out = rewrite(MyCallback(), mod["main"].body)
        res = tvm.IRModule.from_expr(out)

        return res["main"]


@function_pass(opt_level=1)
class TConv1dAddT:
    r"""
      Input
        |
    Transpose           Dense
        |           -->   |
      Conv1D           BiasAdd
        |
     BiasAdd
        |
    Transpose

    """

    def transform_function(self, func, mod, ctx):
        """patten and convert op"""

        class MyCallback(DFPatternCallback):
            def __init__(self):
                super(MyCallback, self).__init__()
                # input
                self.input = wildcard()
                # transpose1
                self.transpose1 = is_op("transpose")(self.input)
                # conv1d
                self.weight_val = is_constant()
                self.bias_val = is_constant()
                self.conv1d = is_op("nn.conv1d")(self.transpose1, self.weight_val).has_attr(
                    {"kernel_size": [1], "groups": 1, "strides": [1], "padding": [0, 0]}
                )
                self.bias_add = is_op("nn.bias_add")(self.conv1d, self.bias_val)
                # transpose2
                self.transpose2 = is_op("transpose")(self.bias_add)
                self.pattern = self.transpose2

            def callback(self, pre, post, node_map):
                """taget op"""
                in_node = node_map[self.input][0]
                weight = node_map[self.weight_val][0].data.asnumpy().squeeze(2)
                weight_exp = relay.const(weight)
                bias = node_map[self.bias_val][0]
                new_dense = relay.op.nn.dense(in_node, weight_exp)
                new_out = relay.op.nn.bias_add(new_dense, bias, axis=2)

                return new_out

        out = rewrite(MyCallback(), mod["main"].body)
        res = tvm.IRModule.from_expr(out)

        return res["main"]


@function_pass(opt_level=1)
class Conv2dSqueezeAdd:
    r"""fusion pass for qnn

        Input
          |
    qnn.csin.conv2d        qnn.csin.conv2d
          |           -->        |
    qnn.csi.reshape        qnn.csi.reshape
          |
     qnn.csi.add

    """

    def transform_function(self, func, mod, ctx):
        """patten and convert op"""

        class MyCallback(DFPatternCallback):
            def __init__(self):
                super(MyCallback, self).__init__()
                # input
                self.input = wildcard()
                # conv2d
                self.weight_val = is_constant()
                self.bias = is_constant()
                self.conv2d = is_op("qnn.csi.conv2d")(self.input, self.weight_val, self.bias)
                # squeeze
                self.squeeze = is_op("qnn.csi.reshape")(self.conv2d)
                # bias_add
                self.bias_val = is_constant()
                self.bias_add = is_op("qnn.csi.add")(self.squeeze, self.bias_val)

                self.pattern = self.bias_add

            def callback(self, pre, post, node_map):
                """taget op"""
                in_node = node_map[self.input][0]
                weight = node_map[self.weight_val][0]
                conv2d = node_map[self.conv2d][0]
                old_bias = node_map[self.bias][0]
                bias = node_map[self.bias_val][0]
                squeeze = node_map[self.squeeze][0]

                old_b_val = old_bias.data.asnumpy()
                bias_val = bias.data.asnumpy()
                b_shape = bias_val.shape
                bias_size = b_shape[0] if len(b_shape) == 1 else b_shape
                conv_attrs = _qnn_attrs(conv2d.attrs)
                bias_attrs = _qnn_attrs(bias.attrs)
                squeeze_attrs = _qnn_attrs(squeeze.attrs)
                conv_attrs["q_params"][-1] = bias_attrs["q_params"][-1]
                squeeze_attrs["q_params"][0] = bias_attrs["q_params"][-1]
                squeeze_attrs["q_params"][-1] = bias_attrs["q_params"][-1]
                if bias_size == conv_attrs["channels"]:
                    new_bias = bias if not old_b_val else relay.const(bias_val + old_b_val)
                    new_conv2d = relay.qnn.op.csi_conv2d(in_node, weight, new_bias, *conv_attrs)
                    new_node = relay.qnn.op.csi_reshape(new_conv2d, **squeeze_attrs)
                else:
                    new_node = bias

                return new_node

        out = rewrite(MyCallback(), mod["main"].body)
        res = tvm.IRModule.from_expr(out)

        return res["main"]


@function_pass(opt_level=1)
class Swish:
    r"""fusion pass for qnn

        Input
       /     \
      |   Sigmoid    -->   Swish
       \     /
         Mul

    """

    def transform_function(self, func, mod, ctx):
        """patten and convert op"""

        class MyCallback(DFPatternCallback):
            def __init__(self):
                super(MyCallback, self).__init__()
                # input
                self.input = wildcard()
                # sigmoid
                self.sigmoid = is_op("sigmoid")(self.input)
                # mul
                self.mul = is_op("multiply")(self.input, self.sigmoid) | is_op("multiply")(
                    self.sigmoid, self.input
                )
                self.pattern = self.mul

            def callback(self, pre, post, node_map):
                """taget op"""
                in_node = node_map[self.input][0]
                new_node = relay.op.nn.swish(in_node)
                return new_node

        out = rewrite(MyCallback(), mod["main"].body)
        res = tvm.IRModule.from_expr(out)

        return res["main"]
