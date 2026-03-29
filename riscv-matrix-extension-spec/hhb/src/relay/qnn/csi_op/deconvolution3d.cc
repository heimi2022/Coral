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
TVM_REGISTER_NODE_TYPE(QnnCSIDeConv3DAttrs);

template <typename AttrType>
bool QnnCSIDeConv3DRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                       const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 4);
  const auto* data = types[0].as<TensorTypeNode>();
  const auto* weight = types[1].as<TensorTypeNode>();
  if (data == nullptr) return false;

  static const Layout kNCDHW("NCDHW");
  static const Layout kOIDHW("OIDHW");

  const QnnCSIDeConv3DAttrs* param = attrs.as<AttrType>();
  CHECK(param != nullptr);
  const Layout in_layout(param->data_layout);
  const Layout kernel_layout(param->kernel_layout);

  const auto trans_in_layout = tir::BijectiveLayout(in_layout, kNCDHW);
  CHECK(trans_in_layout.defined())
      << "Conv3d_transpose only support input layouts that are convertible from NCDHW."
      << " But got " << in_layout;

  const auto trans_kernel_layout = tir::BijectiveLayout(kernel_layout, kOIDHW);
  CHECK(trans_kernel_layout.defined())
      << "Conv3d_transpose only support kernel layouts that are convertible from OIDHW."
      << " But got " << kernel_layout;

  Layout out_layout(param->out_layout == "" ? param->data_layout : param->out_layout);
  const auto trans_out_layout = tir::BijectiveLayout(out_layout, kNCDHW);
  CHECK(trans_out_layout.defined())
      << "Conv3d_transpose only support output layouts that are convertible from NCDHW."
      << " But got " << out_layout;

  IndexExpr channels, dilated_ksize_d, dilated_ksize_y, dilated_ksize_x;

  auto dshape_ncdhw = trans_in_layout.ForwardShape(data->shape);

  // infer weight if the kernel_size and channels are defined
  if (param->kernel_size.defined() && param->channels.defined()) {
    CHECK_EQ(param->kernel_size.size(), 3);
    CHECK_EQ(param->dilation.size(), 3);

    Array<IndexExpr> wshape({dshape_ncdhw[1], indexdiv(param->channels, param->groups),
                             param->kernel_size[0], param->kernel_size[1], param->kernel_size[2]});

    wshape = trans_kernel_layout.BackwardShape(wshape);
    dilated_ksize_d = 1 + (param->kernel_size[0] - 1) * param->dilation[0];
    dilated_ksize_y = 1 + (param->kernel_size[1] - 1) * param->dilation[1];
    dilated_ksize_x = 1 + (param->kernel_size[2] - 1) * param->dilation[2];
    channels = param->channels;

    // assign result to reporter
    reporter->Assign(types[1], TensorType(wshape, data->dtype));
  } else {
    // use weight to infer the conv shape.
    if (weight == nullptr) return false;
    auto wshape = trans_kernel_layout.ForwardShape(weight->shape);
    if (param->kernel_size.defined()) {
      CHECK_EQ(param->kernel_size.size(), 3);
      // check the size
      CHECK(reporter->AssertEQ(param->kernel_size[0], wshape[2]) &&
            reporter->AssertEQ(param->kernel_size[1], wshape[3]) &&
            reporter->AssertEQ(param->kernel_size[2], wshape[4]))
          << "Conv3D: shape of weight is inconsistent with kernel_size, "
          << " kernel_size=" << param->kernel_size << " wshape=" << Array<IndexExpr>(wshape);
    }
    if (param->channels.defined()) {
      CHECK(reporter->AssertEQ(param->channels, wshape[1]))
          << "Conv3D: shape of weight is inconsistent with channels, "
          << " channels=" << param->channels << " wshape=" << Array<IndexExpr>(wshape);
    }
    CHECK(reporter->AssertEQ(indexdiv(dshape_ncdhw[1], param->groups), wshape[0]));
    channels = wshape[1];
    dilated_ksize_d = 1 + (wshape[2] - 1) * param->dilation[0];
    dilated_ksize_x = 1 + (wshape[3] - 1) * param->dilation[1];
    dilated_ksize_y = 1 + (wshape[4] - 1) * param->dilation[2];
  }

  // dilation
  Array<IndexExpr> oshape({dshape_ncdhw[0], channels, 0, 0, 0});
  IndexExpr pad_d, pad_h, pad_w;
  GetPaddingDepthHeightWidth(param->padding, &pad_d, &pad_h, &pad_w);
  oshape.Set(2, (param->strides[0] * (dshape_ncdhw[2] - 1) + dilated_ksize_d - pad_d +
                 param->output_padding[0]));
  oshape.Set(3, (param->strides[1] * (dshape_ncdhw[3] - 1) + dilated_ksize_y - pad_h +
                 param->output_padding[1]));
  oshape.Set(4, (param->strides[2] * (dshape_ncdhw[4] - 1) + dilated_ksize_x - pad_w +
                 param->output_padding[2]));

  DataType out_dtype = param->out_dtype;
  if (out_dtype.bits() == 0) {
    out_dtype = data->dtype;
  }
  oshape = trans_out_layout.BackwardShape(oshape);
  reporter->Assign(types[3], TensorType(oshape, out_dtype));
  return true;
}

Expr MakeQnnCSIDeConv3D(Expr data, Expr weight, Expr bias, Array<IndexExpr> strides,
                        Array<IndexExpr> padding, Array<IndexExpr> dilation, int groups,
                        IndexExpr channels, Array<IndexExpr> kernel_size, std::string data_layout,
                        std::string kernel_layout, std::string out_layout,
                        Array<IndexExpr> output_padding, DataType out_dtype,

                        Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIDeConv3DAttrs>();
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

  static const Op& op = Op::Get("qnn.csi.deconv3d");
  return Call(op, {data, weight, bias}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.deconv3d")
    .describe(R"code(3D quantized deconvolution layer.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIDeConv3DAttrs>()
    .set_num_inputs(3)
    .add_argument("data", "Tensor", "The quantized input data tensor.")
    .add_argument("weight", "Tensor", "The quantized weight tensor.")
    .add_argument("bias", "Tensor", "The quantized bias tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIDeConv3DRel", QnnCSIDeConv3DRel<QnnCSIDeConv3DAttrs>)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIDeConv3D").set_body_typed(MakeQnnCSIDeConv3D);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
