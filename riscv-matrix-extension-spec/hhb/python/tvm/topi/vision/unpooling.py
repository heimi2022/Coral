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
# pylint: disable=invalid-name
"""unpooling operator"""
import tvm
from tvm.te import hybrid


@hybrid.script
def hybrid_unpooling(data, mask_data, scale_h=2, scale_w=2, pad_out_h=0, pad_out_w=0):
    """Upsampling.

    This operator takes data as input and does 2D scaling to the given scale factor.
    In the default case, where the data_layout is `NCHW`
    with data of shape (n, c, h, w)
    out will have a shape (n, c, h*scale_h, w*scale_w)

    Parameters
    ----------
    data : tvm.relay.Expr
        The input data to the operator.

    scale_h : tvm.relay.Expr
        The scale factor for height upsampling.

    scale_w : tvm.relay.Expr
        The scale factor for width upsampling.

    Returns
    -------
    result : tvm.relay.Expr
        The computed result.
    """
    numb_ = int32(data.shape[0])
    channels_ = int32(data.shape[1])
    height_ = int32(data.shape[2])
    width_ = int32(data.shape[3])

    upsample_h_ = int32(height_ * scale_h - pad_out_h)
    upsample_w_ = int32(width_ * scale_w - pad_out_w)

    out_data = output_tensor((numb_, channels_, upsample_h_, upsample_w_), "float32")

    for n in range(numb_):
        for c in range(channels_):
            for i in range(upsample_h_):
                for j in range(upsample_w_):
                    out_data[n, c, i, j] = 0.0

    for n in range(numb_):
        for c in range(channels_):
            for i in range(height_):
                for j in range(width_):
                    idx = mask_data[n, c, i, j]
                    if idx < upsample_h_ * upsample_w_:
                        o_h = int32(idx / float32(upsample_w_))
                        o_w = int32(idx - o_h * upsample_w_)
                        out_data[n, c, o_h, o_w] = float32(data[n, c, i, j])

    return out_data


@tvm.target.generic_func
def unpooling(data, mask_data, scale_h=2, scale_w=2, pad_out_h=0, pad_out_w=0):
    """Upsampling.

    This operator takes data as input and does 2D scaling to the given scale factor.
    In the default case, where the data_layout is `NCHW`
    with data of shape (n, c, h, w)
    out will have a shape (n, c, h*scale_h, w*scale_w)

    Parameters
    ----------
    data : tvm.relay.Expr
        The input data to the operator.

    scale_h : tvm.relay.Expr
        The scale factor for height upsampling.

    scale_w : tvm.relay.Expr
        The scale factor for width upsampling.

    Returns
    -------
    result : tvm.relay.Expr
        The computed result.
    """
    output = hybrid_unpooling(
        data,
        mask_data,
        tvm.tir.const(scale_h, "int32"),
        tvm.tir.const(scale_w, "int32"),
        tvm.tir.const(pad_out_h, "int32"),
        tvm.tir.const(pad_out_w, "int32"),
    )
    return output
