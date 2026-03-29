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
#include "../../op/nn/convolution.h"

#include <tvm/relay/analysis.h>
#include <tvm/relay/base.h>
#include <tvm/relay/op.h>
#include <tvm/relay/qnn/attrs.h>
#include <tvm/relay/transform.h>
#include <tvm/tir/data_layout.h>

#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {

// relay.op.qnn.conv2d
TVM_REGISTER_NODE_TYPE(QnnCSIConv2DAttrs);

bool QnnCSIConv2DRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                     const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 4);
  const auto* data = types[0].as<TensorTypeNode>();
  const auto* weight = types[1].as<TensorTypeNode>();
  const auto* bias = types[2].as<TensorTypeNode>();
  if (data == nullptr || weight == nullptr || bias == nullptr) return false;
  const auto* param = attrs.as<QnnCSIConv2DAttrs>();
  CHECK(param != nullptr) << "QnnCSIConv2DAttrs cannot be nullptr.";

  if (data == nullptr) return false;
  static const Layout kNCHW("NCHW");
  static const Layout kOIHW("OIHW");

  const Layout in_layout(param->data_layout);
  const Layout kernel_layout(param->kernel_layout);

  const auto trans_in_layout = tir::BijectiveLayout(in_layout, kNCHW);
  CHECK(trans_in_layout.defined())
      << "Conv only support input layouts that are convertible from NCHW."
      << " But got " << in_layout;

  const auto trans_kernel_layout = tir::BijectiveLayout(kernel_layout, kOIHW);
  CHECK(trans_kernel_layout.defined())
      << "Conv only support kernel layouts that are convertible from OIHW."
      << " But got " << kernel_layout;

  Layout out_layout(param->out_layout == "" ? param->data_layout : param->out_layout);
  const auto trans_out_layout = tir::BijectiveLayout(out_layout, kNCHW);
  CHECK(trans_out_layout.defined())
      << "Conv only support output layouts that are convertible from NCHW."
      << " But got " << out_layout;

  Array<IndexExpr> dshape_nchw = trans_in_layout.ForwardShape(data->shape);
  bool is_depthwise = false;
  if (param->groups > 1) {
    CHECK(weight && weight->shape.defined())
        << "Weight shape must be specified when groups is greater than 1.";
    Array<IndexExpr> wshape_oihw = trans_kernel_layout.ForwardShape(weight->shape);
    if (param->data_layout == "NCHW") {
      if (tvm::tir::ExprDeepEqual()(param->groups, dshape_nchw[1]) &&
          tvm::tir::ExprDeepEqual()(param->groups, wshape_oihw[0])) {
        is_depthwise = true;
      }
    } else if (param->data_layout == "NHWC") {
      if (tvm::tir::ExprDeepEqual()(param->groups, dshape_nchw[1]) &&
          tvm::tir::ExprDeepEqual()(param->groups, wshape_oihw[1])) {
        is_depthwise = true;
      }
    }
  }

  IndexExpr channels, dilated_ksize_y, dilated_ksize_x;
  // infer weight if the kernel_size and channels are defined
  if (param->kernel_size.defined() && param->channels.defined()) {
    CHECK_EQ(param->kernel_size.size(), 2);
    CHECK_EQ(param->dilation.size(), 2);
    Array<IndexExpr> wshape;

    if (is_depthwise) {
      // infer weight's shape for depthwise convolution
      if (param->data_layout == "NCHW") {
        // infer weight's shape for depthwise convolution
        wshape = {{dshape_nchw[1], indexdiv(param->channels, dshape_nchw[1]), param->kernel_size[0],
                   param->kernel_size[1]}};
      } else if (param->data_layout == "NHWC") {
        wshape = {{
            indexdiv(param->channels, dshape_nchw[1]),
            dshape_nchw[1],
            param->kernel_size[0],
            param->kernel_size[1],
        }};
      }
    } else {
      wshape = {{param->channels, indexdiv(dshape_nchw[1], param->groups), param->kernel_size[0],
                 param->kernel_size[1]}};
    }

    wshape = trans_kernel_layout.BackwardShape(wshape);
    channels = param->channels;
    dilated_ksize_y = 1 + (param->kernel_size[0] - 1) * param->dilation[0];
    dilated_ksize_x = 1 + (param->kernel_size[1] - 1) * param->dilation[1];
    DataType weight_dtype = data->dtype;
    if (weight != nullptr) {
      weight_dtype = weight->dtype;
    }
    // assign result to reporter
    reporter->Assign(types[1], TensorType(wshape, weight_dtype));
  } else {
    // use weight to infer the conv shape.
    if (weight == nullptr) return false;
    auto wshape = trans_kernel_layout.ForwardShape(weight->shape);
    if (param->kernel_size.defined()) {
      CHECK_EQ(param->kernel_size.size(), 2);
      // check the size
      CHECK(reporter->AssertEQ(param->kernel_size[0], wshape[2]) &&
            reporter->AssertEQ(param->kernel_size[1], wshape[3]))
          << "Conv2D: shape of weight is inconsistent with kernel_size, "
          << " kernel_size=" << param->kernel_size << " wshape=" << wshape;
    }
    if (param->channels.defined()) {
      CHECK(reporter->AssertEQ(param->channels, wshape[0]))
          << "Conv2D: shape of weight is inconsistent with channels, "
          << " channels=" << param->channels << " wshape=" << wshape;
    }
    CHECK(reporter->AssertEQ(indexdiv(dshape_nchw[1], param->groups), wshape[1]));
    channels = wshape[0];
    dilated_ksize_y = 1 + (wshape[2] - 1) * param->dilation[0];
    dilated_ksize_x = 1 + (wshape[3] - 1) * param->dilation[1];
  }
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
  reporter->Assign(types[3], TensorType(oshape, out_dtype));
  return true;
}

