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
 * \file psroipooling.cc
 * \brief PSRoIPooling operators
 */
#include <tvm/relay/attrs/vision.h>
#include <tvm/relay/op.h>
#include <tvm/relay/op_attr_types.h>

namespace tvm {
namespace relay {

TVM_REGISTER_NODE_TYPE(PSRoIPoolingAttrs);

bool PSRoIpoolingRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                     const TypeReporter& reporter) {
  auto psroipooling_attrs = attrs.as<PSRoIPoolingAttrs>();
  CHECK_EQ(types.size(), 3);
  const auto* data = types[0].as<TensorTypeNode>();
  const auto* rois = types[1].as<TensorTypeNode>();
  const auto& dshape = data->shape;
  const auto& rshape = rois->shape;
  CHECK(psroipooling_attrs);
  CHECK_EQ(dshape.size(), 4) << "Input data should be 4-D.";
  CHECK_EQ(rshape.size(), 2) << "Input rois should be 2-D.";
  // assign output type
  std::vector<IndexExpr> oshape({rshape[0], psroipooling_attrs->output_dim,
                                 psroipooling_attrs->group_size, psroipooling_attrs->group_size});
  reporter->Assign(types[2], TensorType(oshape, data->dtype));
  return true;
}

Expr MakePSRoIPooling(Expr data, Expr rois, int output_dim, int group_size, double spatial_scale) {
  auto attrs = make_object<PSRoIPoolingAttrs>();
  attrs->output_dim = output_dim;
  attrs->group_size = group_size;
  attrs->spatial_scale = spatial_scale;
  static const Op& op = Op::Get("vision.psroipooling");
  return Call(op, {data, rois}, Attrs(attrs), {});
}

TVM_REGISTER_GLOBAL("relay.op.vision._make.psroipooling").set_body_typed(MakePSRoIPooling);

RELAY_REGISTER_OP("vision.psroipooling")
    .describe(R"doc(PSRoIpooling operator.

 - **data**: Input is 4D array of shape
             (batch_size, channels, height, width)
 - **rois**: 2D array of shape (num_roi, 5). The last dimension should be in format of
             [batch_index, w_start, h_start, w_end, h_end].
 - **out**: This depends on the `layout` parameter. Output is 4D array of shape
            (num_roi, output_dim, group_size, group_size).
 )doc" TVM_ADD_FILELINE)
    .set_num_inputs(2)
    .add_argument("data", "Tensor", "The input tensor.")
    .add_argument("rois", "Tensor", "The input rois")
    .set_support_level(5)
    .add_type_rel("PSRoIPooling", PSRoIpoolingRel);

}  // namespace relay
}  // namespace tvm
