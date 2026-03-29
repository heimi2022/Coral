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
TVM_REGISTER_NODE_TYPE(QnnCSIMaxPool2DAttrs);
TVM_REGISTER_NODE_TYPE(QnnCSIAvgPool2DAttrs);
TVM_REGISTER_NODE_TYPE(QnnCSIMaxPool2DLocatAttrs);

template <typename AttrType>
bool QnnCSIPool2DRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                     const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();

  if (data == nullptr) return false;

  const auto dshape = data->shape;
  CHECK_GE(dshape.size(), 2U)
      << "Pool2D only support input >= 2-D: input must have height and width";
  const auto param = attrs.as<AttrType>();
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

  std::vector<IndexExpr> oshape;
  for (const auto& e : dshape) {
    oshape.push_back(e);
  }

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

template <typename AttrType>
bool QnnCSIPool2DLocatRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                          const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();

  if (data == nullptr) return false;

  const auto dshape = data->shape;
  CHECK_GE(dshape.size(), 2U)
      << "Pool2D only support input >= 2-D: input must have height and width";
  const auto param = attrs.as<AttrType>();
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

  std::vector<IndexExpr> oshape;
  for (const auto& e : dshape) {
    oshape.push_back(e);
  }

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
  DataType dtype = DataType::Float(32);
  // assign output type
  reporter->Assign(types[1], TensorType(oshape, dtype));
  return true;
}

// QNN Multiplication operator.
Expr MakeQnnCSIMaxPool(Expr data, DataType out_dtype, Array<IndexExpr> strides,
                       Array<IndexExpr> padding, Array<IndexExpr> pool_size, bool ceil_mode,
                       std::string layout, Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIMaxPool2DAttrs>();
  attrs->pool_size = std::move(pool_size);
  attrs->strides = std::move(strides);
  attrs->padding = std::move(padding);
  attrs->layout = std::move(layout);
  attrs->out_dtype = std::move(out_dtype);
  attrs->ceil_mode = ceil_mode;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.maxpool2d");
  return Call(op, {data}, Attrs(attrs), {});
}
RELAY_REGISTER_OP("qnn.csi.maxpool2d")
    .describe(R"code(Max pooling operation for two dimensional data.

- **data**: This depends on the `layout` parameter. Input is 4D array of shape
            (batch_size, channels, height, width) if `layout` is `NCHW`.
- **out**: This depends on the `layout` parameter. Output is 4D array of shape
           (batch_size, channels, out_height, out_width)  if `layout` is `NCHW`.
           out_height and out_width are calculated as::

               out_height = floor((height+padding[0]+padding[2]-pool_size[0])/strides[0])+1
               out_width = floor((width+padding[1]+padding[3]-pool_size[1])/strides[1])+1

           where padding will be an expanded array based on number of values passed as::
               one int : all sides same padding used.
               two int : bottom, right use same as top and left.
               four int: padding width in the order of (top, left, bottom, right).

           When `ceil_mode` is `True`, ceil will be used instead of floor in this
           equation.

)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIMaxPool2DAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIMaxPool2DRel", QnnCSIPool2DRel<QnnCSIMaxPool2DAttrs>)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIMaxPool").set_body_typed(MakeQnnCSIMaxPool);

