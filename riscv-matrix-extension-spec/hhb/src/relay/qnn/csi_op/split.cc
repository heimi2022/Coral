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
 * \file src/relay/qnn/op/slice.cc
 * \brief QNN stride slice operator.
 */
#include <tvm/relay/analysis.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>

#include "../op/op_common.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {

// relay.split
TVM_REGISTER_NODE_TYPE(QnnCSISplitAttrs);

bool QnnCSISplitRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                    const TypeReporter& reporter) {
  // `types` contains: [data, result]
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) return false;
  CHECK_NE(data->shape.size(), 0) << "Input shape cannot be empty";
  const auto param = attrs.as<QnnCSISplitAttrs>();
  CHECK(param != nullptr);
  auto axis = param->axis;
  if (axis < 0) {
    axis += data->shape.size();
  }
  CHECK_LT(axis, data->shape.size()) << "axis should be within the input dimension range.";
  CHECK_GE(axis, 0) << "axis should be within the input dimension range.";

  if (const IntImmNode* sections = param->indices_or_sections.as<IntImmNode>()) {
    CHECK(reporter->Assert(indexmod(data->shape[axis], sections->value) ==
                           tir::make_zero(DataType::Int(64))))
        << "indices_or_sections need to be able to divide input.shape[axis]";
    std::vector<Type> fields;
    for (int i = 0; i < sections->value; ++i) {
      std::vector<IndexExpr> oshape(data->shape.begin(), data->shape.end());
      oshape[axis] = indexdiv(oshape[axis], sections->value);
      auto vec_type = TensorType(oshape, data->dtype);
      fields.push_back(vec_type);
    }
    reporter->Assign(types[1], TupleType(Array<Type>(fields)));
  } else {
    auto indices = Downcast<Array<ObjectRef>>(param->indices_or_sections);
    auto begin = IndexExpr(tir::make_zero(DataType::Int(32)));
    std::vector<Type> fields;
    for (unsigned int i = 0; i < indices.size(); ++i) {
      CHECK(reporter->Assert(Downcast<IndexExpr>(indices[i]) > begin))
          << "indices_or_sections need to be a sorted ascending list";
      std::vector<IndexExpr> oshape(data->shape.begin(), data->shape.end());
      oshape[axis] = Downcast<IndexExpr>(indices[i]) - begin;
      begin = Downcast<IndexExpr>(indices[i]);
      auto vec_type = TensorType(oshape, data->dtype);
      fields.push_back(vec_type);
    }
    CHECK(reporter->Assert(begin < data->shape[axis]))
        << "The sum of sections must match the input.shape[axis]";
    std::vector<IndexExpr> oshape(data->shape.begin(), data->shape.end());
    oshape[axis] = data->shape[axis] - begin;
    auto vec_type = TensorType(oshape, data->dtype);
    fields.push_back(vec_type);
    reporter->Assign(types[1], TupleType(Array<Type>(fields)));
  }
  return true;
}

Expr MakeQnnCSISplit(Expr data, ObjectRef indices_or_sections, int axis, DataType out_dtype,
                     Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSISplitAttrs>();
  attrs->axis = axis;
  attrs->indices_or_sections = std::move(indices_or_sections);
  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.split");
  return Call(op, {data}, Attrs(attrs), {});
}

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSISplit")
    .set_body([](const TVMArgs& args, TVMRetValue* rv) {
      if (args.type_codes[1] == kDLInt) {
        // Note: we change it from Int(64) to Int(32) for now as
        // combine_parallel_dense will transform the graph with Int(32).
        // More invetigation is needs to check which one we should use.
        *rv =
            MakeQnnCSISplit(args[0], tir::make_const(DataType::Int(32), static_cast<int>(args[1])),
                            args[2], args[3], args[4], args[5]);
      } else {
        *rv = MakeQnnCSISplit(args[0], args[1], args[2], args[3], args[4], args[5]);
      }
    });

RELAY_REGISTER_OP("qnn.csi.split")
    .describe(R"code(Splits an array along a particular axis into multiple sub-arrays.

Indices or sections to split into. Accepts an int or a tuple
If indices_or_sections is an integer, the input will be divided equally
along given axis. If such a split is not possible, an error is raised.

If indices_or_sections is a tuple of sorted integers,
the entries indicate where along axis the array is split.

)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSISplitAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSISplitRel", QnnCSISplitRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
