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
 * \file src/relay/qnn/op/reduce.cc
 * \brief QNN operator.
 */
#include <tvm/relay/analysis.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>

#include "../op/op_common.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {
TVM_REGISTER_NODE_TYPE(QnnCSINonMaximumSuppressionAttrs);

bool QnnCSINMSRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                  const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 5);
  const auto* data = types[0].as<TensorTypeNode>();
  const auto* valid_count = types[1].as<TensorTypeNode>();
  const QnnCSINonMaximumSuppressionAttrs* param = attrs.as<QnnCSINonMaximumSuppressionAttrs>();
  const auto& dshape = data->shape;
  const auto& vshape = valid_count->shape;
  CHECK_EQ(dshape.size(), 3) << "Input data should be 3-D.";
  CHECK_EQ(vshape.size(), 1) << "Input valid count should be 1-D.";

  // assign output type
  if (param->return_indices) {
    std::vector<Type> fields;
    // dynamic happens for return_indices in TensorFlow & ONNX
    std::vector<IndexExpr> oshape({dshape[0], dshape[1]});
    fields.push_back(TensorType(oshape, DataType::Int(32)));
    std::vector<IndexExpr> countshape({dshape[0], 1});
    fields.push_back(TensorType(countshape, DataType::Int(32)));
    reporter->Assign(types[4], TupleType(Array<Type>(fields)));
  } else {
    reporter->Assign(types[4], TensorType(dshape, data->dtype));
  }
  return true;
}

// QNN Multiplication operator.
Expr MakeQnnCSINMS(Expr data, Expr valid_count, Expr indices, Expr max_output_size,
                   double iou_threshold, bool force_suppress, int top_k, int coord_start,
                   int score_index, int id_index, bool return_indices, bool invalid_to_bottom,
                   DataType out_dtype, Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSINonMaximumSuppressionAttrs>();

  attrs->iou_threshold = iou_threshold;
  attrs->force_suppress = force_suppress;
  attrs->top_k = top_k;
  attrs->coord_start = coord_start;
  attrs->score_index = score_index;
  attrs->id_index = id_index;
  attrs->return_indices = return_indices;
  attrs->invalid_to_bottom = invalid_to_bottom;

  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.nms");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.nms")
    .describe(R"doc(Non-maximum suppression. The input boxes should
be in the format of [class_id, score, left, top, right, bottom]
or [score, left, top, right, bottom]. Set id_index to be -1 to
ignore class_id axis.
)doc" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSINonMaximumSuppressionAttrs>()
    .set_num_inputs(4)
    .add_argument("data", "Tensor", "The quantized data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSINMSRel", QnnCSINMSRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSINMS").set_body_typed(MakeQnnCSINMS);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
