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
# pylint: disable=invalid-name, unused-variable, too-many-locals
# pylint: disable=unused-argument, redefined-builtin
"""fsmn operators"""
from .. import te, tir
from ..utils import get_const_tuple


def fsmn(
    frame,
    l_filter,
    r_filter,
    frame_sequence,
    frame_counter,
    l_order,
    r_order,
    l_stride,
    r_stride,
    unavailable_frames,
):
    """fsmn operator.

    Parameters
    ----------
    Input : tvm.te.Tensor
        2-D with shape [1, in_width]

    l_filter : tvm.te.Tensor
        2-D with shape [l_order, in_width]

    r_filter : tvm.te.Tensor
        2-D with shape [r_order, in_width]

    frame_sequence: tvm.te.Tensor
        2-D with shape [(l_order -1) * l_stride + r_order * r_stride, in_width ]

    l_stride : int
        Left stride size

    r_stride : int
        Right stride size

    Returns
    -------
    Output : tvm.te.Tensor
        2-D with shape [1, in_width]
    """

    def _fsmn(
        frame,
        l_filter_,
        r_filter_,
        frame_sequence,
        frame_counter,
        out_buf,
        l_order,
        r_order,
        l_stride,
        r_stride,
        unavailable_frames,
    ):
        ib = tir.ir_builder.create()
        last_frame = ib.buffer_ptr(frame)
        past_filter = ib.buffer_ptr(l_filter_)
        future_filter = ib.buffer_ptr(r_filter_)
        sequence_frame = ib.buffer_ptr(frame_sequence)
        frame_counter_ = ib.buffer_ptr(frame_counter)
        out = ib.buffer_ptr(out_buf)

        # len_order = (l_order -1) * l_stride + r_order * r_stride
        len_order, length = get_const_tuple(frame_sequence.shape)

        with ib.for_range(0, length) as i:
            out[i] = 0.0

        frame_counter_[0] = frame_counter_[0] + 1

        # set last frame to sequence tail.
        with ib.if_scope(frame_counter_[0] > unavailable_frames):
            with ib.for_range(0, len_order) as i:
                with ib.for_range(0, length) as j:
                    new_index = i * length + j
                    with ib.if_scope(i == (len_order - 1)):
                        sequence_frame[new_index] = last_frame[j]
                    with ib.else_scope():
                        original_index = (i + 1) * length + j
                        sequence_frame[new_index] = sequence_frame[original_index]

        # past frame
        with ib.for_range(0, l_order) as k:
            with ib.for_range(0, length) as l:
                in_index = k * l_stride * length + l
                filter_index = (l_order - k - 1) * length + l
                out[l] = past_filter[filter_index] * sequence_frame[in_index] + out[l]

        # current frame
        with ib.for_range(0, length) as m:
            in_index = (l_order - 1) * length * l_stride + m
            out[m] = sequence_frame[in_index] + out[m]

        # future frame
        with ib.for_range(0, r_order) as m:
            with ib.for_range(0, length) as n:
                in_index = m * r_stride * length + n + l_order * l_stride * length
                filter_index = m * length + n
                out[n] = future_filter[filter_index] * sequence_frame[in_index] + out[n]

        return ib.get()

    out_shape = list(get_const_tuple(frame.shape))
    out = te.extern(
        out_shape,
        [frame, l_filter, r_filter, frame_sequence, frame_counter],
        lambda ins, outs: _fsmn(
            ins[0],
            ins[1],
            ins[2],
            ins[3],
            ins[4],
            outs[0],
            l_order,
            r_order,
            l_stride,
            r_stride,
            unavailable_frames,
        ),
        dtype=frame.dtype,
    )

    return out
