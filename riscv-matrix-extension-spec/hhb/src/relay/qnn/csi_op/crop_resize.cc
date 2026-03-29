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
 * \file src/relay/qnn/op/convolution.cc
 * \brief Property def of qnn convolution operator.
 */
#include <tvm/relay/analysis.h>
#include <tvm/relay/base.h>
#include <tvm/relay/op.h>
#include <tvm/relay/qnn/attrs.h>
#include <tvm/relay/transform.h>
#include <tvm/tir/data_layout.h>

#include "../../op/nn/convolution.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {

// relay.op.qnn.conv2d
TVM_REGISTER_NODE_TYPE(QnnCSICropResizeAttrs);

bool QnnCSICropResizeRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                         const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 4);
  const auto* data = types[0].as<TensorTypeNode>();
  const auto* boxes = types[1].as<TensorTypeNode>();
  const auto* box_indices = types[2].as<TensorTypeNode>();
  if (data == nullptr || boxes == nullptr || box_indices == nullptr) return false;

  const QnnCSICropResizeAttrs* param = attrs.as<QnnCSICropResizeAttrs>();
  CHECK(param != nullptr);
  auto crop_size = param->crop_size;

  DataType out_dtype = param->out_dtype;
  if (out_dtype.bits() == 0) {
    out_dtype = data->dtype;
  }

  // 4-D tensor of shape [num_boxes, crop_height, crop_width, depth]
  static const Layout kNCHW("NCHW");
  const Layout in_layout(param->layout);
  auto layout_converter = tir::BijectiveLayout(in_layout, kNCHW);
  auto oshape = layout_converter.ForwardShape(data->shape);
  oshape.Set(0, boxes->shape[0]);
  oshape.Set(2, crop_size[0]);
  oshape.Set(3, crop_size[1]);
  auto bshape = layout_converter.BackwardShape(oshape);
  // assign output type
  reporter->Assign(types[3], TensorType(bshape, out_dtype));
  return true;
}

Expr MakeQnnCSICropResize(Expr data, Expr boxes, Expr box_indices, Array<IndexExpr> crop_size,
                          String layout, String method, double extrapolation_value,
                          DataType out_dtype,

                          Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSICropResizeAttrs>();
  attrs->crop_size = std::move(crop_size);
  attrs->layout = std::move(layout);
  attrs->method = std::move(method);
  attrs->extrapolation_value = std::move(extrapolation_value);
  attrs->out_dtype = std::move(out_dtype);

  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.crop_resize");
  return Call(op, {data, boxes, box_indices}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.crop_resize")
    .describe(R"code(3D quantized deconvolution layer.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSICropResizeAttrs>()
    .set_num_inputs(3)
    .add_argument("data", "Tensor", "The quantized input data tensor.")
    .add_argument("weight", "Tensor", "The quantized weight tensor.")
    .add_argument("bias", "Tensor", "The quantized bias tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSICropResizeRel", QnnCSICropResizeRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSICropResize").set_body_typed(MakeQnnCSICropResize);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
