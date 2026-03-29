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
# pylint: disable=invalid-name, unused-argument, too-many-nested-blocks
# pylint: disable=unused-variable, chained-comparison
"""extract_image_patches operator"""
import tvm
from tvm.te import hybrid


@hybrid.script
def hybrid_extract_image_patches(data, ksizes, strides, rates, padding):
    """extract_image_patches operator.

    Parameters
    ----------
    data : tvm.Tensor
        4-D with shape [batch, channel, height, width]

    ksizes : tvm.array
        1-D with shape [kernel_size_h, kernel_size_w].

    strides : tvm.array
        1-d with shape [stride_h, stride_w].

    rates : tvm.array
        just list dilated.
        1-d with shape [dilated_h, dilated_w].

    padding : tvm.array
        1-d with shape [pad_l, pad_t, pad_r, pad_d]
    """
    # dtype = rois.dtype
    batch, channel, in_height, in_width = data.shape
    k_h, k_w = ksizes
    stride_h, stride_w = strides
    dilated_h, dilated_w = rates
    pad_l, pad_t, pad_r, pad_d = padding

    # output shape
    out_channel = k_h * k_w * channel

    output = output_tensor((batch, out_channel, out_height, out_width), "float32")

    for b in range(batch):
        for c in range(channel):
            for out_y in range(out_height):
                for out_x in range(out_width):
                    in_x_origin = (out_x * stride_width) - pad_left
                    in_y_origin = (out_y * stride_height) - pad_top
                    for filter_y in range(filter_height):
                        for filter_x in range(filter_width):
                            in_x = in_x_origin + dilation_width_factor * filter_x
                            in_y = in_y_origin + dilation_height_factor * filter_y
                            o_x = out_x + filter_x
                            o_y = out_y + filter_y
                            if (
                                (in_x >= 0)
                                and (in_x < input_width)
                                and (in_y >= 0)
                                and (in_y < input_height)
                            ):
                                output[b, c, o_y, o_x] = data[batch, c, in_y, in_x]

    return output


@tvm.target.generic_func
def extract_image_patches(data, ksizes, strides, rates, padding):
    output = hybrid_extract_image_patches(
        data,
        ksizes,
        tvm.tir.const(output_dim, "int32"),
        tvm.tir.const(group_size, "int32"),
        tvm.tir.const(spatial_scale, rois.dtype),
    )
    return output
