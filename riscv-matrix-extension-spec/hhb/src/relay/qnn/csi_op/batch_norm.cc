/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

/*!
 * \file src/relay/qnn/op/mul.cc
 * \brief QNN mul operator.
 */
#include <tvm/relay/analysis.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>

#include "../op/op_common.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {
TVM_REGISTER_NODE_TYPE(QnnCSIBatchNormAttrs);

bool QnnCSIBatchNormRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                        const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 6);
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) return false;

  const QnnCSIBatchNormAttrs* param = attrs.as<QnnCSIBatchNormAttrs>();

  // axis of -1 means use the last dimension
  CHECK(param->axis >= -1 && param->axis < (int)data->shape.size());
  int axis = (param->axis != -1) ? param->axis : data->shape.size() - 1;
  auto axis_size = data->shape[axis];

  // if we are using beta and gamma, they need to be of shape (dim,)
  reporter->Assign(types[1], TensorType({axis_size}, DataType::Float(32)));
  reporter->Assign(types[2], TensorType({axis_size}, DataType::Float(32)));
  reporter->Assign(types[3], TensorType({axis_size}, DataType::Float(32)));
  reporter->Assign(types[4], TensorType({axis_size}, DataType::Float(32)));

  // output is a tuple of the normed data (same shape as input), new running mean,
  // and new running average (the latter two are both vectors of length dim)

  reporter->Assign(types[5], TensorType(data->shape, data->dtype));
  return true;
}

// QNN Multiplication operator.
Expr MakeQnnCSIBatchNorm(Expr data, Expr gamma, Expr beta, Expr moving_mean, Expr moving_var,
                         int axis, double epsilon, bool center, bool scale,
                         Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIBatchNormAttrs>();
  attrs->axis = axis;
  attrs->epsilon = epsilon;
  attrs->center = center;
  attrs->scale = scale;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.bn");
  return Call(op, {data, gamma, beta, moving_mean, moving_var}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.bn")
    .describe(R"code(Batch normalization layer (Ioffe and Szegedy, 2014).
Normalizes the input at each batch, i.e. applies a transformation
that maintains the mean activation close to 0 and the activation
standard deviation close to 1.

.. math::

  data\_mean[i] = mean(data[:,i,:,...]) \\
  data\_var[i] = var(data[:,i,:,...])

Then compute the normalized output, which has the same shape as input, as following:

.. math::

  out[:,i,:,...] = \frac{data[:,i,:,...] - data\_mean[i]}{\sqrt{data\_var[i]+\epsilon}} \
* gamma[i] + beta[i]

Both *mean* and *var* returns a scalar by treating the input as a vector.

Assume the input has size *k* on axis 1, then both ``gamma`` and ``beta`` have shape *(k,)*.

Besides the inputs and the outputs, this operator accepts two auxiliary
states, ``moving_mean`` and ``moving_var``, which are *k*-length
vectors. They are global statistics for the whole dataset, which are updated
by::

  moving_mean = moving_mean * momentum + data_mean * (1 - momentum)
  moving_var = moving_var * momentum + data_var * (1 - momentum)

The parameter ``axis`` specifies which axis of the input shape denotes
the 'channel' (separately normalized groups).  The default is 1.  Specifying -1 sets the channel
axis to be the last item in the input shape.

.. note::
    This operator can be optimized away for inference.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIBatchNormAttrs>()
    .set_num_inputs(5)
    .add_argument("data", "Tensor", "Input to which batch_norm will be applied.")
    .add_argument("gamma", "Tensor", "The gamma scale factor.")
    .add_argument("beta", "Tensor", "The beta offset factor.")
    .add_argument("moving_mean", "Tensor", "Running mean of input.")
    .add_argument("moving_var", "Tensor", "Running variance of input.")
    .set_support_level(11)
    .add_type_rel("QnnCSIBatchNormRel", QnnCSIBatchNormRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.csi_batch_norm").set_body_typed(MakeQnnCSIBatchNorm);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
