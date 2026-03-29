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
TVM_REGISTER_NODE_TYPE(QnnCSIUnaryAttrs);

bool QnnCSIScatterNDRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                        const TypeReporter& reporter) {
  CHECK_EQ(num_inputs, 3);
  CHECK_EQ(types.size(), 4);
  auto data = types[0].as<TensorTypeNode>();
  if (data == nullptr) {
    return false;
  }
  auto indices = types[1].as<TensorTypeNode>();
  if (indices == nullptr) {
    return false;
  }
  auto updates = types[2].as<TensorTypeNode>();
  if (updates == nullptr) {
    return false;
  }
  CHECK(indices->dtype.is_int()) << "indices of take must be tensor of integer";
  const auto param = attrs.as<QnnCSIUnaryAttrs>();
  CHECK(param != nullptr);
  reporter->Assign(types[3], TensorType(data->shape, data->dtype));
  return true;
}

// QNN scatter_nd operator.
Expr MakeQnnCSIScatterND(Expr data, Expr indices, Expr updates, DataType out_dtype,
                         Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIUnaryAttrs>();
  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.scatter_nd");
  return Call(op, {data, indices, updates}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.scatter_nd")
    .describe(
        R"doc(Update data by adding values in updates at positions defined by indices)doc" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIUnaryAttrs>()
    .set_num_inputs(3)
    .add_argument("data", "Tensor", "The input data tensor.")
    .add_argument("indicies", "Tensor", "The indicies location tensor.")
    .add_argument("updates", "Tensor", "The values to update the input with.")
    .set_support_level(11)
    .add_type_rel("QnnCSIScatterNDRel", QnnCSIScatterNDRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIScatterND").set_body_typed(MakeQnnCSIScatterND);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
