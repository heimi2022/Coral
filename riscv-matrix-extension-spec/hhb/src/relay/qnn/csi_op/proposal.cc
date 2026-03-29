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
 * \file src/relay/qnn/csi_op/Proposal.cc
 * \brief QNN Proposal operator.
 */
#include <tvm/relay/analysis.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>

#include "../op/op_common.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {
TVM_REGISTER_NODE_TYPE(QnnCSIProposalAttrs);

bool QnnCSIProposalRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                       const TypeReporter& reporter) {
  auto proposal_attrs = attrs.as<QnnCSIProposalAttrs>();
  CHECK_EQ(types.size(), 4);
  const auto* cls_prob = types[0].as<TensorTypeNode>();
  const auto* bbox_pred = types[1].as<TensorTypeNode>();
  const auto* im_info = types[2].as<TensorTypeNode>();

  if (!cls_prob || !bbox_pred || !im_info) {
    return false;
  }

  CHECK_EQ(cls_prob->shape.size(), 4U)
      << "The dimension of class probability should be 4, but received " << cls_prob->shape.size();
  CHECK_EQ(bbox_pred->shape.size(), 4U)
      << "The dimension of box prediction should be 4, but received " << bbox_pred->shape.size();
  CHECK_EQ(im_info->shape.size(), 2U)
      << "The dimension of image info should be 2, but received " << im_info->shape.size();
  CHECK(reporter->AssertEQ(im_info->shape[1], 3));

  auto batch = cls_prob->shape[0];

  std::vector<IndexExpr> oshape({batch * proposal_attrs->rpn_post_nms_top_n, 5});
  reporter->Assign(types[3], TensorType(oshape, cls_prob->dtype));
  return true;
}
// QNN Multiplication operator.
Expr MakeQnnCSIProposal(Expr cls_prob, Expr bbox_pred, Expr im_info, Array<IndexExpr> scales,
                        Array<IndexExpr> ratios, int feature_stride, double threshold,
                        int rpn_pre_nms_top_n, int rpn_post_nms_top_n, int rpn_min_size,
                        bool iou_loss, DataType out_dtype, Array<Array<IndexExpr>> q_params,
                        String layer_name) {
  auto attrs = make_object<QnnCSIProposalAttrs>();
  attrs->scales = std::move(scales);
  attrs->ratios = std::move(ratios);
  attrs->feature_stride = feature_stride;
  attrs->threshold = threshold;
  attrs->rpn_pre_nms_top_n = rpn_pre_nms_top_n;
  attrs->rpn_post_nms_top_n = rpn_post_nms_top_n;
  attrs->rpn_min_size = rpn_min_size;
  attrs->iou_loss = iou_loss;
  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.proposal");
  return Call(op, {cls_prob, bbox_pred, im_info}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.proposal")
    .describe(R"code(Generate region proposals via RPN.

 - **cls_prob**: 4-D with shape [batch, 2 * num_anchors, height, width].
 - **bbox_pred**: 4-D with shape [batch, 4 * num_anchors, height, width].
 - **im_info**: 2-D with shape [batch, 3].
 - **out**: 2-D with shape [batch * rpn_post_nms_top_n, 5].
 )code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIProposalAttrs>()
    .set_num_inputs(3)
    .add_argument("cls_prob", "Tensor", "Score of how likely proposal is object")
    .add_argument("bbox_pred", "Tensor", "BBox predicted deltas from anchors for proposals")
    .add_argument("im_info", "Tensor", "Image size and scale")
    .set_support_level(11)
    .add_type_rel("QnnCSIProposalRel", QnnCSIProposalRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIProposal").set_body_typed(MakeQnnCSIProposal);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
