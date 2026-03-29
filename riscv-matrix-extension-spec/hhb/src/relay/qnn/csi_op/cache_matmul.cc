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
 * \file src/relay/qnn/op/matmul.cc
 * \brief Property def of qnn matmul operator.
 */

#include <tvm/relay/base.h>
#include <tvm/relay/op.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>

#include "../../op/nn/nn.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {

// relay.op.qnn.matmul
TVM_REGISTER_NODE_TYPE(QnnCSICacheMatMulAttrs);

bool QnnCSICacheMatMulRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                          const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 4);

  auto* input = types[0].as<TensorTypeNode>();
  const auto* param = attrs.as<QnnCSICacheMatMulAttrs>();
  CHECK(param != nullptr);

  auto shape = param->shape;
  auto axes = param->axes;

  const int ndim = shape.size();
  // construct int_axes
  std::vector<int> int_axes;
  int_axes.reserve(ndim);

  // Construct output shape
  std::vector<int> axis_used(ndim, 0);
  for (const Integer& e : axes) {
    int64_t axis = e;
    // sanity check for axis and ndim
    ICHECK(-ndim <= axis && axis < ndim)
        << "transpose only allows each `axis` in `axes` in range [-data.ndim, data.ndim)"
        << ", but got axis = " << axis << ", and data.ndim = " << ndim;
    axis = axis < 0 ? axis + ndim : axis;
    // sanity check for duplication
    ICHECK(!axis_used[axis]) << "Duplicate axes in transpose: " << axis;
    axis_used[axis] = 1;
    int_axes.push_back(static_cast<int>(axis));
  }

  std::vector<IndexExpr> oshape;
  oshape.reserve(ndim);
  for (int axis : int_axes) {
    oshape.push_back(shape[axis]);
  }

  // Assign output shape
  reporter->Assign(types[3], TensorType(oshape, input->dtype));
  return true;
}

Expr MakeQnnCSICacheMatMul(Expr data, Expr weight, Expr bias, Array<Integer> cache_shape,
                           Array<Integer> shape, Array<Integer> axes, DataType out_dtype,
                           Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSICacheMatMulAttrs>();
  attrs->cache_shape = std::move(cache_shape);
  attrs->shape = std::move(shape);
  attrs->axes = std::move(axes);

  attrs->out_dtype = std::move(out_dtype);
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);
  static const Op& op = Op::Get("qnn.csi.cache_matmul");
  return Call(op, {data, weight, bias}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.cache_matmul")
    .describe(R"code(
    custom fusion ops.
     (cache)
     Gather   Other
        \      /
         Concat
           |
         MatMUl               --> CacheMatMul
           |
          Add
           |
        Reshape
           |
        Transpose
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSICacheMatMulAttrs>()
    .set_num_inputs(3)
    .add_argument("data", "Tensor", "The input data tensor.")
    .add_argument("weight", "Tensor", "The weight tensor.")
    .add_argument("bias", "Tensor", "The bias tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSICacheMatMulRel", QnnCSICacheMatMulRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSICacheMatMul").set_body_typed(MakeQnnCSICacheMatMul);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
