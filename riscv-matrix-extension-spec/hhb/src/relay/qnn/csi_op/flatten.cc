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

/* relay.flatten */
TVM_REGISTER_NODE_TYPE(QnnCSIUnaryAttrs);

bool QnnCSIFlattenRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                      const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) return false;
  if (data->shape.size() == 0) return false;

  auto target_dim = tir::make_const(DataType::Int(32), 1);

  for (uint32_t i = 1; i < data->shape.size(); ++i) {
    if (!data->shape[i].as<tir::AnyNode>()) {
      target_dim = target_dim * data->shape[i];
    } else {
      target_dim = data->shape[i];
      break;
    }
  }

  std::vector<IndexExpr> oshape({data->shape[0], target_dim});

  // assign output type
  reporter->Assign(types[1], TensorType(oshape, data->dtype));
  return true;
}

Expr MakeQnnCSIFlatten(Expr data, DataType out_dtype, Array<Array<IndexExpr>> q_params,
                       String layer_name) {
  auto attrs = make_object<QnnCSIUnaryAttrs>();
  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.flatten");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.flatten")
    .describe(
        R"code(Given tensor, this operation returns a new tensor that has the same values as tensor in
          the same order, except with a new shape given by newshape.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIUnaryAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIFlattenRel", QnnCSIFlattenRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIFlatten").set_body_typed(MakeQnnCSIFlatten);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
