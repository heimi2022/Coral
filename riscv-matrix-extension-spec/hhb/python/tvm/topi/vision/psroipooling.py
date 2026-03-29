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
# pylint: disable=invalid-name, unused-variable, too-many-nested-blocks
"""PSROI pool operator"""
import tvm
from tvm.te import hybrid


@hybrid.script
def hybrid_psroipooling(data, rois, output_dim, group_size, spatial_scale):
    """PSROI pool operator.

    Parameters
    ----------
    data : tvm.Tensor
        4-D with shape [batch, channel, height, width]

    rois : tvm.Tensor
        2-D with shape [num_roi, 5]. The last dimension should be in format of
        [batch_index, w_start, h_start, w_end, h_end]

    output_dim : int
        The number of output's channel.

    group_size : int
        The width and height of output

    spatial_scale : float
        Ratio of input feature map height (or w) to raw image height (or w). Equals the reciprocal
        of total stride in convolutional layers, which should be in range (0.0, 1.0]
    """
    # dtype = rois.dtype
    num_rois = rois.shape[0]
    channel = data.shape[1]
    height = data.shape[2]
    width = data.shape[3]
    output = output_tensor((num_rois, output_dim, group_size, group_size), "float32")

    for n in range(num_rois):
        roi_start_w = float32(round(rois[n, 1]) * spatial_scale)
        roi_start_h = float32(round(rois[n, 2]) * spatial_scale)
        roi_end_w = float32(round((rois[n, 3] + 1.0)) * spatial_scale)
        roi_end_h = float32(round((rois[n, 4] + 1.0)) * spatial_scale)

        roi_height = max(roi_end_h - roi_start_h, 0.1)
        roi_width = max(roi_end_w - roi_start_w, 0.1)
        bin_size_h = roi_height / float32(group_size)
        bin_size_w = roi_width / float32(group_size)

        for ctop in range(output_dim):
            for ph in range(group_size):
                for pw in range(group_size):
                    hstart = int32(floor(float32(ph) * bin_size_h + roi_start_h))
                    wstart = int32(floor(float32(pw) * bin_size_w + roi_start_w))
                    hend = int32(ceil(float32((ph + 1)) * bin_size_h + roi_start_h))
                    wend = int32(ceil(float32((pw + 1)) * bin_size_w + roi_start_w))

                    hstart = min(max(hstart, 0), height)
                    hend = min(max(hend, 0), height)
                    wstart = min(max(wstart, 0), width)
                    wend = min(max(wend, 0), width)

                    c = (ctop * group_size + ph) * group_size + pw
                    out_sum = 0.0
                    for h in range(hend - hstart):
                        for w in range(wend - wstart):
                            out_sum = out_sum + data[0, c, h + hstart, w + wstart]

                    bin_area = (hend - hstart) * (wend - wstart)

                    if hstart < hend and wstart < wend:
                        output[n, ctop, ph, pw] = out_sum / float32(bin_area)
                    else:
                        output[n, ctop, ph, pw] = 0.0
    return output


@tvm.target.generic_func
def psroipooling(data, rois, output_dim, group_size, spatial_scale):
    output = hybrid_psroipooling(
        data,
        rois,
        tvm.tir.const(output_dim, "int32"),
        tvm.tir.const(group_size, "int32"),
        tvm.tir.const(spatial_scale, rois.dtype),
    )
    return output
