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
 * \file extract_image_patches.cc
 * \brief extract_image_patches operators
 */
#include <tvm/relay/attrs/vision.h>
#include <tvm/relay/op.h>
#include <tvm/relay/op_attr_types.h>

namespace tvm {
namespace relay {

TVM_REGISTER_NODE_TYPE(ExtractImagePatchesAttrs);

bool ExtractImagePatchesRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                            const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();

  if (data == nullptr) return false;

  const auto dshape = data->shape;
  CHECK_GE(dshape.size(), 2U)
      << "ExtractImagePatches only support input >= 2-D: input must have height and width";
  const auto param = attrs.as<ExtractImagePatchesAttrs>();
  CHECK(param != nullptr);

  Layout layout(param->layout);
  CHECK(layout.Contains(LayoutAxis::Get('H')) && layout.Contains(LayoutAxis::Get('W')) &&
        !layout.Contains(LayoutAxis::Get('h')) && !layout.Contains(LayoutAxis::Get('w')))
      << "Invalid layout " << layout
      << ". ExtractImagePatches layout must have H and W, which cannot be split";

  std::vector<IndexExpr> oshape(dshape.begin(), dshape.end());
  oshape[1] = param->ksizes[0] * param->ksizes[1] * dshape[1];

  // assign output type
  reporter->Assign(types[1], TensorType(oshape, data->dtype));
  return true;
}

Expr MakeExtractImagePatches(Expr data, Array<IndexExpr> ksizes, Array<IndexExpr> strides,
                             Array<IndexExpr> rates, Array<IndexExpr> padding, std::string layout) {
  auto attrs = make_object<ExtractImagePatchesAttrs>();
  attrs->ksizes = std::move(ksizes);
  attrs->strides = std::move(strides);
  attrs->padding = std::move(padding);
  attrs->rates = std::move(rates);
  attrs->layout = std::move(layout);
  static const Op& op = Op::Get("vision.extract_image_patches");
  return Call(op, {data}, Attrs(attrs), {});
}

TVM_REGISTER_GLOBAL("relay.op.vision._make.extract_image_patches")
    .set_body_typed(MakeExtractImagePatches);

RELAY_REGISTER_OP("vision.extract_image_patches")
    .describe(R"doc(extract_image_patches operator.

 - **data**: Input is 4D array of shape
             (batch_size, channels, height, width)
 )doc" TVM_ADD_FILELINE)
    .set_attrs_type<ExtractImagePatchesAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The input tensor.")
    .add_argument("ksizes", "Tensor", "The kernel size")
    .add_argument("strides", "Tensor", "The kernel stride size")
    .add_argument("padding", "Tensor", "The padding size")
    .add_argument("rates", "Tensor", "The ceil model")
    .set_support_level(5)
    .add_type_rel("ExtractImagePatchesRel", ExtractImagePatchesRel);

}  // namespace relay
}  // namespace tvm
