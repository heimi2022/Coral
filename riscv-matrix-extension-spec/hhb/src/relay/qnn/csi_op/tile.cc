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
TVM_REGISTER_NODE_TYPE(QnnCSITileAttrs);

// tile operator
bool QnnCSITileRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                   const TypeReporter& reporter) {
  // `types` contains: [data, result]
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) {
    CHECK(types[0].as<IncompleteTypeNode>())
        << "tile: expect input type to be TensorType but get " << types[0];
    return false;
  }
  const auto* param = attrs.as<QnnCSITileAttrs>();
  const size_t ndim = data->shape.size();
  const Array<Integer>& reps = param->reps;
  // check dimension match
  CHECK(reps.defined()) << "repetition array is not defined. data.ndim = " << ndim;
  const size_t rndim = reps.size();
  for (size_t i = 0; i < rndim; ++i) {
    if (const tvm::tir::IntImmNode* val = reps[i].as<tvm::tir::IntImmNode>()) {
      CHECK_GT(val->value, 0) << "Tile reps value should always be larger than 0, but get: "
                              << val->value;
    }
  }
  size_t tndim = (ndim > rndim) ? ndim : rndim;
  // re-construct data shape or reps shape
  std::vector<IndexExpr> data_shape;
  std::vector<IndexExpr> reps_shape;
  data_shape.reserve(tndim);
  reps_shape.reserve(tndim);
  if (ndim == rndim) {
    for (size_t i = 0; i < tndim; ++i) {
      data_shape.emplace_back(data->shape[i]);
      reps_shape.emplace_back(reps[i]);
    }
  } else if (ndim > rndim) {
    for (size_t i = 0; i < ndim; ++i) {
      data_shape.emplace_back(data->shape[i]);
    }
    for (size_t i = 0; i < (ndim - rndim); ++i) {
      reps_shape.emplace_back(1);
    }
    for (size_t i = 0; i < rndim; ++i) {
      reps_shape.emplace_back(reps[i]);
    }
  } else {
    for (size_t i = 0; i < rndim; ++i) {
      reps_shape.emplace_back(reps[i]);
    }
    for (size_t i = 0; i < (rndim - ndim); ++i) {
      data_shape.emplace_back(1);
    }
    for (size_t i = 0; i < ndim; ++i) {
      data_shape.emplace_back(data->shape[i]);
    }
  }
  std::vector<IndexExpr> oshape;
  oshape.reserve(tndim);
  for (size_t i = 0; i < tndim; ++i) {
    // Save Any if it is dynamic shape
    if (!data_shape[i].as<IntImmNode>()) {
      oshape.emplace_back(Any());
    } else {
      oshape.emplace_back(data_shape[i] * reps_shape[i]);
    }
  }
  reporter->Assign(types[1], TensorType(oshape, data->dtype));
  return true;
}

// QNN Tile operator.
Expr MakeQnnCSITile(Expr data, Array<Integer> reps, DataType out_dtype,
                    Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSITileAttrs>();
  attrs->reps = std::move(reps);
  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.tile");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.tile")
    .describe(R"code(Repeat the whole array multiple times.

- **data**: The input data to the operator.
- **reps**: The number of times to repeat the operator.

)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSITileAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The input tensor.")
    .add_argument("reps", "Tensor", "The number of times to repeat the input on each axis.")
    .set_support_level(11)
    .add_type_rel("QnnCSITileRel", QnnCSITileRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSITile").set_body_typed(MakeQnnCSITile);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
