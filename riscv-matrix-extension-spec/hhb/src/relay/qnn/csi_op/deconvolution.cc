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

#include "../../op/op_common.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {

// relay.op.qnn.conv2d
TVM_REGISTER_NODE_TYPE(QnnCSIDeConv2DAttrs);

bool QnnCSIDeConv2DRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                       const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 4);
  const auto* data = types[0].as<TensorTypeNode>();
  const auto* weight = types[1].as<TensorTypeNode>();
  if (data == nullptr) return false;

  static const Layout kNCHW("NCHW");
  static const Layout kIOHW("IOHW");

  const QnnCSIDeConv2DAttrs* param = attrs.as<QnnCSIDeConv2DAttrs>();
  ICHECK(param != nullptr);
  const Layout in_layout(param->data_layout);
  const Layout kernel_layout(param->kernel_layout);

  const auto trans_in_layout = tir::BijectiveLayout(in_layout, kNCHW);
  ICHECK(trans_in_layout.defined())
      << "Conv2DTransposed only support input layouts that are convertible from NCHW."
      << " But got " << in_layout;

  const auto trans_kernel_layout = tir::BijectiveLayout(kernel_layout, kIOHW);
  ICHECK(trans_kernel_layout.defined())
      << "Conv2DTransposed only support kernel layouts that are convertible from IOHW."
      << " But got " << kernel_layout;

  Layout out_layout(param->out_layout == "" ? param->data_layout : param->out_layout);
  const auto trans_out_layout = tir::BijectiveLayout(out_layout, kNCHW);
  ICHECK(trans_out_layout.defined())
      << "Conv2DTransposed only support output layouts that are convertible from NCHW."
      << " But got " << out_layout;

  IndexExpr channels, dilated_ksize_y, dilated_ksize_x;

  auto dshape_nchw = trans_in_layout.ForwardShape(data->shape);

  // infer weight if the kernel_size and channels are defined
  if (param->kernel_size.defined() && param->channels.defined()) {
    ICHECK_EQ(param->kernel_size.size(), 2);
    ICHECK_EQ(param->dilation.size(), 2);

    Array<IndexExpr> wshape({dshape_nchw[1], indexdiv(param->channels, param->groups),
                             param->kernel_size[0], param->kernel_size[1]});

    wshape = trans_kernel_layout.BackwardShape(wshape);
    dilated_ksize_y = 1 + (param->kernel_size[0] - 1) * param->dilation[0];
    dilated_ksize_x = 1 + (param->kernel_size[1] - 1) * param->dilation[1];
    channels = param->channels;

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
      ICHECK_EQ(param->kernel_size.size(), 2);
      // check the size
      ICHECK(reporter->AssertEQ(param->kernel_size[0], wshape[2]) &&
             reporter->AssertEQ(param->kernel_size[1], wshape[3]))
          << "Conv2DTransposed: shape of weight is inconsistent with kernel_size, "
          << " kernel_size=" << param->kernel_size << " wshape=" << Array<IndexExpr>(wshape);
    }
    if (param->channels.defined()) {
      ICHECK(reporter->AssertEQ(indexdiv(param->channels, param->groups), wshape[1]))
          << "Conv2DTransposed: shape of weight is inconsistent with out_channels, "
          << " out_channels // groups != weight.shape[1] "
          << " out_channels=" << param->channels << " groups=" << param->groups
          << " weight.shape=" << Array<IndexExpr>(wshape);
    }
    if (!dshape_nchw[1].as<tir::AnyNode>() && !wshape[0].as<tir::AnyNode>()) {
      ICHECK(reporter->AssertEQ(dshape_nchw[1], wshape[0]))
          << "Conv2DTransposed: shape of weight is inconsistent with in_channels."
          << " data.shape= " << Array<IndexExpr>(dshape_nchw) << " groups= " << param->groups
          << " weight.shape= " << Array<IndexExpr>(wshape);
    }
    channels = wshape[1];
    dilated_ksize_y = 1 + (wshape[2] - 1) * param->dilation[0];
    dilated_ksize_x = 1 + (wshape[3] - 1) * param->dilation[1];
  }
  // dilation
  Array<IndexExpr> oshape({dshape_nchw[0], channels, 0, 0});
  IndexExpr pad_h, pad_w;
  GetPaddingHeightWidth(param->padding, &pad_h, &pad_w);
  if (!dshape_nchw[2].as<tir::AnyNode>()) {
    oshape.Set(2, (param->strides[0] * (dshape_nchw[2] - 1) + dilated_ksize_y - pad_h +
                   param->output_padding[0]));
  } else {
    oshape.Set(2, dshape_nchw[2]);
  }
  if (!dshape_nchw[3].as<tir::AnyNode>()) {
    oshape.Set(3, (param->strides[1] * (dshape_nchw[3] - 1) + dilated_ksize_x - pad_w +
                   param->output_padding[1]));
  } else {
    oshape.Set(3, dshape_nchw[3]);
  }

  DataType out_dtype = param->out_dtype;
  if (out_dtype.bits() == 0) {
    out_dtype = data->dtype;
  }
  oshape = trans_out_layout.BackwardShape(oshape);
  reporter->Assign(types[3], TensorType(oshape, out_dtype));
  return true;
}

Expr MakeQnnCSIDeConv2D(Expr data, Expr weight, Expr bias, Array<IndexExpr> strides,
                        Array<IndexExpr> padding, Array<IndexExpr> dilation, int groups,
                        IndexExpr channels, Array<IndexExpr> kernel_size, std::string data_layout,
                        std::string kernel_layout, std::string out_layout,
                        Array<IndexExpr> output_padding, DataType out_dtype,

                        Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIDeConv2DAttrs>();
  attrs->channels = std::move(channels);
  attrs->kernel_size = std::move(kernel_size);
  attrs->strides = std::move(strides);
  attrs->padding = std::move(padding);
  attrs->output_padding = std::move(output_padding);
  attrs->dilation = std::move(dilation);
  attrs->groups = groups;
  attrs->data_layout = std::move(data_layout);
  attrs->kernel_layout = std::move(kernel_layout);
  attrs->out_layout = std::move(out_layout);
  attrs->out_dtype = std::move(out_dtype);

  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.deconv2d");
  return Call(op, {data, weight, bias}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.deconv2d")
    .describe(R"code(2D quantized deconvolution layer.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIDeConv2DAttrs>()
    .set_num_inputs(3)
    .add_argument("data", "Tensor", "The quantized input data tensor.")
    .add_argument("weight", "Tensor", "The quantized weight tensor.")
    .add_argument("bias", "Tensor", "The quantized bias tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIDeConv2DRel", QnnCSIDeConv2DRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIDeConv2D").set_body_typed(MakeQnnCSIDeConv2D);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
