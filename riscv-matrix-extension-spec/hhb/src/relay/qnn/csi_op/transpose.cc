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
TVM_REGISTER_NODE_TYPE(QnnCSITransposeAttrs);

bool QnnCSITransposeRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                        const TypeReporter& reporter) {
  // types: [data, result]
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) {
    CHECK(types[0].as<IncompleteTypeNode>())
        << "transpose: expect input type to be TensorType but get " << types[0];
    return false;
  }
  const auto* param = attrs.as<QnnCSITransposeAttrs>();
  const int ndim = data->shape.size();
  const Array<Integer>& axes = param->axes;
  // check dimension match
  CHECK(!axes.defined() || static_cast<int>(axes.size()) == ndim)
      << "Dimension mismatch: axes has " << axes.size() << " elements"
      << ", but data.ndim = " << ndim;
  // construct int_axes
  std::vector<int> int_axes;
  int_axes.reserve(ndim);
  // used not defined to check if it is None.
  if (!axes.defined()) {
    for (int i = ndim - 1; i >= 0; --i) {
      int_axes.push_back(i);
    }
  } else {
    std::vector<int> axis_used(ndim, 0);
    for (const Integer& e : axes) {
      int64_t axis = e;
      // sanity check for axis and ndim
      CHECK(-ndim <= axis && axis < ndim)
          << "transpose only allows each `axis` in `axes` in range [-data.ndim, data.ndim)"
          << ", but got axis = " << axis << ", and data.ndim = " << ndim;
      axis = axis < 0 ? axis + ndim : axis;
      // sanity check for duplication
      CHECK(!axis_used[axis]) << "Duplicate axes in transpose: " << axis;
      axis_used[axis] = 1;
      int_axes.push_back(static_cast<int>(axis));
    }
  }
  std::vector<IndexExpr> oshape;
  oshape.reserve(ndim);
  for (int axis : int_axes) {
    oshape.push_back(data->shape[axis]);
  }
  reporter->Assign(types[1], TensorType(oshape, data->dtype));
  return true;
}

// QNN Multiplication operator.
Expr MakeQnnCSITranspose(Expr data, Array<Integer> axes, DataType out_dtype,
                         Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSITransposeAttrs>();
  attrs->axes = axes;
  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.transpose");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.transpose")
    .describe(
        R"code(Given tensor, this operation returns a new tensor that has the same values as tensor in
          the same order, except with a new shape given by newshape.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSITransposeAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSITransposeRel", QnnCSITransposeRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSITranspose").set_body_typed(MakeQnnCSITranspose);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
