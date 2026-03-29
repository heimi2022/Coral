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
TVM_REGISTER_NODE_TYPE(QnnCSITopKAttrs);

bool QnnCSITopKRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                   const TypeReporter& reporter) {
  // `types` contains: [data, result]
  const QnnCSITopKAttrs* param = attrs.as<QnnCSITopKAttrs>();
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();
  CHECK(data);
  int ndim = data->shape.size();
  int axis = param->axis;
  if (axis < 0) {
    axis += ndim;
  }
  CHECK(axis >= 0 && axis < ndim);
  Array<IndexExpr> out_shape;
  for (int i = 0; i < ndim; ++i) {
    if (i != axis) {
      out_shape.push_back(data->shape[i]);
    } else {
      const Integer& ck = Integer(param->k);
      if (ck->value < 1) {
        out_shape.push_back(data->shape[i]);
      } else {
        out_shape.push_back(ck);
      }
    }
  }
  auto values_ty = TensorType(out_shape, data->dtype);
  auto indices_ty = TensorType(out_shape, param->dtype);
  if (param->ret_type == "both") {
    reporter->Assign(types[1], TupleType({values_ty, indices_ty}));
  } else if (param->ret_type == "values") {
    reporter->Assign(types[1], values_ty);
  } else if (param->ret_type == "indices") {
    reporter->Assign(types[1], indices_ty);
  } else {
    LOG(FATAL) << "Unsupported ret type: " << param->ret_type;
  }
  return true;
}
// QNN Multiplication operator.
Expr MakeQnnCSITopK(Expr data, int32_t k, int axis, String ret_type, bool is_ascend, DataType dtype,
                    DataType out_dtype, Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSITopKAttrs>();
  attrs->k = k;
  attrs->axis = axis;
  attrs->ret_type = ret_type;
  attrs->is_ascend = is_ascend;
  attrs->dtype = dtype;
  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.topk");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.topk")
    .describe(R"code(Returns the topk input array, computed element-wise.

.. math::
   topk(x)

)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSITopKAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSITopKRel", QnnCSITopKRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSITopK").set_body_typed(MakeQnnCSITopK);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
