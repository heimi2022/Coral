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
 * \file src/relay/qnn/op/fsmn.cc
 * \brief QNN fsmn operator.
 */
#include <tvm/relay/analysis.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>

#include "../op/op_common.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {
TVM_REGISTER_NODE_TYPE(QnnCSIFsmnAttrs);

bool QnnCSIFsmnRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                   const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 6);
  const auto* data = types[0].as<TensorTypeNode>();
  // const auto* l_filter = types[1].as<TensorTypeNode>();
  // const auto* r_filter = types[2].as<TensorTypeNode>();
  // const auto* frame_sequence = types[3].as<TensorTypeNode>();
  if (data == nullptr) return false;

  const QnnCSIFsmnAttrs* param = attrs.as<QnnCSIFsmnAttrs>();
  CHECK(param != nullptr);
  // const int l_order = param->l_order;
  // const int r_order = param->r_order;
  // const int l_stride = param->l_stride;
  // const int r_stride = param->r_stride;

  auto oshape = data->shape;
  // auto l_filter_shape = l_filter->shape;
  // auto r_filter_shape = r_filter->shape;
  // auto frame_sequence_shape = frame_sequence->shape;
  // tvm::tir::ExprDeepEqual expr_equal;
  // expr_equal(l_filter_shape[0], l_order);
  // expr_equal(l_filter_shape[1], oshape[1]);
  // expr_equal(r_filter_shape[0], r_order);
  // expr_equal(r_filter_shape[1], oshape[1]);
  // expr_equal(frame_sequence_shape[0],
  //                           r_order * r_stride + (l_order - 1) * l_stride + 1);
  // expr_equal(frame_sequence_shape[1], oshape[1]);

  reporter->Assign(types[5], TensorType(oshape, data->dtype));

  return true;
}

// QNN Relu operator.
Expr MakeQnnCSIFsmn(Expr frame, Expr l_filter, Expr r_filter, Expr frame_sequence,
                    Expr frame_counter, int l_order, int r_order, int l_stride, int r_stride,
                    int unavailable_frames, Array<Array<IndexExpr>> q_params, DataType out_dtype,
                    String layer_name) {
  auto attrs = make_object<QnnCSIFsmnAttrs>();
  attrs->l_order = std::move(l_order);
  attrs->r_order = std::move(r_order);
  attrs->l_stride = std::move(l_stride);
  attrs->r_stride = std::move(r_stride);
  attrs->unavailable_frames = std::move(unavailable_frames);
  attrs->q_params = std::move(q_params);
  attrs->out_dtype = std::move(out_dtype);
  attrs->layer_name = std::move(layer_name);
  static const Op& op = Op::Get("qnn.csi.fsmn");
  return Call(op, {frame, l_filter, r_filter, frame_sequence, frame_counter}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.fsmn")
    .describe(R"code(Feedforwward sequential memory network.

- **frame**: data is a 2D array of shape
            (1, length)

- **l_filter**: l_filter is a 2D array of shape
            (l_order, length)

- **r_filter**: r_filter is a 2D array of shape
            (l_order, length)

- **frame_sequence**:
            (l_order + r_order, length)

- **out**: Output is a 2D array of shape
            (1, length).

)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIFsmnAttrs>()
    .set_num_inputs(5)
    .add_argument("data", "Tensor", "The input tensor")
    .add_argument("l_filter", "Tensor", "The parameter tensor")
    .add_argument("r_filter", "Tensor", "The parameter tensor")
    .add_argument("frame_counter", "Tensor", "count passed frames")
    .add_argument("frame_sequence", "Tensor", "Temporary space to hold past and future frames")
    .set_support_level(11)
    .add_type_rel("QnnCSIFsmnRel", QnnCSIFsmnRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIFsmn").set_body_typed(MakeQnnCSIFsmn);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
