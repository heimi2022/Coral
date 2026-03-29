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
 * \file max_pool2d_location.cc
 * \brief max_pool2d_location operators
 */
#include <tvm/relay/attrs/vision.h>
#include <tvm/relay/op.h>
#include <tvm/relay/op_attr_types.h>

namespace tvm {
namespace relay {

TVM_REGISTER_NODE_TYPE(MaxPool2dLocationAttrs);

bool MaxPool2dLocationRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                          const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();

  if (data == nullptr) return false;

  const auto dshape = data->shape;
  CHECK_GE(dshape.size(), 2U)
      << "Pool2D only support input >= 2-D: input must have height and width";
  const auto param = attrs.as<MaxPool2dLocationAttrs>();
  CHECK(param != nullptr);

  Layout layout(param->layout);
  CHECK(layout.Contains(LayoutAxis::Get('H')) && layout.Contains(LayoutAxis::Get('W')) &&
        !layout.Contains(LayoutAxis::Get('h')) && !layout.Contains(LayoutAxis::Get('w')))
      << "Invalid layout " << layout << ". Pool2D layout must have H and W, which cannot be split";

  const auto hidx = layout.IndexOf(LayoutAxis::Get('H'));
  const auto widx = layout.IndexOf(LayoutAxis::Get('W'));

  IndexExpr pad_h, pad_w;
  if (param->padding.size() == 1) {
    pad_h = param->padding[0] * 2;
    pad_w = param->padding[0] * 2;
  } else if (param->padding.size() == 2) {
    // (top, left)
    pad_h = param->padding[0] * 2;
    pad_w = param->padding[1] * 2;
  } else if (param->padding.size() == 4) {
    // (top, left, bottom, right)
    pad_h = param->padding[0] + param->padding[2];
    pad_w = param->padding[1] + param->padding[3];
  } else {
    return false;
  }

  std::vector<IndexExpr> oshape(dshape.begin(), dshape.end());

  if (dshape[hidx].as<tir::AnyNode>()) {
    oshape[hidx] = dshape[hidx];
  } else {
    if (param->ceil_mode) {
      oshape[hidx] = ((dshape[hidx] + pad_h - param->pool_size[0] + param->strides[0] - 1) /
                      param->strides[0]) +
                     1;
    } else {
      oshape[hidx] = ((dshape[hidx] + pad_h - param->pool_size[0]) / param->strides[0]) + 1;
    }
  }
  if (dshape[widx].as<tir::AnyNode>()) {
    oshape[widx] = dshape[widx];
  } else {
    if (param->ceil_mode) {
      oshape[widx] = ((dshape[widx] + pad_w - param->pool_size[1] + param->strides[1] - 1) /
                      param->strides[1]) +
                     1;
    } else {
      oshape[widx] = ((dshape[widx] + pad_w - param->pool_size[1]) / param->strides[1]) + 1;
    }
  }

  // assign output type
  reporter->Assign(types[1], TensorType(oshape, data->dtype));
  return true;
}

Expr MakeMaxPool2dLocation(Expr data, Array<IndexExpr> pool_size, Array<IndexExpr> strides,
                           Array<IndexExpr> padding, std::string layout, bool ceil_mode) {
  auto attrs = make_object<MaxPool2dLocationAttrs>();
  attrs->pool_size = std::move(pool_size);
  attrs->strides = std::move(strides);
  attrs->padding = std::move(padding);
  attrs->ceil_mode = std::move(ceil_mode);
  attrs->layout = std::move(layout);
  static const Op& op = Op::Get("vision.max_pool2d_location");
  return Call(op, {data}, Attrs(attrs), {});
}

TVM_REGISTER_GLOBAL("relay.op.vision._make.max_pool2d_location")
    .set_body_typed(MakeMaxPool2dLocation);

RELAY_REGISTER_OP("vision.max_pool2d_location")
    .describe(R"doc(max_pool2d_location operator.

 - **data**: Input is 4D array of shape
             (batch_size, channels, height, width)
 )doc" TVM_ADD_FILELINE)
    .set_attrs_type<MaxPool2dLocationAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The input tensor.")
    .add_argument("pool_size", "Tensor", "The kernel size")
    .add_argument("strides", "Tensor", "The kernel stride size")
    .add_argument("padding", "Tensor", "The padding size")
    .add_argument("ceil_model", "Bool", "The ceil model")
    .set_support_level(5)
    .add_type_rel("MaxPool2dLocationRel", MaxPool2dLocationRel);

}  // namespace relay
}  // namespace tvm
