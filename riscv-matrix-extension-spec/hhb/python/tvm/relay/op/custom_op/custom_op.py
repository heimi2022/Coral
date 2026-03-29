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
# pylint: disable=invalid-name, too-many-lines
"""Neural network operations."""
from . import _make
from ..nn.utils import get_pad_tuple1d


def cache_matmul(data, weight, bias, cache_shape, shape, axes):
    r"""
    custom fusion op
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

    Parameters
    ----------
    data : relay.Expr
        input
    cache : relay.Expr
        cache frame
    weight : relay.Expr
        weight for matmul
    bias :
        bias for matmul
    shape : tuple
        shape for transpose
    axes : tuple


    Returns
    -------
    result : relay.Expr
    """

    return _make.cache_matmul(data, weight, bias, cache_shape, shape, axes)


def cache_conv1d(
    data,
    weight,
    bias,
    cache_shape,
    strides=1,
    padding=0,
    dilation=1,
    groups=1,
    channels=None,
    kernel_size=None,
    data_layout="NCW",
    kernel_layout="OIW",
    out_layout="",
    out_dtype="",
):
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

    Parameters
    ----------
    data : relay.Expr
        The input data to the operator.

    weight : relay.Expr
        The weight expressions.

    bias :
        The bias expressions.

    strides : Optional[int, Tuple[int]]
        The strides of convolution.

    padding : Optional[int, Tuple[int]]
        The padding of convolution on both sides of the input before convolution.

    dilation : Optional[int, Tuple[int]]
        Specifies the dilation rate to be used for dilated convolution.

    groups : Optional[int]
        Currently unused for 1D convolution.

    channels : Optional[int]
        Number of output channels of this convolution.

    kernel_size : Optional[int, Tuple[int]]
        The spatial dimension of the convolution kernel.

    data_layout : Optional[str]
        Layout of the input.

    kernel_layout : Optional[str]
        Layout of the weight.

    out_layout : Optional[str]
        Layout of the output, by default, out_layout is the same as data_layout

    out_dtype : Optional[str]
        Specifies the output data type for mixed precision conv2d.

    Returns
    -------
    result : tvm.relay.Expr
        The computed result.
    """
    if isinstance(kernel_size, int):
        kernel_size = (kernel_size,)
    if isinstance(strides, int):
        strides = (strides,)
    if isinstance(dilation, int):
        dilation = (dilation,)
    padding = get_pad_tuple1d(padding)

    return _make.cache_conv1d(
        data,
        weight,
        bias,
        cache_shape,
        strides,
        padding,
        dilation,
        groups,
        channels,
        kernel_size,
        data_layout,
        kernel_layout,
        out_layout,
        out_dtype,
    )
