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
#include <tvm/relay/attrs/vision.h>
#include <tvm/relay/op.h>
#include <tvm/relay/op_attr_types.h>

namespace tvm {
namespace relay {

TVM_REGISTER_NODE_TYPE(UnpoolingAttrs);

bool UnpoolingRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                  const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 3);
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) return false;

  static const Layout kNCHW("NCHW");

  const UnpoolingAttrs* param = attrs.as<UnpoolingAttrs>();
  CHECK(param != nullptr);
  const Layout in_layout(param->layout);

  auto layout_converter = tir::BijectiveLayout(in_layout, kNCHW);
  CHECK(layout_converter.defined())
      << "UpSampling only support input layouts that are convertible from NCHW."
      << " But got " << in_layout;

  auto oshape = layout_converter.ForwardShape(data->shape);
  oshape.Set(2, tir::Cast(oshape[2].dtype(), tvm::round(oshape[2] * param->scale_h)));
  oshape.Set(3, tir::Cast(oshape[3].dtype(), tvm::round(oshape[3] * param->scale_w)));

  // assign output type
  reporter->Assign(types[2], TensorType(layout_converter.BackwardShape(oshape), data->dtype));
  return true;
}

Expr MakeUnpooling(Expr data, Expr mask_data, int scale_h, int scale_w, int pad_out_h,
                   int pad_out_w, std::string layout) {
  auto attrs = make_object<UnpoolingAttrs>();
  attrs->scale_h = std::move(scale_h);
  attrs->scale_w = std::move(scale_w);
  attrs->pad_out_h = std::move(pad_out_h);
  attrs->pad_out_w = std::move(pad_out_w);
  attrs->layout = std::move(layout);
  static const Op& op = Op::Get("vision.unpooling");
  return Call(op, {data, mask_data}, Attrs(attrs), {});
}

TVM_REGISTER_GLOBAL("relay.op.vision._make.unpooling").set_body_typed(MakeUnpooling);

RELAY_REGISTER_OP("vision.unpooling")
    .describe(R"doc(unpooling operator.

 - **data**: Input is 4D array of shape
             (batch_size, channels, height, width)
 )doc" TVM_ADD_FILELINE)
    .set_num_inputs(2)
    .set_attrs_type<UnpoolingAttrs>()
    .add_argument("data", "Tensor", "The input tensor.")
    .add_argument("scale_h", "Tensor", "The kernel size")
    .add_argument("scale_w", "Tensor", "The kernel stride size")
    .add_argument("pad_out_h", "Tensor", "The padding size")
    .add_argument("ceil_model", "Bool", "The ceil model")
    .set_support_level(5)
    .add_type_rel("UnpoolingRel", UnpoolingRel);

}  // namespace relay
}  // namespace tvm
