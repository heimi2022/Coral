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
"""max_pool2d_location operations."""
from . import _make


def extract_image_patches(
    data, ksizes=(1, 1), strides=(1, 1), rates=(1, 1), padding=(0, 0), layout="NCHW"
):
    r"""2D maximum extract_image_patches operator.

    This operator takes data as input and gets 2D max value location
    with in pool_size sized window by striding defined by stride

    Parameters
    ----------
    data : tvm.relay.Expr
        The input data to the operator.

    ksizes : int or tuple of int, optional
        The size of window for kernel.

    strides : tuple of int, optional
        The strides of pooling.

    rates : tuple of int, optional
        The dilated of kernel.

    padding : tuple of int, optional
        The padding for pooling.

    layout : str, optional
        Layout of the input.

    Returns
    -------
    result : tvm.relay.Expr
        The computed result.
    """
    return _make.extract_image_patches(data, ksizes, strides, rates, padding, layout)
