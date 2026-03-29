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
 * \file src/relay/qnn/op/where.cc
 * \brief QNN where operator.
 */
#include <tvm/relay/analysis.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>

#include "../op/op_common.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {

TVM_REGISTER_NODE_TYPE(QnnCSIOneHotAttrs);

bool QnnCSIOneHotRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                     const TypeReporter& reporter) {
  ICHECK_EQ(types.size(), 2);
  const auto* indices = types[0].as<TensorTypeNode>();
  ICHECK(indices);

  const auto param = attrs.as<QnnCSIOneHotAttrs>();
  ICHECK_GT(param->depth, 0);

  Array<IndexExpr> oshape;
  int ndim = indices->shape.size() + 1;
  int indices_index = 0;
  int true_axis = (param->axis == -1) ? indices->shape.size() : param->axis;
  for (int i = 0; i < ndim; i++) {
    if (i == true_axis) {
      oshape.push_back(Integer(param->depth));
    } else {
      oshape.push_back(indices->shape[indices_index++]);
    }
  }

  reporter->Assign(types[1], TensorType(oshape, param->out_dtype));
  return true;
}

Expr MakeQnnCSIOneHot(Expr indices, int depth, int axis, DataType out_dtype,
                      Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIOneHotAttrs>();
  attrs->depth = std::move(depth);
  attrs->axis = axis;
  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.one_hot");
  return Call(op, {indices}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.one_hot")
    .describe(R"code(Returns a one-hot tensor where the locations repsented by indices take value 1,
    other locations take value 0. Final dimension is <indices dimensions> x depth.

    **indices** Locations to set to 1.

    **on_value** Value to fill at indices.

    **off_value** Value to fill at all other positions besides indices.

    **depth** Depth of the one-hot dimension.

    **axis** Axis to fill.

    **dtype**)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIOneHotAttrs>()
    .set_num_inputs(1)
    .add_argument("indices", "Tensor", "Locations to set to on_value.")
    .set_support_level(11)
    .add_type_rel("QnnCSIOneHotRel", QnnCSIOneHotRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIOneHot").set_body_typed(MakeQnnCSIOneHot);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
