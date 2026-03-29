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

// relay.op.qnn.dilation2d
TVM_REGISTER_NODE_TYPE(QnnCSIDilation2DAttrs);

bool QnnCSIDilation2DRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                         const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 3);
  const auto* data = types[0].as<TensorTypeNode>();
  const auto* weight = types[1].as<TensorTypeNode>();
  if (data == nullptr) return false;
  static const Layout kNCHW("NCHW");
  static const Layout kOIHW("IHW");

  const QnnCSIDilation2DAttrs* param = attrs.as<QnnCSIDilation2DAttrs>();
  CHECK(param != nullptr);
  const Layout in_layout(param->data_layout);
  const Layout kernel_layout(param->kernel_layout);

  const auto trans_in_layout = tir::BijectiveLayout(in_layout, kNCHW);
  CHECK(trans_in_layout.defined())
      << "Dilation2D only support input layouts that are convertible from NCHW."
      << " But got " << in_layout;

  const auto trans_kernel_layout = tir::BijectiveLayout(kernel_layout, kOIHW);
  CHECK(trans_kernel_layout.defined())
      << "Dilation2D only support kernel layouts that are convertible from OIHW."
      << " But got " << kernel_layout;

  Layout out_layout(param->data_layout);
  const auto trans_out_layout = tir::BijectiveLayout(out_layout, kNCHW);
  CHECK(trans_out_layout.defined())
      << "Dilation2D only support output layouts that are convertible from NCHW."
      << " But got " << out_layout;

  Array<IndexExpr> dshape_nchw = trans_in_layout.ForwardShape(data->shape);

  IndexExpr channels, dilated_ksize_y, dilated_ksize_x;

  // use weight to infer the conv shape.
  if (weight == nullptr) return false;
  auto wshape = trans_kernel_layout.ForwardShape(weight->shape);
  channels = wshape[0];

  dilated_ksize_y = 1 + (wshape[1] - 1) * param->dilations[0];
  dilated_ksize_x = 1 + (wshape[2] - 1) * param->dilations[1];

  // dilation
  Array<IndexExpr> oshape({dshape_nchw[0], channels, 0, 0});
  IndexExpr pad_h, pad_w;
  GetPaddingHeightWidth(param->padding, &pad_h, &pad_w);
  if (!dshape_nchw[2].as<tir::AnyNode>()) {
    oshape.Set(2, indexdiv(dshape_nchw[2] + pad_h - dilated_ksize_y, param->strides[0]) + 1);
  } else {
    oshape.Set(2, dshape_nchw[2]);
  }

  if (!dshape_nchw[3].as<tir::AnyNode>()) {
    oshape.Set(3, indexdiv(dshape_nchw[3] + pad_w - dilated_ksize_x, param->strides[1]) + 1);
  } else {
    oshape.Set(3, dshape_nchw[3]);
  }

  DataType out_dtype = param->out_dtype;
  if (out_dtype.bits() == 0) {
    out_dtype = data->dtype;
  }
  oshape = trans_out_layout.BackwardShape(oshape);
  // assign output type
  reporter->Assign(types[2], TensorType(oshape, out_dtype));
  return true;
}

Expr MakeQnnCSIDilation2D(Expr data, Expr weight, Array<IndexExpr> strides,
                          Array<IndexExpr> padding, Array<IndexExpr> dilations,
                          std::string data_layout, std::string kernel_layout, DataType out_dtype,

                          Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIDilation2DAttrs>();
  attrs->strides = std::move(strides);
  attrs->padding = std::move(padding);
  attrs->dilations = std::move(dilations);
  attrs->data_layout = std::move(data_layout);
  attrs->kernel_layout = std::move(kernel_layout);
  attrs->out_dtype = std::move(out_dtype);
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.dilation2d");
  return Call(op, {data, weight}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.dilation2d")
    .describe(R"code(Computes grayscale dilation of 4D input and 3D filter.
- **data**: This depends on the `layout` parameter. Input is 4D array of shape
            (batch_size, in_channels, height, width) if `layout` is `NCHW`.
- **weight**: (in_channels, height, width)
- **out**:  This depends on the `layout` parameter. Output is 4D array of shape
            (batch_size, channels, out_height, out_width) if `layout` is `NCHW`.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIDilation2DAttrs>()
    .set_num_inputs(2)
    .add_argument("data", "Tensor", "The quantized input data tensor.")
    .add_argument("weight", "Tensor", "The quantized weight tensor.")
    .add_argument("bias", "Tensor", "The quantized bias tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIDilation2DRel", QnnCSIDilation2DRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIDilation2D").set_body_typed(MakeQnnCSIDilation2D);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
