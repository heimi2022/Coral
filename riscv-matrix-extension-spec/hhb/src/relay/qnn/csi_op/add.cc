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
 * \file src/relay/qnn/op/add.cc
 * \brief QNN add operator.
 */
#include <tvm/relay/analysis.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>

#include "../op/op_common.h"

namespace tvm {
namespace relay {
namespace qnn {
TVM_REGISTER_NODE_TYPE(QnnBinaryOpAttrs);

bool QnnCSIBinaryOpRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                       const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 3);
  if (auto* t0 = types[0].as<TensorTypeNode>()) {
    if (auto* t1 = types[1].as<TensorTypeNode>()) {
      reporter->Assign(
          types[2], ConcreteBroadcast(GetRef<TensorType>(t0), GetRef<TensorType>(t1), t0->dtype));
      return true;
    }
  }
  return false;
}

bool QnnCSIBiasOpRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                     const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 3);
  if (types[0].as<TensorTypeNode>()) {
    if (types[1].as<TensorTypeNode>()) {
      reporter->Assign(types[2], types[0]);
      return true;
    }
  }
  return false;
}

// QNN Addition operator.
Expr MakeQnnCSIAdd(Expr lhs, Expr rhs, Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnBinaryOpAttrs>();
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.add");
  return Call(op, {lhs, rhs}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.add")
    .describe("Elementwise add with with broadcasting for quantized tensors.")
    .set_attrs_type<QnnBinaryOpAttrs>()
    .set_num_inputs(2)
    .add_argument("lhs", "Tensor", "The left hand side quantized tensor.")
    .add_argument("rhs", "Tensor", "The right hand side quantized tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIAddcast", QnnCSIBinaryOpRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIAdd").set_body_typed(MakeQnnCSIAdd);

// QNN Addition operator.
Expr MakeQnnCSIBiasAdd(Expr lhs, Expr rhs, Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnBinaryOpAttrs>();
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.bias_add");
  return Call(op, {lhs, rhs}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.bias_add")
    .describe("Elementwise add with with broadcasting for quantized tensors.")
    .set_attrs_type<QnnBinaryOpAttrs>()
    .set_num_inputs(2)
    .add_argument("lhs", "Tensor", "The left hand side quantized tensor.")
    .add_argument("rhs", "Tensor", "The right hand side quantized tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIBiasAddcast", QnnCSIBiasOpRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIBiasAdd").set_body_typed(MakeQnnCSIBiasAdd);

// QNN Subtract operator.
Expr MakeQnnCSISubtract(Expr lhs, Expr rhs, Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnBinaryOpAttrs>();
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.subtract");
  return Call(op, {lhs, rhs}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.subtract")
    .describe("Elementwise subtract with with broadcasting for quantized tensors.")
    .set_attrs_type<QnnBinaryOpAttrs>()
    .set_num_inputs(2)
    .add_argument("lhs", "Tensor", "The left hand side quantized tensor.")
    .add_argument("rhs", "Tensor", "The right hand side quantized tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSISubtractcast", QnnCSIBinaryOpRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSISubtract").set_body_typed(MakeQnnCSISubtract);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
