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
"""Internal utilities for parsing Python subset to TIR"""

import ast
import inspect
import logging
import sys
import numpy

import tvm.runtime
from tvm._ffi.base import numeric_types
from tvm.ir.container import Array

from tvm.tir import expr as _expr
from tvm.tir import stmt as _stmt
from tvm.te.tensor import Tensor


# pylint: disable=invalid-name
np_arg_types = tuple(list(numeric_types) + [numpy.ndarray])
tvm_arg_types = (Tensor, Array, _expr.Var, _expr.ConstExpr)
halide_imm_types = (_expr.IntImm, _expr.FloatImm)


def _internal_assert(cond, err):
    """Simplify the code segment like if not XXX then raise an error"""
    if not cond:
        raise ValueError(err)


# Useful constants. In avoid of runtime dependences, we use function calls to return them.
def make_nop():
    """Returns a 'no operation' node in HalideIR."""
    return _stmt.Evaluate(tvm.runtime.const(0, dtype="int32"))


def is_docstring(node):
    """Checks if a Python AST node is a docstring"""
    return isinstance(node, ast.Expr) and isinstance(node.value, ast.Str)


def _pruned_source(func):
    """Prune source code's extra leading spaces"""
    try:
        lines = inspect.getsource(func).split("\n")
        leading_space = len(lines[0]) - len(lines[0].lstrip(" "))
        lines = [line[leading_space:] for line in lines]
        return "\n".join(lines)
    except IOError as err:
        if sys.version_info[0] == 2 and str(err) == "could not get source code":
            logging.log(
                logging.CRITICAL,
                "This module is not fully operated under Python2... " "Please move to Python3!",
            )
            raise err

    if func.__name__ == "_scatter_add_1d":
        return """
@hybrid.script
def _scatter_add_1d(data, indices, updates):
    out = output_tensor(data.shape, data.dtype)
    for i in range(data.shape[0]):
        out[i] = data[i]
    for i in range(indices.shape[0]):
        out[indices[i] if indices[i] >= 0 else indices[i] + data.shape[0]] += updates[i]
    return out
        """
    if func.__name__ == "roi_align_nchw_ir":
        return """
@hybrid.script
def roi_align_nchw_ir(
    data, rois, num_rois, w_pc, pos_pc, pooled_size, spatial_scale, sample_ratio, mode
):
    channels = data.shape[1]
    height = data.shape[2]
    width = data.shape[3]
    pooled_size_h = pooled_size[0]
    pooled_size_w = pooled_size[1]
    output = output_tensor((num_rois, channels, pooled_size_h, pooled_size_w), data.dtype)

    for n in parallel(num_rois):
        roi_batch_index = int32(rois[n, 0])
        roi_start_w = rois[n, 1] * spatial_scale
        roi_start_h = rois[n, 2] * spatial_scale
        roi_end_w = rois[n, 3] * spatial_scale
        roi_end_h = rois[n, 4] * spatial_scale

        roi_h = max(roi_end_h - roi_start_h, 1.0)
        roi_w = max(roi_end_w - roi_start_w, 1.0)

        bin_h = roi_h / pooled_size_h
        bin_w = roi_w / pooled_size_w

        roi_bin_grid_h = sample_ratio
        roi_bin_grid_w = roi_bin_grid_h
        rounded_bin_h = int32(bin_h) * 1.0
        rounded_bin_w = int32(bin_w) * 1.0
        if sample_ratio <= 0:
            # Cannot use ceil function since hybrid script
            # doesn't support Call as indexing
            roi_bin_grid_h = int32(bin_h)
            roi_bin_grid_w = int32(bin_w)
            if rounded_bin_h < bin_h:
                roi_bin_grid_h += 1
            if rounded_bin_w < bin_w:
                roi_bin_grid_w += 1

        count = roi_bin_grid_h * roi_bin_grid_w

        # Pre-calculate indices and weights shared by all channels.
        # This is the key point of optimization.
        pre_calc_index = 0
        iy_upper = roi_bin_grid_h
        ix_upper = roi_bin_grid_w
        for ph in range(pooled_size_h):
            for pw in range(pooled_size_w):
                for iy in range(iy_upper):
                    yy = roi_start_h + ph * bin_h + (iy + 0.5) * bin_h / roi_bin_grid_h
                    for ix in range(ix_upper):
                        xx = roi_start_w + pw * bin_w + (ix + 0.5) * bin_w / roi_bin_grid_w
                        x = xx
                        y = yy
                        if y < -1.0 or y > height or x < -1.0 or x > width:
                            for i in range(4):
                                w_pc[n, pre_calc_index, i] = 0.0
                                pos_pc[n, pre_calc_index, i] = 0
                        else:
                            if y < 0.0:
                                y = 0.0
                            if x < 0.0:
                                x = 0.0

                            y_low = int32(y)
                            x_low = int32(x)
                            x_high = x_low + 1
                            y_high = y_low + 1

                            if y_low >= height - 1:
                                y_high = height - 1
                                y_low = y_high
                                y = float32(y_low)

                            if x_low >= width - 1:
                                x_high = width - 1
                                x_low = x_high
                                x = float32(x_low)

                            ly = y - y_low
                            lx = x - x_low
                            hy = 1.0 - ly
                            hx = 1.0 - lx
                            w1 = hy * hx
                            w2 = hy * lx
                            w3 = ly * hx
                            w4 = ly * lx

                            pos_pc[n, pre_calc_index, 0] = x_low
                            pos_pc[n, pre_calc_index, 1] = x_high
                            pos_pc[n, pre_calc_index, 2] = y_low
                            pos_pc[n, pre_calc_index, 3] = y_high
                            w_pc[n, pre_calc_index, 0] = w1
                            w_pc[n, pre_calc_index, 1] = w2
                            w_pc[n, pre_calc_index, 2] = w3
                            w_pc[n, pre_calc_index, 3] = w4

                        pre_calc_index += 1

        for c in range(channels):
            pre_calc_index = 0
            for ph in range(pooled_size_h):
                for pw in range(pooled_size_w):
                    output_val = 0.0  # Avg mode
                    if mode == 1:  # Max mode
                        output_val = ninf("float32")
                    for iy in range(roi_bin_grid_h):
                        for ix in range(roi_bin_grid_w):
                            bilinear_val = (
                                w_pc[n, pre_calc_index, 0]
                                * data[
                                    roi_batch_index,
                                    c,
                                    pos_pc[n, pre_calc_index, 2],
                                    pos_pc[n, pre_calc_index, 0],
                                ]
                                + w_pc[n, pre_calc_index, 1]
                                * data[
                                    roi_batch_index,
                                    c,
                                    pos_pc[n, pre_calc_index, 2],
                                    pos_pc[n, pre_calc_index, 1],
                                ]
                                + w_pc[n, pre_calc_index, 2]
                                * data[
                                    roi_batch_index,
                                    c,
                                    pos_pc[n, pre_calc_index, 3],
                                    pos_pc[n, pre_calc_index, 0],
                                ]
                                + w_pc[n, pre_calc_index, 3]
                                * data[
                                    roi_batch_index,
                                    c,
                                    pos_pc[n, pre_calc_index, 3],
                                    pos_pc[n, pre_calc_index, 1],
                                ]
                            )
                            pre_calc_index += 1
                            if mode == 0:  # Avg mode
                                output_val += bilinear_val / count
                            if mode == 1:  # Max mode
                                output_val = max(output_val, bilinear_val)
                        output[n, c, ph, pw] = output_val
    return output



        """
    if func.__name__ == "_arange_shape_func":
        return """
@script
def _arange_shape_func(start, stop, step):
    out = output_tensor((1,), "int64")
    if step[0] < 0:
        out[0] = int64(ceil_div((int64(start[0]) - int64(stop[0])), int64(-step[0])))
    else:
        out[0] = int64(ceil_div((int64(stop[0]) - int64(start[0])), int64(step[0])))
    return out
        """

    if func.__name__ == "hybrid_psroipooling":
        return '''
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
                    '''
    if func.__name__ == "hybrid_extract_image_patches":
        return '''
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
                '''
    if func.__name__ == "hybrid_invert_permutation":
        return '''
@hybrid.script
def hybrid_invert_permutation(data):
    """invert_permutation operator.

    Parameters
    ----------
    data : tvm.Tensor
        Must be one of the following types: int32, int64. 1-D.
    """

    length = data.shape[0]
    output = output_tensor((length,), "int32")

    for i in range(length):
        output[data[i]] = i

    return output
                '''
    if func.__name__ == "hybrid_rearrange_box_out":
        return '''
@hybrid.script
def hybrid_rearrange_box_out(data, one, batch_size, num_anchors):
    """Hybrid routine to rearrange nms output to
    move all valid entries to top.

    Parameters
    ----------
    data : tvm.te.Tensor or numpy NDArray
        NMS output. 3-D tensor with shape
        [batch_size, num_anchors, 6].

    one: tvm.tir.const
        Constant one with the same dtype as data.

    batch_size: tvm.tir.IntImm or tvm.tir.Var
        Batch size. We need to pass it in since hybrid script doesn't support
        binding variable to symbolic dim.

    num_anchors: tvm.tir.IntImm or tvm.tir.Var
        Number of anchors.

    Returns
    -------
    output : tvm.te.Tensor or numpy NDArray
        Transformed NMS output. 3-D tensor with shape
        [batch_size, num_anchors, 6].
    """
    elem_length = data.shape[2]
    output = output_tensor((batch_size, num_anchors, elem_length), data.dtype)

    for i in parallel(batch_size):
        valid_idx = 0
        for j in range(num_anchors):
            if data[i, j, 0] >= 0:
                for k in range(elem_length):
                    output[i, valid_idx, k] = data[i, j, k]
                valid_idx += 1
            if j >= valid_idx:
                for k in range(elem_length):
                    output[i, j, k] = -one
    return output
                '''
    if func.__name__ == "hybrid_unpooling":
        return '''
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
                '''
    if func.__name__ == "_scatter_1d":
        return """
@hybrid.script
def _scatter_1d(data, indices, updates):
    out = output_tensor(data.shape, data.dtype)
    for i in range(data.shape[0]):
        out[i] = data[i]
    for i in range(indices.shape[0]):
        out[indices[i] if indices[i] >= 0 else indices[i] + data.shape[0]] = updates[i]
    return out
                """
    if func.__name__ == "_scatter_2d":
        return """
@hybrid.script
def _scatter_2d(data, indices, updates, axis):
    out = output_tensor(data.shape, data.dtype)
    for i in range(data.shape[0]):
        for j in range(data.shape[1]):
            out[i, j] = data[i, j]
    if axis == 0:
        for i in range(indices.shape[0]):
            for j in range(indices.shape[1]):
                out[
                    indices[i, j] if indices[i, j] >= 0 else indices[i, j] + data.shape[axis], j
                ] = updates[i, j]
    else:
        for i in range(indices.shape[0]):
            for j in range(indices.shape[1]):
                out[
                    i, indices[i, j] if indices[i, j] >= 0 else indices[i, j] + data.shape[axis]
                ] = updates[i, j]

    return out
                """
    if func.__name__ == "_scatter_3d":
        return """
@hybrid.script
def _scatter_3d(data, indices, updates, axis):
    out = output_tensor(data.shape, data.dtype)
    for i in range(data.shape[0]):
        for j in range(data.shape[1]):
            for k in range(data.shape[2]):
                out[i, j, k] = data[i, j, k]
    if axis == 0:
        for i in range(indices.shape[0]):
            for j in range(indices.shape[1]):
                for k in range(indices.shape[2]):
                    out[
                        indices[i, j, k]
                        if indices[i, j, k] >= 0
                        else indices[i, j, k] + data.shape[axis],
                        j,
                        k,
                    ] = updates[i, j, k]
    elif axis == 1:
        for i in range(indices.shape[0]):
            for j in range(indices.shape[1]):
                for k in range(indices.shape[2]):
                    out[
                        i,
                        indices[i, j, k]
                        if indices[i, j, k] >= 0
                        else indices[i, j, k] + data.shape[axis],
                        k,
                    ] = updates[i, j, k]
    else:
        for i in range(indices.shape[0]):
            for j in range(indices.shape[1]):
                for k in range(indices.shape[2]):
                    out[
                        i,
                        j,
                        indices[i, j, k]
                        if indices[i, j, k] >= 0
                        else indices[i, j, k] + data.shape[axis],
                    ] = updates[i, j, k]

    return out
                """
    if func.__name__ == "_scatter_4d":
        return """
@hybrid.script
def _scatter_4d(data, indices, updates, axis):
    out = output_tensor(data.shape, data.dtype)
    for i in range(data.shape[0]):
        for j in range(data.shape[1]):
            for k in range(data.shape[2]):
                for l in range(data.shape[3]):
                    out[i, j, k, l] = data[i, j, k, l]

    if axis == 0:
        for i in range(indices.shape[0]):
            for j in range(indices.shape[1]):
                for k in range(indices.shape[2]):
                    for l in range(indices.shape[3]):
                        out[
                            indices[i, j, k, l]
                            if indices[i, j, k, l] >= 0
                            else indices[i, j, k, l] + data.shape[axis],
                            j,
                            k,
                            l,
                        ] = updates[i, j, k, l]
    elif axis == 1:
        for i in range(indices.shape[0]):
            for j in range(indices.shape[1]):
                for k in range(indices.shape[2]):
                    for l in range(indices.shape[3]):
                        out[
                            i,
                            indices[i, j, k, l]
                            if indices[i, j, k, l] >= 0
                            else indices[i, j, k, l] + data.shape[axis],
                            k,
                            l,
                        ] = updates[i, j, k, l]
    elif axis == 2:
        for i in range(indices.shape[0]):
            for j in range(indices.shape[1]):
                for k in range(indices.shape[2]):
                    for l in range(indices.shape[3]):
                        out[
                            i,
                            j,
                            indices[i, j, k, l]
                            if indices[i, j, k, l] >= 0
                            else indices[i, j, k, l] + data.shape[axis],
                            l,
                        ] = updates[i, j, k, l]
    else:
        for i in range(indices.shape[0]):
            for j in range(indices.shape[1]):
                for k in range(indices.shape[2]):
                    for l in range(indices.shape[3]):
                        out[
                            i,
                            j,
                            k,
                            indices[i, j, k, l]
                            if indices[i, j, k, l] >= 0
                            else indices[i, j, k, l] + data.shape[axis],
                        ] = updates[i, j, k, l]

    return out
                """
    if func.__name__ == "roi_align_nchw_ir":
        return """
@hybrid.script
def roi_align_nchw_ir(data, rois, num_rois, w_pc, pos_pc, pooled_size, spatial_scale, sample_ratio):
    channels = data.shape[1]
    height = data.shape[2]
    width = data.shape[3]
    pooled_size_h = pooled_size[0]
    pooled_size_w = pooled_size[1]
    output = output_tensor((num_rois, channels, pooled_size_h, pooled_size_w), data.dtype)

    for n in parallel(num_rois):
        roi_batch_index = int32(rois[n, 0])
        roi_start_w = rois[n, 1] * spatial_scale
        roi_start_h = rois[n, 2] * spatial_scale
        roi_end_w = rois[n, 3] * spatial_scale
        roi_end_h = rois[n, 4] * spatial_scale

        roi_h = max(roi_end_h - roi_start_h, 1.0)
        roi_w = max(roi_end_w - roi_start_w, 1.0)

        bin_h = roi_h / pooled_size_h
        bin_w = roi_w / pooled_size_w

        roi_bin_grid_h = sample_ratio
        roi_bin_grid_w = roi_bin_grid_h
        rounded_bin_h = int32(bin_h) * 1.0
        rounded_bin_w = int32(bin_w) * 1.0
        if sample_ratio <= 0:
            # Cannot use ceil function since hybrid script
            # doesn't support Call as indexing
            roi_bin_grid_h = int32(bin_h)
            roi_bin_grid_w = int32(bin_w)
            if rounded_bin_h < bin_h:
                roi_bin_grid_h += 1
            if rounded_bin_w < bin_w:
                roi_bin_grid_w += 1

        count = roi_bin_grid_h * roi_bin_grid_w

        # Pre-calculate indices and weights shared by all channels.
        # This is the key point of optimization.
        pre_calc_index = 0
        iy_upper = roi_bin_grid_h
        ix_upper = roi_bin_grid_w
        for ph in range(pooled_size_h):
            for pw in range(pooled_size_w):
                for iy in range(iy_upper):
                    yy = roi_start_h + ph * bin_h + (iy + 0.5) * bin_h / roi_bin_grid_h
                    for ix in range(ix_upper):
                        xx = roi_start_w + pw * bin_w + (ix + 0.5) * bin_w / roi_bin_grid_w
                        x = xx
                        y = yy
                        if y < -1.0 or y > height or x < -1.0 or x > width:
                            for i in range(4):
                                w_pc[n, pre_calc_index, i] = 0.0
                                pos_pc[n, pre_calc_index, i] = 0
                        else:
                            if y < 0.0:
                                y = 0.0
                            if x < 0.0:
                                x = 0.0

                            y_low = int32(y)
                            x_low = int32(x)
                            x_high = x_low + 1
                            y_high = y_low + 1

                            if y_low >= height - 1:
                                y_high = height - 1
                                y_low = y_high
                                y = float32(y_low)

                            if x_low >= width - 1:
                                x_high = width - 1
                                x_low = x_high
                                x = float32(x_low)

                            ly = y - y_low
                            lx = x - x_low
                            hy = 1.0 - ly
                            hx = 1.0 - lx
                            w1 = hy * hx
                            w2 = hy * lx
                            w3 = ly * hx
                            w4 = ly * lx

                            pos_pc[n, pre_calc_index, 0] = x_low
                            pos_pc[n, pre_calc_index, 1] = x_high
                            pos_pc[n, pre_calc_index, 2] = y_low
                            pos_pc[n, pre_calc_index, 3] = y_high
                            w_pc[n, pre_calc_index, 0] = w1
                            w_pc[n, pre_calc_index, 1] = w2
                            w_pc[n, pre_calc_index, 2] = w3
                            w_pc[n, pre_calc_index, 3] = w4

                        pre_calc_index += 1

        for c in range(channels):
            pre_calc_index = 0
            for ph in range(pooled_size_h):
                for pw in range(pooled_size_w):
                    output_val = 0.0
                    for iy in range(roi_bin_grid_h):
                        for ix in range(roi_bin_grid_w):
                            output_val += (
                                w_pc[n, pre_calc_index, 0]
                                * data[
                                    roi_batch_index,
                                    c,
                                    pos_pc[n, pre_calc_index, 2],
                                    pos_pc[n, pre_calc_index, 0],
                                ]
                                + w_pc[n, pre_calc_index, 1]
                                * data[
                                    roi_batch_index,
                                    c,
                                    pos_pc[n, pre_calc_index, 2],
                                    pos_pc[n, pre_calc_index, 1],
                                ]
                                + w_pc[n, pre_calc_index, 2]
                                * data[
                                    roi_batch_index,
                                    c,
                                    pos_pc[n, pre_calc_index, 3],
                                    pos_pc[n, pre_calc_index, 0],
                                ]
                                + w_pc[n, pre_calc_index, 3]
                                * data[
                                    roi_batch_index,
                                    c,
                                    pos_pc[n, pre_calc_index, 3],
                                    pos_pc[n, pre_calc_index, 1],
                                ]
                            )
                            pre_calc_index += 1

                    output_val /= count
                    output[n, c, ph, pw] = output_val

    return output
                """


