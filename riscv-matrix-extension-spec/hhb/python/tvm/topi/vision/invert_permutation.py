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
# pylint: disable=invalid-name
"""invert_permutation operator"""
import tvm
from tvm.te import hybrid


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


@tvm.target.generic_func
def invert_permutation(data):
    output = hybrid_invert_permutation(data)
    return output
