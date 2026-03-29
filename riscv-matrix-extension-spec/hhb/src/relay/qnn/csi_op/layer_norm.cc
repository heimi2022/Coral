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
 * \file src/relay/qnn/op/layer_norm.cc
 * \brief Property def of qnn layer_norm operator.
 */

#include <tvm/relay/base.h>
#include <tvm/relay/op.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>

#include "../../op/nn/nn.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {

// relay.op.qnn.layer_norm
TVM_REGISTER_NODE_TYPE(QnnCSILayerNormAttrs);

bool QnnCSILayerNormRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                        const TypeReporter& reporter) {
  ICHECK_EQ(types.size(), 4);
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) return false;
  const QnnCSILayerNormAttrs* param = attrs.as<QnnCSILayerNormAttrs>();
  int axis = param->axis >= 0 ? param->axis : param->axis + data->shape.size();
  ICHECK(axis >= 0 && axis < (int)data->shape.size());
  reporter->Assign(types[1], TensorType({data->shape[axis]}, data->dtype));
  reporter->Assign(types[2], TensorType({data->shape[axis]}, data->dtype));
  reporter->Assign(types[3], TensorType(data->shape, data->dtype));

  return true;
}

Expr MakeQnnCSILayerNorm(Expr data, Expr gamma, Expr beta, int axis, double epsilon, bool center,
                         bool scale, DataType out_dtype, Array<Array<IndexExpr>> q_params,
                         String layer_name) {
  auto attrs = make_object<QnnCSILayerNormAttrs>();
  attrs->axis = std::move(axis);
  attrs->epsilon = std::move(epsilon);
  attrs->center = std::move(center);
  attrs->scale = std::move(scale);

  attrs->out_dtype = std::move(out_dtype);
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.layer_norm");
  return Call(op, {data, gamma, beta}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.layer_norm")
    .describe(R"code(
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSILayerNormAttrs>()
    .set_num_inputs(3)
    .add_argument("data", "Tensor", "Input to which layer_norm will be applied.")
    .add_argument("gamma", "Tensor", "The gamma scale factor.")
    .add_argument("beta", "Tensor", "The beta offset factor.")
    .set_support_level(11)
    .add_type_rel("QnnCSILayerNormRel", QnnCSILayerNormRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSILayerNorm").set_body_typed(MakeQnnCSILayerNorm);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
