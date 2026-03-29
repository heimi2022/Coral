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
 * \file categorical.cc
 * \brief categorical operators
 */
#include <tvm/relay/attrs/vision.h>
#include <tvm/relay/op.h>
#include <tvm/relay/op_attr_types.h>

namespace tvm {
namespace relay {

TVM_REGISTER_NODE_TYPE(CategoricalAttrs);

bool CategoricalRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                    const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();

  if (data == nullptr) return false;

  const auto dshape = data->shape;
  CHECK(dshape.size() == 2) << "categorical only support input == 2-D";
  const auto param = attrs.as<CategoricalAttrs>();
  CHECK(param != nullptr);

  std::vector<IndexExpr> oshape(dshape.begin(), dshape.end());
  oshape[1] = param->num_samples;
  // assign output type
  reporter->Assign(types[1], TensorType(oshape, data->dtype));
  return true;
}

Expr MakeCategorical(Expr data, int32_t num_samples, int32_t seed, int32_t seed2) {
  auto attrs = make_object<CategoricalAttrs>();
  attrs->num_samples = std::move(num_samples);
  attrs->seed = std::move(seed);
  attrs->seed2 = std::move(seed2);
  static const Op& op = Op::Get("vision.categorical");
  return Call(op, {data}, Attrs(attrs), {});
}

TVM_REGISTER_GLOBAL("relay.op.vision._make.categorical").set_body_typed(MakeCategorical);

RELAY_REGISTER_OP("vision.categorical")
    .describe(R"doc(categorical operator.

 - **data**: Input is 4D array of shape
             (batch_size, channels, height, width)
 )doc" TVM_ADD_FILELINE)
    .set_attrs_type<CategoricalAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The input tensor.")
    .add_argument("num_samples", "Int", "Number of independent samples to draw for each row slice.")
    .add_argument("seed", "Int", "random seed.")
    .add_argument("seed2", "Int", "A second seed to avoid seed collision.")
    .set_support_level(5)
    .add_type_rel("CategoricalRel", CategoricalRel);

}  // namespace relay
}  // namespace tvm
