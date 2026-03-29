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
# pylint: disable=invalid-name, unused-argument
"""categorical operator"""
import tvm
from tvm.te import hybrid


@hybrid.script
def hybrid_categorical(data):
    """categorical operator.

    Parameters
    ----------
    logits: 2-D Tensor with shape [batch_size, num_classes]. Each slice [i, :]
            represents the unnormalized log-probabilities for all classes.

    num_samples: 0-D. Number of independent samples to draw for each row slice.

    dtype: integer type to use for the output. Defaults to int64.
    """

    length = data.shape[0]
    output = output_tensor((length,), "int32")

    for i in range(length):
        output[data[i]] = i

    return output


@tvm.target.generic_func
def categorical(data, num_samples, seed, seed2):

    seed = seed or seed2
    assert seed == 0, "Not support for set seed."

    output = hybrid_categorical(data)
    return output
