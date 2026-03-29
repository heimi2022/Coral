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
# pylint: disable=invalid-name, too-many-nested-blocks
"""max_pool2d_location operator"""
from ... import te, tir


def _max_pool2d_location(input_data, out_buf, kernel_h, kernel_w, stride_h, stride_w, pad_t, pad_l):

    ib = tir.ir_builder.create()
    data = ib.buffer_ptr(input_data)
    out = ib.buffer_ptr(out_buf)
    temp = ib.allocate("float32", (1,), name="temp_data", scope="local")

    numb_, channels_, height_, width_ = input_data.shape
    pooled_height_ = out_buf.shape[2]
    pooled_width_ = out_buf.shape[3]

    with ib.for_range(0, numb_) as n:
        with ib.for_range(0, channels_) as c:
            with ib.for_range(0, pooled_height_) as ph:
                with ib.for_range(0, pooled_width_) as pw:
                    hstart = ph * stride_h - pad_t
                    wstart = pw * stride_w - pad_l
                    hend = te.min(hstart + kernel_h, height_)
                    wend = te.min(wstart + kernel_w, width_)
                    hstart = te.max(hstart, 0)
                    wstart = te.max(wstart, 0)
                    i_index = (
                        n * channels_ * height_ * width_
                        + c * height_ * width_
                        + hstart * width_
                        + wstart
                    )
                    o_index = (
                        n * channels_ * pooled_height_ * pooled_width_
                        + c * pooled_height_ * pooled_width_
                        + ph * pooled_width_
                        + pw
                    )
                    temp[0] = data[i_index]
                    out[o_index] = tir.Cast("float32", hstart * width_ + wstart)

                    with ib.for_range(0, hend) as h:
                        with ib.if_scope(h >= hstart):
                            with ib.for_range(0, wend) as w:
                                with ib.if_scope(w >= wstart):
                                    t_index = (
                                        n * channels_ * height_ * width_
                                        + c * height_ * width_
                                        + h * width_
                                        + w
                                    )
                                    with ib.if_scope(data[t_index] > temp[0]):
                                        temp[0] = data[t_index]
                                        out[o_index] = tir.Cast("float32", h * width_ + w)

    return ib.get()


def max_pool2d_location(
    data, pool_size=(1, 1), strides=(1, 1), padding=(0, 0), layout="NCHW", ceil_mode=False
):
    """Max pool2d location op

    Parameters
    ----------
    data : tvm.Tensor
        4-D with shape [batch, channel, height, width]

    pool_size : int or tuple of int, optional
        The size of window for pooling.

    strides : tuple of int, optional
        The strides of pooling.

    padding : tuple of int, optional
        The padding for pooling.

    ceil_mode : bool, optional
        To enable or disable ceil while pooling.

    Returns
    -------
    result : tvm.relay.Expr
        The computed result.
    """
    assert layout == "NCHW", "Layout of max_pool2d_location must be NCHW"
    assert ceil_mode, "Ceil_mode must be true."
    kernel_h, kernel_w = pool_size
    stride_h, stride_w = strides
    pad_t, pad_l, pad_d, pad_r = padding
    pad_h = pad_t + pad_d
    pad_w = pad_l + pad_r

    numb_, channels_, height_, width_ = data.shape
    tmp_h = height_ + pad_h - kernel_h
    tmp_h_ = te.div(tmp_h, stride_h)
    tmp_w = width_ + pad_w - kernel_w
    tmp_w_ = te.div(tmp_w, stride_w)
    pooled_height_ = te.ceil(tmp_h_) + 1
    pooled_width_ = te.ceil(tmp_w_) + 1

    top_mask = te.extern(
        [numb_, channels_, pooled_height_, pooled_width_],
        [data],
        lambda ins, outs: _max_pool2d_location(
            ins[0], outs[0], kernel_h, kernel_w, stride_h, stride_w, pad_t, pad_l
        ),
    )

    return top_mask
