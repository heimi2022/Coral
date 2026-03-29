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

bool QnnCSIUnRavelIndexRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                           const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 3);

  const auto* indices = types[0].as<TensorTypeNode>();
  if (indices == nullptr) {
    CHECK(types[0].as<IncompleteTypeNode>())
        << "unravel_index: expect input type to be TensorType but get " << types[0];
    return false;
  }
  CHECK(indices->dtype.is_int()) << "indices of unravel_index must be tensor of integer";

  const auto* shape = types[1].as<TensorTypeNode>();
  if (shape == nullptr) {
    CHECK(types[1].as<IncompleteTypeNode>())
        << "unravel_index: expect input type to be TensorType but get " << types[1];
    return false;
  }
  CHECK(indices->dtype.is_int()) << "shape of unravel_index must be tensor of integer";

  Array<IndexExpr> indices_shape;
  Array<IndexExpr> shape_shape;
  indices_shape = indices->shape;
  shape_shape = shape->shape;

  Array<IndexExpr> oshape;
  oshape.push_back(shape_shape[0]);
  if (indices_shape.size() != 0) {
    oshape.push_back(indices_shape[0]);
  }
  reporter->Assign(types[2], TensorType(oshape, indices->dtype));
  return true;
}

// QNN UnRavelIndex operator.
Expr MakeQnnCSIUnRavelIndex(Expr data, Expr shape, DataType out_dtype,

                            Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIUnaryAttrs>();
  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.unravel_index");
  return Call(op, {data, shape}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.unravel_index")
    .describe(
        R"code(Converts a flat index or array of flat indices into a tuple of coordinate arrays.

Example::
  -  unravel_index([22, 41, 37], (7, 6)) = [[3, 6, 6], [4, 5, 1]]
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIUnaryAttrs>()
    .set_num_inputs(2)
    .set_support_level(11)
    .add_type_rel("QnnCSIUnRavelIndexRel", QnnCSIUnRavelIndexRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIUnRavelIndex").set_body_typed(MakeQnnCSIUnRavelIndex);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
