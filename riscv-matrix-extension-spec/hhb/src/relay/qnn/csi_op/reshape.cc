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

/* relay.reshape */
TVM_REGISTER_NODE_TYPE(QnnCSIReshapeAttrs);

bool QnnCSIReshapeRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                      const TypeReporter& reporter) {
  // types: [data, result]
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) {
    CHECK(types[0].as<IncompleteTypeNode>())
        << "reshape: expect input type to be TensorType but get " << types[0];
    return false;
  }

  const auto* param = attrs.as<QnnCSIReshapeAttrs>();
  Array<IndexExpr> data_shape;
  Array<Integer> newshape;
  data_shape = data->shape;
  newshape = param->newshape;
  Array<IndexExpr> oshape;
  std::unordered_set<size_t> used_input_dims;
  std::unordered_set<size_t> used_output_dims;
  size_t src_idx = 0;
  int infer_idx = -1;

  for (size_t i = 0; i < newshape.size(); ++i) {
    int svalue = newshape[i]->value;
    // special flag handling for shape inference.
    if (svalue > 0) {
      oshape.push_back(newshape[i]);
      ++src_idx;
    } else if (svalue == 0) {
      // keep same
      CHECK_LT(src_idx, data_shape.size());
      used_input_dims.insert(src_idx);
      used_output_dims.insert(oshape.size());
      oshape.push_back(data_shape[src_idx++]);
    } else if (svalue == -1) {
      // inference based on rest
      CHECK_LT(infer_idx, 0) << "One and only one dim can be inferred";
      infer_idx = i;
      oshape.push_back(1);
      ++src_idx;
    } else if (svalue == -2) {
      // copy all remaining dims from source
      while (src_idx < data_shape.size()) {
        used_input_dims.insert(src_idx);
        used_output_dims.insert(oshape.size());
        oshape.push_back(data_shape[src_idx++]);
      }
    } else if (svalue == -3) {
      // merge two dims from source
      CHECK_LT(src_idx + 1, data_shape.size());
      used_input_dims.insert(src_idx);
      IndexExpr d1 = data_shape[src_idx++];
      used_input_dims.insert(src_idx);
      IndexExpr d2 = data_shape[src_idx++];
      used_output_dims.insert(oshape.size());
      if (d1.as<AnyNode>() || d2.as<AnyNode>()) {
        oshape.push_back(Any());
      } else {
        oshape.push_back(d1 * d2);
      }
    } else if (svalue == -4) {
      // split the source dim s into two dims
      // read the left dim and then the right dim (either can be -1)
      CHECK_LT(i + 2, newshape.size());
      CHECK_LT(src_idx, data_shape.size());
      used_input_dims.insert(src_idx);
      IndexExpr d0 = data_shape[src_idx++];
      Integer d1 = newshape[++i];
      Integer d2 = newshape[++i];
      if (d1->value == -1) {
        CHECK(d2->value != -1) << "Split dims cannot both be -1.";
        used_output_dims.insert(oshape.size());
        if (d0.as<AnyNode>()) {
          oshape.push_back(Any());
        } else {
          oshape.push_back(indexdiv(d0, d2));
        }
        used_output_dims.insert(oshape.size());
        oshape.push_back(d2);
      } else {
        used_output_dims.insert(oshape.size());
        oshape.push_back(d1);
        used_output_dims.insert(oshape.size());
        if (d2->value == -1) {
          if (d0.as<AnyNode>()) {
            oshape.push_back(Any());
          } else {
            oshape.push_back(indexdiv(d0, d1));
          }
        } else {
          oshape.push_back(d2);
        }
      }
    } else {
      CHECK(false) << "Unsupported special value: " << svalue;
    }
  }

  if (infer_idx >= 0) {
    IndexExpr infer_dim = 1;
    for (size_t i = 0; i < data_shape.size(); ++i) {
      if (used_input_dims.count(i) != 0) {
        continue;
      }
      if (data_shape[i].as<AnyNode>()) {
        infer_dim = Any();
        break;
      }
      infer_dim *= data_shape[i];
    }
    if (!infer_dim.as<AnyNode>()) {
      for (size_t i = 0; i < oshape.size(); ++i) {
        if (used_output_dims.count(i) != 0) {
          continue;
        }
        if (oshape[i].as<AnyNode>()) {
          infer_dim = Any();
          break;
        }
        infer_dim = indexdiv(infer_dim, oshape[i]);
      }
    }
    oshape.Set(infer_idx, infer_dim);
  }

  reporter->Assign(types[1], TensorType(oshape, data->dtype));

  return true;
}

Expr MakeQnnCSIReshape(Expr data, Array<Integer> newshape, DataType out_dtype,
                       Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIReshapeAttrs>();
  attrs->newshape = std::move(newshape);
  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.reshape");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.reshape")
    .describe(
        R"code(Given tensor, this operation returns a new tensor that has the same values as tensor in
          the same order, except with a new shape given by newshape.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIReshapeAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIReshapeRel", QnnCSIReshapeRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIReshape").set_body_typed(MakeQnnCSIReshape);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
