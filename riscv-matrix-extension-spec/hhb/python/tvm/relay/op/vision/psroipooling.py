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
"""PSRoIPooling operations."""
from . import _make


def psroipooling(data, rois, output_dim, group_size, spatial_scale):
    """ROI pool operator.

    Parameters
    ----------
    data : relay.Expr
        4-D tensor with shape [batch, channel, height, width]

    rois : relay.Expr
        2-D tensor with shape [num_roi, 5]. The last dimension should be in format of
        [batch_index, w_start, h_start, w_end, h_end]

    output_dim : int
        The number of output's channel.

    group_size : int
        The width and height of output

    spatial_scale : float
        Ratio of input feature map height (or w) to raw image height (or w). Equals the reciprocal
        of total stride in convolutional layers, which should be in range (0.0, 1.0]

    Returns
    -------
    output : relay.Expr
        4-D tensor with shape [num_roi, output_dim, group_size, group_size]
    """
    return _make.psroipooling(data, rois, output_dim, group_size, spatial_scale)
