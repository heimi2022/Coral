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
"""unpooling operations."""
from . import _make


def unpooling(data, mask_data, scale_h=1, scale_w=1, pad_out_h=0, pad_out_w=0, layout="NCHW"):
    """Unpooling.

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

    layout : str, optional
        Layout of the input.

    Returns
    -------
    result : tvm.relay.Expr
        The computed result.
    """
    return _make.unpooling(data, mask_data, scale_h, scale_w, pad_out_h, pad_out_w, layout)
