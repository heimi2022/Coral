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
 * \file src/relay/qnn/op/dequantize.cc
 * \brief QNN dequantize operator. Dequantize operator converts from quantized
 * domain to unquantized domain.
 */

#include <tvm/relay/analysis.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>

#include "../op/op_common.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {

TVM_REGISTER_NODE_TYPE(NNDeinitAttrs);

bool CSINNDeinitRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                    const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();
  CHECK(data);
  const Array<tvm::PrimExpr> oshape = data->shape;
  // assign output type, output will always be float 32.
  reporter->Assign(types[1], TensorType(oshape, DataType::Float(32)));
  return true;
}

Expr MakeCSINNDeinit(Expr data, double input_scale, int32_t input_zero_point) {
  auto attrs = make_object<NNDeinitAttrs>();
  attrs->input_scale = input_scale;
  attrs->input_zero_point = input_zero_point;
  // real_value = scale * (quantized_value - zero_point)
  // A more detailed explanation can be found here -
  // https://github.com/google/gemmlowp/blob/master/doc/quantization.md
  static const Op& op = Op::Get("qnn.csi.nn_deinit");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.nn_deinit")
    .describe(R"code(Dequantizes the input and produces float32 output.
The input is always quantized (int8, uint8) and will be converted to float32 given input scale and zero_point.
- **data**: Quantized tensor of any shape to dequantize. The input data can be of floating point
)code" TVM_ADD_FILELINE)
    .set_attrs_type<NNDeinitAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The tensor to dequantize.")
    .set_support_level(11)
    .add_type_rel("CSINNDeinitRel", CSINNDeinitRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSINNDeinit").set_body_typed(MakeCSINNDeinit);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