def replace_io(body, rmap):
    """Replacing tensors usage according to the dict given"""
    # pylint: disable=import-outside-toplevel
    from tvm.tir import stmt_functor

    def replace(op):
        if isinstance(op, _stmt.ProducerStore) and op.producer.op in rmap.keys():
            buf = rmap[op.producer.op]
            return _stmt.ProducerStore(buf, op.value, op.indices)
        if isinstance(op, _expr.ProducerLoad) and op.producer.op in rmap.keys():
            buf = rmap[op.producer.op]
            return _expr.ProducerLoad(buf, op.indices)
        return None

    return stmt_functor.ir_transform(body, None, replace, ["tir.ProducerStore", "tir.ProducerLoad"])


def _is_tvm_arg_types(args):
    """Determine a list of element is either a list of tvm arguments of a list of numpy arguments.
    If neither is true, raise a value error."""
    if isinstance(args[0], tvm_arg_types):
        for elem in args[1:]:
            _internal_assert(
                isinstance(elem, tvm_arg_types),
                "Expecting a Var, Tensor or ConstExpr instance but %s get!" % str(type(elem)),
            )
        return True

    _internal_assert(
        isinstance(args[0], np_arg_types), "Expect a numpy type but %s get!" % str(type(args[0]))
    )
    for elem in args[1:]:
        _internal_assert(
            isinstance(elem, np_arg_types), "Expect a numpy type but %s get!" % str(type(elem))
        )
    return False
