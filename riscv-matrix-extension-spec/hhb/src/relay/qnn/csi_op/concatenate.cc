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
 * \file src/relay/qnn/op/concatenate.cc
 * \brief QNN concatenate operator. It concatenates quantized input tensors along a given axis.
 */

#include <tvm/relay/analysis.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>
#include <tvm/tir/expr.h>

#include "../../op/tensor/transform.h"
#include "../op/op_common.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {

TVM_REGISTER_NODE_TYPE(QnnConcatenateAttrs);

Expr MakeQnnCSIConcatenate(Expr data, int axis, Array<Array<IndexExpr>> q_params,
                           String layer_name) {
  auto attrs = make_object<QnnConcatenateAttrs>();

  attrs->axis = std::move(axis);
  attrs->q_params = std::move(q_params);
  attrs->layer_name = layer_name;

  static const Op& op = Op::Get("qnn.csi.concatenate");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.concatenate")
    .describe(R"code(Concatenate the quantized input tensors along the given axis.
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnConcatenateAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The tensor to concatenate.")
    .set_support_level(11)
    .add_type_rel("QnnCSIConcatenate", ConcatenateRel<QnnConcatenateAttrs>)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIConcatenate").set_body_typed(MakeQnnCSIConcatenate);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
