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
// Take
TVM_REGISTER_NODE_TYPE(QnnCSITakeAttrs);
bool QnnCSITakeRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                   const TypeReporter& reporter) {
  // `types` contains: [data, indices, result]
  CHECK_EQ(types.size(), 3);
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) {
    return false;
  }
  const auto* indices = types[1].as<TensorTypeNode>();
  if (indices == nullptr) {
    return false;
  }
  CHECK(indices->dtype.is_int()) << "indices of take must be tensor of integer";
  const auto param = attrs.as<QnnCSITakeAttrs>();
  CHECK(param != nullptr);

  if (!param->axis.defined()) {
    std::vector<IndexExpr> oshape(indices->shape.begin(), indices->shape.end());
    reporter->Assign(types[2], TensorType(oshape, data->dtype));
    return true;
  }

  std::vector<IndexExpr> oshape;
  const auto ndim_data = static_cast<int>(data->shape.size());
  const auto ndim_indices = static_cast<int>(indices->shape.size());
  int axis = static_cast<int>(param->axis->value);
  if (axis < 0) axis += ndim_data;
  CHECK_LE(axis, ndim_data) << "axis should be with in data shape"
                            << ", but got = " << axis;

  oshape.reserve(ndim_data - 1 + ndim_indices);
  for (int i = 0; i < axis; ++i) {
    oshape.emplace_back(data->shape[i]);
  }
  for (int i = 0; i < ndim_indices; ++i) {
    oshape.emplace_back(indices->shape[i]);
  }
  for (int i = axis + 1; i < ndim_data; ++i) {
    oshape.emplace_back(data->shape[i]);
  }

  reporter->Assign(types[2], TensorType(oshape, data->dtype));
  return true;
}

// QNN Take operator.
Expr MakeQnnCSITake(Expr data, Expr indices, Integer axis, String mode, DataType out_dtype,
                    Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSITakeAttrs>();

  attrs->axis = std::move(axis);
  attrs->mode = std::move(mode);
  attrs->out_dtype = std::move(out_dtype);
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.take");
  return Call(op, {data, indices}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.take")
    .describe(R"code(Take elements from an array along an axis.

When axis is not None, this function does the same thing as 'fancy' indexing
(indexing arrays using arrays); however, it can be easier to use if you need
elements along a given axis.

**Note** that when axis is none the flattened input array is used.

Examples::

  a = [[ 1, 2],
       [ 3, 4]]
  indices = [3, 0, 2]
  take(a, indices) = [ 4, 1, 3]

  a = [[ 1., 2.],
       [ 3., 4.]]
  indices = [1, 0]
  take(a, indices, axis=1) = [[ 2., 1.],
                              [ 4., 3.]]

)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSITakeAttrs>()
    .set_num_inputs(2)
    .add_argument("data", "Tensor", "The input tensor.")
    .add_argument("indices", "Tensor", "The indices tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSITakeRel", QnnCSITakeRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSITake").set_body_typed(MakeQnnCSITake);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
