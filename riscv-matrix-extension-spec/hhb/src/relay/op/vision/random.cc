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
 * \file standard_normal.cc
 * \brief standard_normal operators
 */
#include <tvm/relay/attrs/vision.h>
#include <tvm/relay/op.h>
#include <tvm/relay/op_attr_types.h>

namespace tvm {
namespace relay {

TVM_REGISTER_NODE_TYPE(StandardNormalAttrs);

bool StandardNormalRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                       const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 3);

  const auto param = attrs.as<StandardNormalAttrs>();
  CHECK(param != nullptr);

  const auto* data = types[0].as<TensorTypeNode>();

  std::vector<IndexExpr> oshape(param->size.begin(), param->size.end());

  // assign output type
  reporter->Assign(types[2], TensorType(oshape, data->dtype));
  return true;
}

Expr MakeStandardNormal(Expr loc, Expr scale, Array<IndexExpr> size) {
  auto attrs = make_object<StandardNormalAttrs>();
  attrs->loc = loc;
  attrs->scale = scale;
  attrs->size = std::move(size);
  static const Op& op = Op::Get("vision.standard_normal");
  return Call(op, {loc, scale}, Attrs(attrs), {});
}

TVM_REGISTER_GLOBAL("relay.op.vision._make.standard_normal").set_body_typed(MakeStandardNormal);

RELAY_REGISTER_OP("vision.standard_normal")
    .describe(R"doc(standard_normal operator.

 - **data**: Input is 1D or 2D array.
 )doc" TVM_ADD_FILELINE)
    .set_attrs_type<StandardNormalAttrs>()
    .set_num_inputs(2)
    .add_argument("loc", "Expr", "mean.")
    .add_argument("scale", "Expr", "var.")
    .add_argument("size", "Expr", "output shape.")
    .set_support_level(5)
    .add_type_rel("StandardNormalRel", StandardNormalRel);

}  // namespace relay
}  // namespace tvm