Expr MakeQnnCSIMaxPool2dWithArgmax(Expr data, DataType out_dtype, Array<IndexExpr> strides,
                                   Array<IndexExpr> padding, Array<IndexExpr> pool_size,
                                   bool ceil_mode, std::string layout,
                                   Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIMaxPool2DAttrs>();
  attrs->pool_size = std::move(pool_size);
  attrs->strides = std::move(strides);
  attrs->padding = std::move(padding);
  attrs->layout = std::move(layout);
  attrs->out_dtype = std::move(out_dtype);
  attrs->ceil_mode = ceil_mode;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.maxpool2d_with_argmax");
  return Call(op, {data}, Attrs(attrs), {});
}
RELAY_REGISTER_OP("qnn.csi.maxpool2d_with_argmax")
    .describe(R"code(Max pooling operation for two dimensional data.

- **data**: This depends on the `layout` parameter. Input is 4D array of shape
            (batch_size, channels, height, width) if `layout` is `NCHW`.
- **out**: This depends on the `layout` parameter. Output is 4D array of shape
           (batch_size, channels, out_height, out_width)  if `layout` is `NCHW`.
           out_height and out_width are calculated as::

               out_height = floor((height+padding[0]+padding[2]-pool_size[0])/strides[0])+1
               out_width = floor((width+padding[1]+padding[3]-pool_size[1])/strides[1])+1

           where padding will be an expanded array based on number of values passed as::
               one int : all sides same padding used.
               two int : bottom, right use same as top and left.
               four int: padding width in the order of (top, left, bottom, right).

           When `ceil_mode` is `True`, ceil will be used instead of floor in this
           equation.

)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIMaxPool2DAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIMaxPool2DRel", QnnCSIPool2DRel<QnnCSIMaxPool2DAttrs>)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIMaxPool2dWithArgmax")
    .set_body_typed(MakeQnnCSIMaxPool2dWithArgmax);

Expr MakeQnnCSIMaxPool2DLocat(Expr data, Array<IndexExpr> strides, Array<IndexExpr> padding,
                              Array<IndexExpr> pool_size, bool ceil_mode, DataType out_dtype,
                              std::string layout, Array<Array<IndexExpr>> q_params,
                              String layer_name) {
  auto attrs = make_object<QnnCSIMaxPool2DLocatAttrs>();
  attrs->pool_size = std::move(pool_size);
  attrs->strides = std::move(strides);
  attrs->padding = std::move(padding);
  attrs->layout = std::move(layout);
  attrs->out_dtype = std::move(out_dtype);
  attrs->ceil_mode = ceil_mode;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.maxpool2d_locat");

  return Call(op, {data}, Attrs(attrs), {});
}
RELAY_REGISTER_OP("qnn.csi.maxpool2d_locat")
    .describe(R"code(Max pooling location operation for two dimensional data.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIMaxPool2DLocatAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIMaxPool2DLocatRel", QnnCSIPool2DLocatRel<QnnCSIMaxPool2DLocatAttrs>)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIMaxPool2DLocat")
    .set_body_typed(MakeQnnCSIMaxPool2DLocat);

Expr MakeQnnCSIAvgPool(Expr data, DataType out_dtype, Array<IndexExpr> strides,
                       Array<IndexExpr> padding, Array<IndexExpr> pool_size, bool ceil_mode,
                       bool count_include_pad, std::string layout, Array<Array<IndexExpr>> q_params,
                       String layer_name) {
  auto attrs = make_object<QnnCSIAvgPool2DAttrs>();
  attrs->pool_size = std::move(pool_size);
  attrs->strides = std::move(strides);
  attrs->padding = std::move(padding);
  attrs->layout = std::move(layout);
  attrs->out_dtype = std::move(out_dtype);
  attrs->ceil_mode = ceil_mode;
  attrs->count_include_pad = count_include_pad;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.avgpool2d");
  return Call(op, {data}, Attrs(attrs), {});
}
RELAY_REGISTER_OP("qnn.csi.avgpool2d")
    .describe(R"code(
Average pooling operation for one dimensional data.

- **data**: This depends on the `layout` parameter. Input is 4D array of shape
            (batch_size, channels, height, width) if `layout` is `NCHW`.
- **out**: This depends on the `layout` parameter. Output is 4D array of shape
           (batch_size, channels, out_height, out_width)  if `layout` is `NCHW`.
           out_height and out_width are calculated as::

               out_height = floor((height+padding[0]+padding[2]-pool_size[0])/strides[0])+1
               out_width = floor((width+padding[1]+padding[3]-pool_size[1])/strides[1])+1

           where padding will be an expanded array based on number of values passed as::
               one int : all sides same padding used.
               two int : bottom, right use same as top and left.
               four int: padding width in the order of (top, left, bottom, right).

)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIAvgPool2DAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIAvgPool2DRel", QnnCSIPool2DRel<QnnCSIAvgPool2DAttrs>)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIAvgPool2d").set_body_typed(MakeQnnCSIAvgPool);
}  // namespace qnn
}  // namespace relay
}  // namespace tvm
