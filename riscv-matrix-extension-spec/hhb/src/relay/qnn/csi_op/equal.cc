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
 * \file src/relay/qnn/csi_op/equal.cc
 * \brief QNN equal operator.
 */
#include <tvm/relay/analysis.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>

#include "../op/op_common.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {
TVM_REGISTER_NODE_TYPE(QnnBinaryOpAttrs);

bool QnnCSIEqualOpRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                      const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 3);
  if (auto* t0 = types[0].as<TensorTypeNode>()) {
    if (auto* t1 = types[1].as<TensorTypeNode>()) {
      CHECK_EQ(t0->dtype, t1->dtype);
      reporter->Assign(types[2], TensorType(t0->shape, DataType::Bool()));
      return true;
    }
  }
  return false;
}
// QNN Equal operator.
Expr MakeQnnCSIEqual(Expr lhs, Expr rhs, Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnBinaryOpAttrs>();
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.equal");
  return Call(op, {lhs, rhs}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.equal")
    .describe("Elementwise equal for tensors.")
    .set_attrs_type<QnnBinaryOpAttrs>()
    .set_num_inputs(2)
    .add_argument("lhs", "Tensor", "The left hand side quantized tensor.")
    .add_argument("rhs", "Tensor", "The right hand side quantized tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIEqual", QnnCSIEqualOpRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIEqual").set_body_typed(MakeQnnCSIEqual);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
