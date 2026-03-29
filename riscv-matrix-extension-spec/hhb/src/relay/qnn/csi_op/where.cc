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
 * \file src/relay/qnn/op/where.cc
 * \brief QNN where operator.
 */
#include <tvm/relay/analysis.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>

#include "../op/op_common.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {

TVM_REGISTER_NODE_TYPE(QnnCSIUnaryAttrs);

bool QnnCSIWhereRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                    const TypeReporter& reporter) {
  ICHECK_EQ(types.size(), 4U);
  const auto* condition = types[0].as<TensorTypeNode>();
  const auto* x = types[1].as<TensorTypeNode>();
  const auto* y = types[2].as<TensorTypeNode>();

  if (condition == nullptr || x == nullptr || y == nullptr) {
    return false;
  }

  ICHECK_EQ(x->dtype, y->dtype) << "x and y must have the same dtype: " << x->dtype << " vs "
                                << y->dtype;

  auto tensor_ty_condition = GetRef<TensorType>(condition);
  auto tensor_ty_x = GetRef<TensorType>(x);
  auto tensor_ty_y = GetRef<TensorType>(y);

  auto b_ty = ConcreteBroadcast(tensor_ty_x, tensor_ty_y, x->dtype);
  auto ret_ty = ConcreteBroadcast(tensor_ty_condition, b_ty, b_ty->dtype);

  reporter->Assign(types[3], ret_ty);
  return true;
}

Expr MakeQnnCSIWhere(const Expr& condition, const Expr& x, const Expr& y, DataType out_dtype,
                     Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIUnaryAttrs>();
  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.where");
  return Call(op, {condition, x, y}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.where")
    .describe(R"code(
Return the elements, either from x or y, depending on the condition.

Given three ndarrays, condition, x, and y, return an ndarray with the elements
from x or y, depending on the elements from condition are true or false.

Shapes of condition, x, and y must be broadcastable to a common shape, which
is the output shape of this op. Semantics follow numpy where function.
https://numpy.org/doc/stable/reference/generated/numpy.where.html

Note that all non-zero values are interpreted as True in condition.

Examples::

  x = [[1, 2], [3, 4]]
  y = [[5, 6], [7, 8]]
  cond = [[0, 1], [-1, 0]]
  where(cond, x, y) = [[5, 2], [3, 8]]


  cond = [[1], [0]]
  where(cond, x, y) = [[1, 2], [7, 8]]

  cond = [0, 1]
  where(cond, 1, -1) = [-1, 1]

)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIUnaryAttrs>()
    .set_num_inputs(3)
    .add_argument("condition", "Tensor", "Condition array")
    .add_argument("x", "Tensor", "First array to be selected")
    .add_argument("y", "Tensor", "Second array to be selected")
    .set_support_level(11)
    .add_type_rel("QnnCSIWhereRel", QnnCSIWhereRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIWhere").set_body_typed(MakeQnnCSIWhere);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
