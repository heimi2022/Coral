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
 * \file src/relay/qnn/op/space_to_batch_nd.cc
 * \brief QNN SpaceToBatchNd operator.
 */
#include <tvm/relay/analysis.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>

#include "../op/op_common.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {
TVM_REGISTER_NODE_TYPE(QnnCSISpaceToBatchNDAttrs);

bool QnnCSISpaceToBatchNDRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                             const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 2);

  auto* input = types[0].as<TensorTypeNode>();
  // Input must be a TensorType
  if (input == nullptr) {
    CHECK(types[0].as<IncompleteTypeNode>())
        << "SpaceToBatchND: expect input type to be TensorType but got " << types[0];
    return false;
  }

  if (input->shape.size() <= 1) return false;

  const auto* param = attrs.as<QnnCSISpaceToBatchNDAttrs>();
  CHECK(param != nullptr);

  auto block_shape = param->block_shape;
  auto paddings = param->paddings;
  const int bdims = static_cast<int>(block_shape.size());
  const int pdims = static_cast<int>(paddings.size());
  // Paddings must be provided for each spatial dim.
  CHECK(pdims == bdims) << "SpaceToBatchND: Paddings must be provided for each spatial dim";

  // Apply paddings to input
  auto in_shape = input->shape;
  std::vector<IndexExpr> padded_shape(input->shape.begin(), input->shape.end());
  for (size_t i = 0; i < paddings.size(); i++) {
    CHECK_EQ(paddings[i].size(), 2U);
    auto pad_before = tir::as_const_int(param->paddings[i][0]);
    auto pad_after = tir::as_const_int(param->paddings[i][1]);
    auto padding = tir::make_const(input->shape[i].dtype(), *pad_before + *pad_after);
    padded_shape[i + 1] = in_shape[i + 1] + padding;
  }

  auto block_shape_numele = tir::make_const(DataType::Int(32), 1);
  for (size_t i = 0; i < block_shape.size(); i++) {
    block_shape_numele *= block_shape[i];
  }

  // Construct output shape
  std::vector<IndexExpr> out_shape(padded_shape);
  out_shape[0] = in_shape[0] * block_shape_numele;
  for (size_t i = 1; i <= block_shape.size(); i++) {
    out_shape[i] = div(padded_shape[i], block_shape[i - 1]);
  }

  // Assign output shape
  reporter->Assign(types[1], TensorType(Array<IndexExpr>(out_shape), input->dtype));
  return true;
}

// QNN SpaceToBatchND operator.
Expr MakeQnnCSISpaceToBatchND(Expr data, Array<Integer> block_shape,
                              Array<Array<IndexExpr>> paddings, double pad_value,
                              DataType out_dtype, Array<Array<IndexExpr>> q_params,
                              String layer_name) {
  auto attrs = make_object<QnnCSISpaceToBatchNDAttrs>();
  attrs->block_shape = std::move(block_shape);
  attrs->paddings = std::move(paddings);
  attrs->pad_value = pad_value;

  attrs->out_dtype = out_dtype;
  attrs->layer_name = layer_name;
  attrs->q_params = std::move(q_params);
  static const Op& op = Op::Get("qnn.csi.space_to_batch_nd");
  return Call(op, {data}, Attrs(attrs), {});
}

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSISpaceToBatchND")
    .set_body_typed(MakeQnnCSISpaceToBatchND);

RELAY_REGISTER_OP("qnn.csi.space_to_batch_nd")
    .describe(R"code(Divide spatial dimensions of the input into a grid of blocks
and interleave them into batch dim.

- **data**: data is a ND array of shape
            (batch, spatial_shapes, remaining_shapes) for NHWC

- **out**: Output is a ND array of shape
           (batch * prod(block_shape), padded_data[1] / block_shape[0], ..., padded_data[M] / block_shape[M-1],
            remaining_shape) for NHWC, where M is the number of spatial dimensions.

Example::

  x = [[[[1], [2]], [[3], [4]]]]

  space_to_batch_nd(x, block_shape = [2, 2]) =
    [[[[1]]], [[[2]]], [[[3]]], [[[4]]]]

)code" TVM_ADD_FILELINE)
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The input tensor.")
    .set_attrs_type<QnnCSISpaceToBatchNDAttrs>()
    .set_support_level(5)
    .add_type_rel("QnnCSISpaceToBatchNDRel", QnnCSISpaceToBatchNDRel)
    .set_attr<TOpPattern>("TOpPattern", kInjective);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