Expr MakeQnnCSIConv2D(Expr data, Expr weight, Expr bias, Array<IndexExpr> strides,
                      Array<IndexExpr> padding, Array<IndexExpr> dilation, int groups,
                      IndexExpr channels, Array<IndexExpr> kernel_size, std::string data_layout,
                      std::string kernel_layout, std::string out_layout, DataType out_dtype,
                      Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIConv2DAttrs>();
  attrs->strides = std::move(strides);
  attrs->padding = std::move(padding);
  attrs->dilation = std::move(dilation);
  attrs->groups = groups;
  attrs->channels = std::move(channels);
  attrs->kernel_size = std::move(kernel_size);
  attrs->data_layout = std::move(data_layout);
  attrs->kernel_layout = std::move(kernel_layout);
  attrs->out_layout = std::move(out_layout);
  attrs->out_dtype = std::move(out_dtype);
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.conv2d");
  return Call(op, {data, weight, bias}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.conv2d")
    .describe(R"code(2D quantized convolution layer.
This operator convolves quantized weight with quantized data. The scale of the
the input quantized tensors. The zero point of the output quantized tensor is
0. By default, the dtype of output is int32. Please also refer to Requantize
operator to understand how to scale back the int32 output to (u)int8.
- **data**: This depends on the `layout` parameter. Input is 4D array of shape
            (batch_size, in_channels, height, width) if `layout` is `NCHW`.
- **weight**: (channels, in_channels, kernel_size[0], kernel_size[1])
- **out**:  This depends on the `layout` parameter. Output is 4D array of shape
            (batch_size, channels, out_height, out_width) if `layout` is `NCHW`.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIConv2DAttrs>()
    .set_num_inputs(3)
    .add_argument("data", "Tensor", "The quantized input data tensor.")
    .add_argument("weight", "Tensor", "The quantized weight tensor.")
    .add_argument("bias", "Tensor", "The quantized bias tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIConv2D", QnnCSIConv2DRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIConv2D").set_body_typed(MakeQnnCSIConv2D);

Expr MakeQnnCSIConv2DRelu(Expr data, Expr weight, Expr bias, Array<IndexExpr> strides,
                          Array<IndexExpr> padding, Array<IndexExpr> dilation, int groups,
                          IndexExpr channels, Array<IndexExpr> kernel_size, std::string data_layout,
                          std::string kernel_layout, std::string out_layout, DataType out_dtype,

                          Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIConv2DAttrs>();
  attrs->strides = std::move(strides);
  attrs->padding = std::move(padding);
  attrs->dilation = std::move(dilation);
  attrs->groups = groups;
  attrs->channels = std::move(channels);
  attrs->kernel_size = std::move(kernel_size);
  attrs->data_layout = std::move(data_layout);
  attrs->kernel_layout = std::move(kernel_layout);
  attrs->out_layout = std::move(out_layout);
  attrs->out_dtype = std::move(out_dtype);
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.conv2d_relu");
  return Call(op, {data, weight, bias}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.conv2d_relu")
    .describe(R"code(2D quantized convolution layer.
This operator convolves quantized weight with quantized data. The scale of the
the input quantized tensors. The zero point of the output quantized tensor is
0. By default, the dtype of output is int32. Please also refer to Requantize
operator to understand how to scale back the int32 output to (u)int8.
- **data**: This depends on the `layout` parameter. Input is 4D array of shape
            (batch_size, in_channels, height, width) if `layout` is `NCHW`.
- **weight**: (channels, in_channels, kernel_size[0], kernel_size[1])
- **out**:  This depends on the `layout` parameter. Output is 4D array of shape
            (batch_size, channels, out_height, out_width) if `layout` is `NCHW`.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIConv2DAttrs>()
    .set_num_inputs(3)
    .add_argument("data", "Tensor", "The quantized input data tensor.")
    .add_argument("weight", "Tensor", "The quantized weight tensor.")
    .add_argument("bias", "Tensor", "The quantized bias tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIConv2D", QnnCSIConv2DRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIConv2DRelu").set_body_typed(MakeQnnCSIConv2DRelu);

Expr MakeQnnCSIConv2DRelu6(Expr data, Expr weight, Expr bias, Array<IndexExpr> strides,
                           Array<IndexExpr> padding, Array<IndexExpr> dilation, int groups,
                           IndexExpr channels, Array<IndexExpr> kernel_size,
                           std::string data_layout, std::string kernel_layout,
                           std::string out_layout, DataType out_dtype,
                           Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIConv2DAttrs>();
  attrs->strides = std::move(strides);
  attrs->padding = std::move(padding);
  attrs->dilation = std::move(dilation);
  attrs->groups = groups;
  attrs->channels = std::move(channels);
  attrs->kernel_size = std::move(kernel_size);
  attrs->data_layout = std::move(data_layout);
  attrs->kernel_layout = std::move(kernel_layout);
  attrs->out_layout = std::move(out_layout);
  attrs->out_dtype = std::move(out_dtype);
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.conv2d_relu6");
  return Call(op, {data, weight, bias}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.conv2d_relu6")
    .describe(R"code(2D quantized convolution layer.
This operator convolves quantized weight with quantized data. The scale of the
the input quantized tensors. The zero point of the output quantized tensor is
0. By default, the dtype of output is int32. Please also refer to Requantize
operator to understand how to scale back the int32 output to (u)int8.
- **data**: This depends on the `layout` parameter. Input is 4D array of shape
            (batch_size, in_channels, height, width) if `layout` is `NCHW`.
- **weight**: (channels, in_channels, kernel_size[0], kernel_size[1])
- **out**:  This depends on the `layout` parameter. Output is 4D array of shape
            (batch_size, channels, out_height, out_width) if `layout` is `NCHW`.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIConv2DAttrs>()
    .set_num_inputs(3)
    .add_argument("data", "Tensor", "The quantized input data tensor.")
    .add_argument("weight", "Tensor", "The quantized weight tensor.")
    .add_argument("bias", "Tensor", "The quantized bias tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIConv2D", QnnCSIConv2DRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIConv2DRelu6").set_body_typed(MakeQnnCSIConv2DRelu6);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
