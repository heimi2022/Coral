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
"""Non-maximum suppression operations."""
from . import _make


def invert_permutation(data):
    """This operation computes the inverse of an index permutation.
    It takes a 1-D integer tensor x, which represents the indices of
    a zero-based array, and swaps each value with its index position.
    In other words, for an output tensor y and an input tensor x, this
    operation computes the following:

    'y[x[i]] = i for i in [0, 1, ..., len(x) - 1]'


    Parameters
    ----------
    data : relay.Expr
        Must be one of the following types: int32, int64. 1-D.
    Returns
    -------
    out : relay.Expr
        3-D tensor with shape [batch_size, num_anchors, 6].
    """
    return _make.invert_permutation(data)
