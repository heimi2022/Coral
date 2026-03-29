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

// relay.op.qnn.avgpool3d
TVM_REGISTER_NODE_TYPE(QnnCSIAvgPool3DAttrs);
TVM_REGISTER_NODE_TYPE(QnnCSIMaxPool3DAttrs);

template <typename AttrType>
bool QnnCSIPool3DRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                     const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();

  if (data == nullptr) return false;

  const auto dshape = data->shape;
  CHECK_GE(dshape.size(), 3U)
      << "Pool3D only support input >= 3-D: input must have depth, height and width";
  const auto param = attrs.as<AttrType>();
  CHECK(param != nullptr);

  Layout layout(param->layout);
  CHECK(layout.Contains(LayoutAxis::Get('D')) && layout.Contains(LayoutAxis::Get('H')) &&
        layout.Contains(LayoutAxis::Get('W')) && !layout.Contains(LayoutAxis::Get('d')) &&
        !layout.Contains(LayoutAxis::Get('h')) && !layout.Contains(LayoutAxis::Get('w')))
      << "Invalid layout " << layout
      << ". Pool3D layout must have D, H and W, which cannot be split";

  const auto didx = layout.IndexOf(LayoutAxis::Get('D'));
  const auto hidx = layout.IndexOf(LayoutAxis::Get('H'));
  const auto widx = layout.IndexOf(LayoutAxis::Get('W'));

  IndexExpr pad[3];
  if (param->padding.size() == 1) {
    pad[0] = param->padding[0] * 2;
    pad[1] = param->padding[0] * 2;
    pad[2] = param->padding[0] * 2;
  } else if (param->padding.size() == 3) {
    // (front, top, left)
    pad[0] = param->padding[0] * 2;
    pad[1] = param->padding[1] * 2;
    pad[2] = param->padding[2] * 2;
  } else if (param->padding.size() == 6) {
    // (front, top, left, back, bottom, right)
    pad[0] = param->padding[0] + param->padding[3];
    pad[1] = param->padding[1] + param->padding[4];
    pad[2] = param->padding[2] + param->padding[5];
  } else {
    return false;
  }

  std::vector<IndexExpr> oshape(dshape.begin(), dshape.end());

  int idxes[3] = {didx, hidx, widx};
  for (int i = 0; i < 3; i++) {
    int ii = idxes[i];
    if (dshape[ii].as<tir::AnyNode>()) {
      oshape[ii] = dshape[ii];
    } else {
      if (param->ceil_mode) {
        oshape[ii] = ((dshape[ii] + pad[i] - param->pool_size[i] + param->strides[i] - 1) /
                      param->strides[i]) +
                     1;
      } else {
        oshape[ii] = ((dshape[ii] + pad[i] - param->pool_size[i]) / param->strides[i]) + 1;
      }
    }
  }

  // assign output type
  reporter->Assign(types[1], TensorType(oshape, data->dtype));
  return true;
}

Expr MakeQnnCSIAvgPool3D(Expr data, DataType out_dtype, Array<IndexExpr> strides,
                         Array<IndexExpr> padding, Array<IndexExpr> pool_size, bool ceil_mode,
                         bool count_include_pad, std::string layout,
                         Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIAvgPool3DAttrs>();
  attrs->pool_size = std::move(pool_size);
  attrs->strides = std::move(strides);
  attrs->padding = std::move(padding);
  attrs->layout = std::move(layout);
  attrs->out_dtype = std::move(out_dtype);
  attrs->ceil_mode = ceil_mode;
  attrs->count_include_pad = count_include_pad;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.avgpool3d");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.avgpool3d")
    .describe(R"code(
Average pooling operation for three dimensional data.

- **data**: This depends on the `layout` parameter. Input is 5D array of shape
            (batch_size, channels, depth, height, width) if `layout` is `NCDHW`.
- **out**: This depends on the `layout` parameter. Output is 5D array of shape
           (batch_size, channels, out_depth, out_height, out_width)  if `layout` is `NCDHW`.
           out_depth, out_height and out_width are calculated as::

               out_depth = floor((depth+padding[0]+padding[3]-pool_size[0])/strides[0])+1
               out_height = floor((height+padding[1]+padding[4]-pool_size[1])/strides[1])+1
               out_width = floor((width+padding[2]+padding[5]-pool_size[2])/strides[2])+1

           where padding will be an expanded array based on number of values passed as::
               one int : all sides same padding used.
               three int : front, bottom, right use same as back, top and left.
               six int: padding width in the order of (front, top, left, back, bottom, right).

           When `ceil_mode` is `True`, ceil will be used instead of floor in this
           equation.

)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIAvgPool3DAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized input data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIAvgPool3D", QnnCSIPool3DRel<QnnCSIAvgPool3DAttrs>)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIAvgPool3D").set_body_typed(MakeQnnCSIAvgPool3D);

Expr MakeQnnCSIMaxPool3D(Expr data, DataType out_dtype, Array<IndexExpr> strides,
                         Array<IndexExpr> padding, Array<IndexExpr> pool_size, bool ceil_mode,
                         std::string layout,

                         Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIMaxPool3DAttrs>();
  attrs->pool_size = std::move(pool_size);
  attrs->strides = std::move(strides);
  attrs->padding = std::move(padding);
  attrs->layout = std::move(layout);
  attrs->out_dtype = std::move(out_dtype);
  attrs->ceil_mode = ceil_mode;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.maxpool3d");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.maxpool3d")
    .describe(R"code(
Max pooling operation for three dimensional data.

- **data**: This depends on the `layout` parameter. Input is 5D array of shape
            (batch_size, channels, depth, height, width) if `layout` is `NCDHW`.
- **out**: This depends on the `layout` parameter. Output is 5D array of shape
           (batch_size, channels, out_depth, out_height, out_width)  if `layout` is `NCDHW`.
           out_depth, out_height and out_width are calculated as::

               out_depth = floor((depth+padding[0]+padding[3]-pool_size[0])/strides[0])+1
               out_height = floor((height+padding[1]+padding[4]-pool_size[1])/strides[1])+1
               out_width = floor((width+padding[2]+padding[5]-pool_size[2])/strides[2])+1

           where padding will be an expanded array based on number of values passed as::
               one int : all sides same padding used.
               three int : front, bottom, right use same as back, top and left.
               six int: padding width in the order of (front, top, left, back, bottom, right).

           When `ceil_mode` is `True`, ceil will be used instead of floor in this
           equation.

)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIMaxPool3DAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized input data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIMaxPool3D", QnnCSIPool3DRel<QnnCSIMaxPool3DAttrs>)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIMaxPool3D").set_body_typed(MakeQnnCSIMaxPool3D);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
