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
 * \file unpooling.cc
 * \brief unpooling operators
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

TVM_REGISTER_NODE_TYPE(QnnCSIUnPoolingAttrs);

bool QnnCSIUnPoolingRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                        const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 3);
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) return false;

  static const Layout kNCHW("NCHW");

  const QnnCSIUnPoolingAttrs* param = attrs.as<QnnCSIUnPoolingAttrs>();
  CHECK(param != nullptr);
  const Layout in_layout(param->layout);

  auto layout_converter = tir::BijectiveLayout(in_layout, kNCHW);
  CHECK(layout_converter.defined())
      << "UpSampling only support input layouts that are convertible from NCHW."
      << " But got " << in_layout;

  auto oshape = layout_converter.ForwardShape(data->shape);
  oshape.Set(2, tir::Cast(oshape[2].dtype(), tvm::round(oshape[2] * param->scales[0])));
  oshape.Set(3, tir::Cast(oshape[3].dtype(), tvm::round(oshape[3] * param->scales[1])));

  // assign output type
  reporter->Assign(types[2], TensorType(layout_converter.BackwardShape(oshape), data->dtype));
  return true;
}

Expr MakeQnnCSIUnPooling(Expr data, Expr mask_data, Array<IndexExpr> scales,
                         Array<IndexExpr> out_padding, DataType out_dtype, std::string layout,
                         Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIUnPoolingAttrs>();
  attrs->scales = std::move(scales);
  attrs->out_padding = std::move(out_padding);
  attrs->layout = std::move(layout);
  attrs->out_dtype = std::move(out_dtype);
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.unpooling");
  return Call(op, {data, mask_data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.unpooling")
    .describe(R"doc(unpooling operator.

 - **data**: Input is 4D array of shape
             (batch_size, channels, height, width)
 )doc" TVM_ADD_FILELINE)
    .set_num_inputs(2)
    .set_attrs_type<QnnCSIUnPoolingAttrs>()
    .add_argument("data", "Tensor", "The input tensor.")
    .add_argument("mask_data", "Tensor", "The mask_data tensor.")
    .add_argument("scales", "Tensor", "The out scale size")
    .add_argument("out_padding", "Tensor", "The out scale size")
    .set_support_level(11)
    .add_type_rel("QnnCSIUnPoolingRel", QnnCSIUnPoolingRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIUnPooling").set_body_typed(MakeQnnCSIUnPooling);
}  // namespace qnn
}  // namespace relay
}  // namespace tvm
