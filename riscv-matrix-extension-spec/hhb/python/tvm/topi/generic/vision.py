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
# pylint: disable=invalid-name, no-member
"""Generic vision operators"""
from __future__ import absolute_import as _abs
import tvm
from .. import cpp
from .default import default_schedule as _default_schedule


@tvm.target.generic_func
def schedule_reorg(outs):
    """Schedule for reorg

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of reorg
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    target = tvm.target.Target.current(allow_none=False)
    cpp_target = cpp.TEST_create_target(target.kind.name)
    return cpp.generic.default_schedule(cpp_target, outs, False)


def schedule_get_valid_counts(outs):
    """Schedule for get_valid_counts

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of nms
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


def schedule_nms(outs):
    """Schedule for non-maximum suppression

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of nms
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


def schedule_multibox_prior(outs):
    """Schedule for multibox_prior

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of multibox_prior
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


def schedule_multibox_transform_loc(outs):
    """Schedule for multibox_transform_loc

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of
      multibox_transform_loc in the format
      of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


def schedule_multibox_detection(outs):
    """Schedule for multibox_detection

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of multibox_detection
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


def schedule_roi_align(outs):
    """Schedule for roi_align

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of roi_align
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


def schedule_roi_pool(outs):
    """Schedule for roi_align

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of roi_pool
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


@tvm.target.generic_func
def schedule_psroipooling(outs):
    """Schedule for psroipooling

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of psroipooling
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


@tvm.target.generic_func
def schedule_max_pool2d_location(outs):
    """Schedule for pool2d_location

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of pool2d_location
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


@tvm.target.generic_func
def schedule_invert_permutation(outs):
    """Schedule for invert_permutation

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of invert_permutation
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


@tvm.target.generic_func
def schedule_categorical(outs):
    """Schedule for categorical

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of categorical
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


@tvm.target.generic_func
def schedule_standard_normal(outs):
    """Schedule for standard_normal

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of standard_normal
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


@tvm.target.generic_func
def schedule_unpooling(outs):
    """Schedule for unpooling

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of unpooling
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


@tvm.target.generic_func
def schedule_proposal(outs):
    """Schedule for proposal operator.

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of proposal
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


def schedule_segment_op(outs):
    """Schedule for segment_max operator.
    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of segment_max
      in the format of an array of tensors.
    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


def schedule_cumsum(outs):
    """Schedule for cumsum operator.

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of cumsum
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


def schedule_cumprod(outs):
    """Schedule for cumprod operator.

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of cumprod
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


def schedule_hardmax(outs):
    """Schedule for hardmax operator.

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of hardmax
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


def schedule_celu(outs):
    """Schedule for celu operator.

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of celu
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)


def schedule_fsmn(outs):
    """Schedule for fsmn operator.

    Parameters
    ----------
    outs: Array of Tensor
      The computation graph description of fsmn
      in the format of an array of tensors.

    Returns
    -------
    s: Schedule
      The computation schedule for the op.
    """
    return _default_schedule(outs, False)
