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
TVM_REGISTER_NODE_TYPE(QnnCSIExpandDimsAttrs);

bool QnnCSIExpandDimsRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                         const TypeReporter& reporter) {
  // `types` contains: [data, result]
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) {
    CHECK(types[0].as<IncompleteTypeNode>())
        << "expand_dims: expect input type to be TensorType but get " << types[0];
    return false;
  }
  const auto* param = attrs.as<QnnCSIExpandDimsAttrs>();
  const int ndim = static_cast<int>(data->shape.size());
  const int axis = param->axis;
  const int num_newaxis = param->num_newaxis;
  CHECK(num_newaxis >= 0) << "expand_dims only accepts `num_newaxis >= 0`"
                          << ", but got num_newaxis = " << num_newaxis;
  CHECK(-ndim - 1 <= axis && axis <= ndim)
      << "expand_dims only accepts `axis` in [-data.ndim - 1, data.ndim]"
      << ", but got axis = " << axis << ", and data.ndim = " << ndim;
  const int pivot = axis < 0 ? ndim + axis + 1 : axis;
  std::vector<IndexExpr> oshape;
  oshape.reserve(ndim + num_newaxis);
  for (int i = 0; i < pivot; ++i) {
    oshape.emplace_back(data->shape[i]);
  }
  for (int i = 0; i < num_newaxis; ++i) {
    oshape.emplace_back(1);
  }
  for (int i = pivot; i < ndim; ++i) {
    oshape.emplace_back(data->shape[i]);
  }
  reporter->Assign(types[1], TensorType(oshape, data->dtype));
  return true;
}

// QNN Multiplication operator.
Expr MakeQnnCSIExpandDims(Expr data, int32_t axis, int32_t num_newaxis, DataType out_dtype,
                          Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIExpandDimsAttrs>();
  attrs->out_dtype = out_dtype;
  attrs->axis = axis;
  attrs->num_newaxis = num_newaxis;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.expand_dims");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.expand_dims")
    .describe(R"code(Insert `num_newaxis` axises at the position given by `axis`

- **data**: The input data to the operator.

)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIExpandDimsAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIExpandDimsRel", QnnCSIExpandDimsRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIExpandDims").set_body_typed(MakeQnnCSIExpandDims);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
