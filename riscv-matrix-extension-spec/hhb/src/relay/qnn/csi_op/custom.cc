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
 * \file src/relay/qnn/op/custom.cc
 * \brief QNN custom operator. It concatenates quantized input tensors along a given axis.
 */

#include <tvm/relay/analysis.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>
#include <tvm/tir/expr.h>

#include "../../op/tensor/transform.h"
#include "../op/op_common.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {

TVM_REGISTER_NODE_TYPE(QnnCSICustomAttrs);

bool QnnCSICustomOpRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                       const TypeReporter& reporter) {
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) return false;
  for (size_t i = 1; i < types.size(); ++i) {
    reporter->Assign(types[i], types[0]);
  }
  return true;
}

void process_custom_attr(Array<String> src_attr, std::map<String, String>* dest_attr) {
  uint size = src_attr.size();
  CHECK_EQ(size % 2, 0);
  for (uint i = 0; i < size; i += 2) {
    dest_attr->insert({src_attr[i], src_attr[i + 1]});
  }
}

Expr MakeQnnCSICustomOp(Expr data, String op_type, Array<String> custom_attr, String layer_name) {
  auto attrs = make_object<QnnCSICustomAttrs>();

  attrs->op_type = std::move(op_type);
  process_custom_attr(custom_attr, &attrs->custom_attr);
  attrs->layer_name = layer_name;

  static const Op& op = Op::Get("qnn.csi.custom_op");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.custom_op")
    .describe(R"code(custom op for csi.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSICustomAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The tensor to custom.")
    .set_support_level(11)
    .add_type_rel("QnnCSICustomOpRel", QnnCSICustomOpRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSICustomOp").set_body_typed(MakeQnnCSICustomOp);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
