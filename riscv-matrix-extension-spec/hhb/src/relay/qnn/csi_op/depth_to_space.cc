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
TVM_REGISTER_NODE_TYPE(QnnCSISubPixelAttrs);

bool QnnCSIDepthToSpaceRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                           const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) return false;

  static const Layout kNCHW("NCHW");

  const QnnCSISubPixelAttrs* param = attrs.as<QnnCSISubPixelAttrs>();
  CHECK(param != nullptr);
  const int block_size = param->block_size;
  const Layout in_layout(param->layout);
  auto layout_converter = tir::BijectiveLayout(in_layout, kNCHW);
  CHECK(layout_converter.defined())
      << "DepthToSpace only support input layouts that are convertible from NCHW."
      << " But got " << in_layout;

  auto oshape = layout_converter.ForwardShape(data->shape);
  oshape.Set(1, indexdiv(oshape[1], (block_size * block_size)));
  oshape.Set(2, oshape[2] * block_size);
  oshape.Set(3, oshape[3] * block_size);

  // Assign output type
  reporter->Assign(types[1], TensorType(layout_converter.BackwardShape(oshape), data->dtype));

  return true;
}

// QNN DepthToSpace operator.
Expr MakeQnnCSIDepthToSpace(Expr data, int block_size, String layout, String mode,
                            DataType out_dtype,

                            Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSISubPixelAttrs>();
  attrs->block_size = block_size;
  attrs->layout = std::move(layout);
  attrs->mode = std::move(mode);
  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.depth_to_space");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.depth_to_space")
    .describe(R"code(Rearrange input channels into spatial pixels.

- **data**: data is a 4D array of shape
            (batch, in_channels, in_height, in_width) for NCHW

- **out**: Output is a 4D array of shape
           (batch, in_channels / block_size * block_size, in_height * block_size, in_width * block_size) for NCHW.

)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSISubPixelAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIDepthToSpaceRel", QnnCSIDepthToSpaceRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIDepthToSpace").set_body_typed(MakeQnnCSIDepthToSpace);

bool QnnCSISpaceToDepthRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                           const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) return false;

  static const Layout kNCHW("NCHW");

  const QnnCSISubPixelAttrs* param = attrs.as<QnnCSISubPixelAttrs>();
  CHECK(param != nullptr);
  const int block_size = param->block_size;
  const Layout in_layout(param->layout);
  auto layout_converter = tir::BijectiveLayout(in_layout, kNCHW);
  CHECK(layout_converter.defined())
      << "SpaceToDepth only support input layouts that are convertible from NCHW."
      << " But got " << in_layout;

  auto oshape = layout_converter.ForwardShape(data->shape);
  oshape.Set(1, oshape[1] * (block_size * block_size));
  oshape.Set(2, indexdiv(oshape[2], block_size));
  oshape.Set(3, indexdiv(oshape[3], block_size));

  // Assign output type
  reporter->Assign(types[1], TensorType(layout_converter.BackwardShape(oshape), data->dtype));

  return true;
}

// QNN DepthToSpace operator.
Expr MakeQnnCSISpaceToDepth(Expr data, int block_size, String layout, std::string mode,
                            DataType out_dtype, Array<Array<IndexExpr>> q_params,
                            String layer_name) {
  auto attrs = make_object<QnnCSISubPixelAttrs>();
  attrs->block_size = std::move(block_size);
  attrs->layout = std::move(layout);
  attrs->mode = std::move(mode);
  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.space_to_depth");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.space_to_depth")
    .describe(R"code(Rearrange spatial pixels into new output channels.

- **data**: data is a 4D array of shape
            (batch, in_channels, in_height, in_width) for NCHW

- **out**: Output is a 4D array of shape
           (batch, in_channels * block_size * block_size, in_height / block_size, in_width / block_size) for NCHW.

)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSISubPixelAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSISpaceToDepthRel", QnnCSISpaceToDepthRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSISpaceToDepth").set_body_typed(MakeQnnCSISpaceToDepth);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
