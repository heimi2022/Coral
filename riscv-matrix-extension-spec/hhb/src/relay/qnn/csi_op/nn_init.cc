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
 * \file src/relay/qnn/op/quantize.cc
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

TVM_REGISTER_NODE_TYPE(NNInitAttrs);

bool CSINNInitRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                  const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();
  const auto input_dtype = data->dtype;
  CHECK(input_dtype == DataType::Float(32))
      << "Input type should be one of float32 but was " << input_dtype;
  const auto* quantize_attrs = attrs.as<NNInitAttrs>();
  const Array<tvm::PrimExpr> oshape = data->shape;
  const DataType out_dtype = quantize_attrs->out_dtype;
  // assign output type
  reporter->Assign(types[1], TensorType(oshape, out_dtype));
  return true;
}

Expr MakeCSINNInit(Expr data, double output_scale, int32_t output_zero_point, DataType out_dtype,
                   Array<IndexExpr> max_values, Array<IndexExpr> min_values) {
  auto attrs = make_object<NNInitAttrs>();
  attrs->output_scale = output_scale;
  attrs->output_zero_point = output_zero_point;
  attrs->out_dtype = std::move(out_dtype);
  attrs->max_values = std::move(max_values);
  attrs->min_values = std::move(min_values);
  static const Op& op = Op::Get("qnn.csi.nn_init");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.nn_init")
    .describe(R"code(nn_init the input and produces quantized output.
The input can be either float or quantized(int8, unit8). If the input is float,
this op takes scale and zero point and quantize the float value to
quantized output, in int8 or uint8 format. If the input is quantized value,
the op requantize the input (of a certain type, with a given scale and zero
point) to the output of the same or different type with a same or different
scale and zero point.
- **data**: Tensor of any shape to quantize. The input data can be of floating point
          or quantized.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<NNInitAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The tensor to quantize.")
    .set_support_level(11)
    .add_type_rel("CSINNInitRel", CSINNInitRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSINNInit").set_body_typed(MakeCSINNInit);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
