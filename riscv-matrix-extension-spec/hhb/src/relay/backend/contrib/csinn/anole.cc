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
 * \file src/relay/backend/contrib/csinn/anole.cc
 * \brief Implementation of CSINN anole codegen APIs.
 */

#include "anole.h"

#include <map>
#include <string>
#include <vector>

using namespace tvm::relay::qnn;
namespace tvm {
namespace relay {
namespace contrib {
namespace csinn {

void CodegenAnole::EmitHeader(void) {
  func_def_.OneLine("#include <shl_ovx.h>");
  func_def_.NewLine();
}

void CodegenAnole::EmitSessionSetup(void) {
  std::ostringstream t0;
  t0 << "void *" << ext_func_id_ << "_(";
  if (multithread) {
    t0 << "char *params_base, int deviceIndex) {";
  } else {
    t0 << "char *params_base) {";
  }
  func_def_.OneLine(t0);
  func_def_.EnterScope();

  func_def_.OneLine("struct csinn_session *sess = csinn_alloc_session();");
  SessionRunMode();
  ModelBinarySave();
  t0 << "sess->base_api = " << target_name_ << ";";
  func_def_.OneLine(t0);
  t0 << "sess->base_dtype = " << base_dtype_ << ";";
  func_def_.OneLine(t0);
  if (debug_level_ == "INFO") {
    func_def_.OneLine("sess->debug_level = CSINN_DEBUG_LEVEL_INFO;");
  }
  func_def_.OneLine("csinn_session_init(sess);");

  if (multithread) {
    func_def_.OneLine("shl_ovx_set_graph_attribute(sess, deviceIndex);");
  }

  t0 << "csinn_set_input_number(" << ext_func_args_.size() << ", sess);";
  func_def_.OneLine(t0);
  t0 << "csinn_set_output_number(" << output_list_.size() << ", sess);";
  func_def_.OneLine(t0);

  func_def_.NewLine();
  for (uint32_t i = 0; i < ext_func_args_.size(); i++) {
    std::string in_name = CodegenCSINN::replace(ext_func_args_[i]->name_hint());
    std::ostringstream t1;
    t1 << "csinn_set_tensor_entry(" << in_name << ", sess)";
    func_def_.PushDecl(t1);
    t1 << "csinn_set_input(" << i << ", " << in_name << ", sess)";
    func_def_.PushDecl(t1);
  }

  func_def_.BufToCode();

  for (uint32_t i = 0; i < output_list_.size(); i++) {
    if (!output_list_[i].is_const) {
      string output_name = output_list_[i].name;
      t0 << "csinn_set_output(" << i << ", " << output_name << ", sess);";
      func_def_.OneLine(t0);
    } else {
      t0 << output_list_[i].name << "->name = "
         << "\"" << output_list_[i].name << "\";";
      func_def_.OneLine(t0);
      t0 << output_list_[i].name << "->dtype = CSINN_DTYPE_FLOAT32;";
      func_def_.OneLine(t0);
      t0 << output_list_[i].name << "->is_const = 1;";
      func_def_.OneLine(t0);
      t0 << "csinn_set_tensor_entry(" << output_list_[i].name << ", sess);";
      func_def_.OneLine(t0);
      t0 << "csinn_set_output(" << i << ", " << output_list_[i].name << ", sess);";
      func_def_.OneLine(t0);
    }
  }

  func_def_.NewLine();
  func_def_.OneLine("csinn_session_setup(sess);");
  func_def_.OneLine("return sess;");
  func_def_.ExitScope();
  func_def_.OneLine("}");
}

void CodegenAnole::EmitNBGSetup(void) {
  std::ostringstream t0;
  std::vector<string> nbg_func_;
  for (uint i = 0; i < output_list_.size(); i++) {
    if (!output_list_[i].is_const) {
      string output_name = output_list_[i].name;
      auto iter = io_nodes.find(output_name);
      if (iter == io_nodes.end()) {
        CHECK(0);
      }
      QuantParams q_params = iter->second.first;
      std::ostringstream t0;
      t0 << "csinn_set_tensor_entry(" << output_name << ", sess);";
      nbg_func_.push_back(t0.str());
      t0.str("");
      t0 << "csinn_set_output(" << i << ", " << output_name << ", sess);";
      nbg_func_.push_back(t0.str());
    }
  }
  for (uint i = 0; i < ext_func_args_.size(); i++) {
    std::string new_name = CodegenCSINN::replace(ext_func_args_[i]->name_hint());
    auto iter = io_nodes.find(new_name);
    QuantParams q_params = iter->second.first;
    string in_name = q_params.name;
    std::ostringstream t0;
    t0 << "csinn_set_tensor_entry(" << in_name << ", sess);";
    nbg_func_.push_back(t0.str());

    t0.str("");
    t0 << "csinn_set_input(" << i << ", " << in_name << ", sess);";
    nbg_func_.push_back(t0.str());
  }
  // codegen for binary graph function
  func_def_.NewLine();
  if (multithread) {
    t0 << "void *csinn_nbg(char *path, int deviceIndex) {";
  } else {
    t0 << "void *csinn_nbg(char *path) {";
  }
  func_def_.OneLine(t0);
  func_def_.EnterScope();

  // function body
  func_def_.OneLine("struct csinn_session *sess = csinn_alloc_session();");
  t0 << "sess->base_api = " << target_name_ << ";";
  func_def_.OneLine(t0);
  t0 << "sess->base_dtype = " << base_dtype_ << ";";
  func_def_.OneLine(t0);
  func_def_.OneLine("csinn_session_init(sess);");

  if (multithread) {
    func_def_.OneLine("shl_ovx_set_graph_attribute(sess, deviceIndex);");
  }

  t0 << "csinn_set_input_number(" << ext_func_args_.size() << ", sess);";
  func_def_.OneLine(t0);
  t0 << "csinn_set_output_number(" << output_list_.size() << ", sess);";
  func_def_.OneLine(t0);

  func_def_.NewLine();

  for (auto iter = io_nodes.begin(); iter != io_nodes.end(); iter++) {
    CreateGraphTensor(iter->second.first);
  }

  for (auto decl : nbg_func_) {
    func_def_.OneLine(decl);
  }

  t0 << "sess->model.bm_path = path;";
  func_def_.OneLine(t0);
  t0 << "csinn_load_binary_model(sess);";
  func_def_.OneLine(t0);
  func_def_.OneLine("return sess;");

  func_def_.ExitScope();
  func_def_.OneLine("}");
}

void CodegenAnole::visit_expr(const CallNode* call) {
  /* Get the arguments for various CSINN kernels. */
  /* QNN op */
  if (first_visit_expr) {
    first_visit_expr = false;
    output_element output;
    output.call = call;
    output_list_.push_back(output);
  }
  if (IsOp(call, "qnn.csi.add")) {
    DisoOp(call, "add");
  } else if (IsOp(call, "qnn.csi.avgpool2d")) {
    AvgPool2d(call);
  } else if (IsOp(call, "qnn.csi.bias_add")) {
    DisoOp(call, "add");
  } else if (IsOp(call, "qnn.csi.clip")) {
    Clip(call);
  } else if (IsOp(call, "qnn.csi.subtract")) {
    DisoOp(call, "sub");
  } else if (IsOp(call, "qnn.csi.div")) {
    DisoOp(call, "div");
  } else if (IsOp(call, "qnn.csi.concatenate")) {
    Concat(call);
  } else if (IsOp(call, "qnn.csi.conv2d")) {
    Conv2d(call, "conv2d");
  } else if (IsOp(call, "qnn.csi.conv2d_relu")) {
    Conv2d(call, "conv2d_relu");
  } else if (IsOp(call, "qnn.csi.conv2d_relu6")) {
    Conv2d(call, "conv2d_relu6");
  } else if (IsOp(call, "qnn.csi.deconv2d")) {
    DeConv2d(call);
  } else if (IsOp(call, "qnn.csi.dense")) {
    Dense(call);
  } else if (IsOp(call, "qnn.csi.equal")) {
    DisoOp(call, "equal");
  } else if (IsOp(call, "qnn.csi.exp")) {
    Unary(call, "exp");
  } else if (IsOp(call, "qnn.csi.flatten")) {
    Flatten(call);
  } else if (IsOp(call, "qnn.csi.global_avgpool2d")) {
    GlobalAvgPool2d(call);
  } else if (IsOp(call, "qnn.csi.global_maxpool2d")) {
    GlobalMaxPool2d(call);
  } else if (IsOp(call, "qnn.csi.leaky_relu")) {
    LeakyRelu(call);
  } else if (IsOp(call, "qnn.csi.lrn")) {
    LRN(call);
  } else if (IsOp(call, "qnn.csi.maxpool2d")) {
    MaxPool2d(call);
  } else if (IsOp(call, "qnn.csi.maxpool2d_locat")) {
    MaxPool2dLocat(call);
  } else if (IsOp(call, "qnn.csi.maxpool2d_with_argmax")) {
    Maxpool2dWithArgmax(call);
  } else if (IsOp(call, "qnn.csi.mean")) {
    Reduce(call, "mean", cfg->dtype_weight);
  } else if (IsOp(call, "qnn.csi.minimum")) {
    DisoOp(call, "minimum");
  } else if (IsOp(call, "qnn.csi.mul")) {
    DisoOp(call, "mul");
  } else if (IsOp(call, "qnn.csi.pad")) {
    Pad(call);
  } else if (IsOp(call, "qnn.csi.prelu")) {
    PRelu(call);
  } else if (IsOp(call, "qnn.csi.proposal")) {
    Proposal(call);
  } else if (IsOp(call, "qnn.csi.psroipooling")) {
    PSROIPool(call);
  } else if (IsOp(call, "qnn.csi.relu")) {
    Relu(call);
  } else if (IsOp(call, "qnn.csi.relu6")) {
    Relu6(call);
  } else if (IsOp(call, "qnn.csi.reshape")) {
    Reshape(call);
  } else if (IsOp(call, "qnn.csi.roipooling")) {
    ROIPool(call);
  } else if (IsOp(call, "qnn.csi.sigmoid")) {
    Sigmoid(call);
  } else if (IsOp(call, "qnn.csi.softmax")) {
    Softmax(call);
  } else if (IsOp(call, "qnn.csi.split")) {
    Split(call);
  } else if (IsOp(call, "qnn.csi.squeeze")) {
    Squeeze(call);
  } else if (IsOp(call, "qnn.csi.strided_slice")) {
    StridedSlice(call);
  } else if (IsOp(call, "qnn.csi.transpose")) {
    Transpose(call);
  } else if (IsOp(call, "qnn.csi.unpooling")) {
    UnPool2d(call);
  } else if (IsOp(call, "qnn.csi.upsampling")) {
    UpSampling(call);
  } else {
    std::cerr << "Anole NPU unsupported op: " << AsText(call->op, false) << "\n";
    exit(-1);
  }
}

void CodegenAnole::DisoOp(const CallNode* call, string op_name) {
  std::ostringstream decl_stream;
  std::ostringstream t0;
  CSINNOP* op = new CSINNOP;
  const auto* attr = call->attrs.as<QnnBinaryOpAttrs>();
  CHECK(attr);

  CHECK(call->args.size() == 2) << "op expects 2 args";

  // Make function call with input buffers when visiting arguments
  decl_stream << "(";

  string lhs_name, rhs_name;
  /* Emit input0 tensor */
  visit(call->args[0]);
  CHECK(out_.size() == 1) << "Every args expects a single out_";
  auto lhs_input = out_[0];
  lhs_name = CodegenCSINN::CreateInputTensor(op, decl_stream, call, 0, GetCallOPQuant(call, 0));
  decl_stream << ", ";

  /* Emit input1 tensor */
  auto input1_qinfo = GetCallOPQuant(call, 1);
  if (call->args[1].as<CallNode>() || call->args[1].as<VarNode>()) {
    visit(call->args[1]);
    CHECK(out_.size() == 1) << "Every args expects a single out_";
    auto rhs_input = out_[0];
    rhs_name = CodegenCSINN::CreateInputTensor(op, decl_stream, call, 1, input1_qinfo);

  } else {
    // add constant arg
    visit(call->args[1]);
    CHECK(constant_.size() == 1) << "Every args expects a single out_";
    auto rhs = constant_[0];
    auto lhs_shape = call->args[0]->get_shape();
    auto rhs_shape = call->args[1]->get_shape();

    rhs_name = "rhs_" + to_string(buf_idx_);
    CreateConstantTensor(op, rhs, rhs_name, rhs_shape, input1_qinfo);
    CSINNTensor* tensor = op->get_tensor(rhs_name);
    tensor->tensor->dtype = CSINN_DTYPE_UINT8;
    t0 << "csinn_set_tensor_entry(" << rhs_name << ", sess)";
    tensor->append_str(t0);
    decl_stream << rhs_name;
  }

  /* Emit output tensor */
  string output_name = CreateOutputTensor(op, decl_stream, call, GetCallOPQuant(call, 2));

  string params_name = "params_" + to_string(buf_idx_);
  decl_stream << ", " << params_name << ")";
  push_decl(op);
  malloc_params("csinn_diso_params", params_name);
  PushOutput(output_name, call);
  buf_idx_++;
  params_common_setup(decl_stream, call, op_name, params_name, attr->layer_name.c_str(),
                      "CSINN_LAYOUT_NCHW");
  end_stream(decl_stream, op_name);
}

void CodegenAnole::Flatten(const CallNode* call) {
  std::ostringstream decl_stream;
  std::ostringstream t0;
  CSINNOP* op = new CSINNOP;
  const auto* attr = call->attrs.as<QnnCSIUnaryAttrs>();

  string callback;
  if (CheckOutput(call) != -1) {
    callback = "shl_ovx_flatten_tail";
  } else {
    callback = "shl_ovx_flatten";
  }

  SisoOp<QnnCSIUnaryAttrs>(op, decl_stream, call, attr);

  string params_name = "params_" + to_string(buf_idx_);
  decl_stream << ", " << params_name << ")";
  push_decl(op);
  malloc_params("csinn_flatten_params", params_name);
  t0 << params_name << "->base.layout = CSINN_LAYOUT_NCHW";
  func_def_.PushDecl(t0);
  t0 << params_name << "->base.api = CSINN_ANOLE";
  func_def_.PushDecl(t0);
  t0 << "struct csinn_callback *" << params_name << "_cb = " << params_name << "->base.cb";
  func_def_.PushDecl(t0);
  t0 << params_name << "_cb->est = " << callback;
  func_def_.PushDecl(t0);

  end_stream(decl_stream, "flatten");
}

void CodegenAnole::Squeeze(const CallNode* call) {
  std::ostringstream decl;
  std::ostringstream t0;
  CSINNOP* op = new CSINNOP;
  const auto* attr = call->attrs.as<QnnCSISqueezeAttrs>();
  string callback;
  if (CheckOutput(call) != -1) {
    callback = "shl_ovx_squeeze_tail";
  } else {
    callback = "shl_ovx_squeeze";
  }

  SisoOp<QnnCSISqueezeAttrs>(op, decl, call, attr);

  string squeeze_axis_name = "squeeze_aixs_" + to_string(buf_idx_);
  int32_t squeeze_axis_dim_num = attr->axis.size();
  t0 << "int32_t " << squeeze_axis_name << "[" << squeeze_axis_dim_num << "] = {";
  for (int i = 0; i < squeeze_axis_dim_num; i++) {
    t0 << to_string(attr->axis[i].as<IntImmNode>()->value) << ", ";
  }
  t0 << "}";
  func_def_.PushDecl(t0);

  string params_name = "params_" + to_string(buf_idx_);
  decl << ", " << params_name << ")";
  push_decl(op);
  malloc_params("csinn_squeeze_params", params_name);
  t0 << params_name << "->base.layout = CSINN_LAYOUT_NCHW";
  func_def_.PushDecl(t0);
  t0 << params_name << "->base.api = CSINN_ANOLE";
  func_def_.PushDecl(t0);
  t0 << "struct csinn_callback *" << params_name << "_cb = " << params_name << "->base.cb";
  func_def_.PushDecl(t0);
  t0 << params_name << "_cb->est = " << callback;
  func_def_.PushDecl(t0);
  t0 << params_name << "->axis = " << squeeze_axis_name;
  func_def_.PushDecl(t0);
  t0 << params_name << "->axis_num = " << squeeze_axis_dim_num;
  func_def_.PushDecl(t0);
  end_stream(decl, "squeeze");
}

void CodegenAnole::Reshape(const CallNode* call) {
  std::ostringstream decl;
  std::ostringstream t0;
  CSINNOP* op = new CSINNOP;
  const auto* attr = call->attrs.as<QnnCSIReshapeAttrs>();
  string callback;
  if (CheckOutput(call) != -1) {
    callback = "shl_ovx_reshape_tail";
  } else {
    callback = "shl_ovx_reshape";
  }

  SisoOp<QnnCSIReshapeAttrs>(op, decl, call, attr);

  auto out_shape = call->get_shape();
  string new_shape_name = "shape_" + to_string(buf_idx_);
  int32_t new_shape_dim_num = out_shape.size();
  t0 << "int32_t " << new_shape_name << "[" << new_shape_dim_num << "] = {";
  for (int i = 0; i < new_shape_dim_num; i++) {
    t0 << to_string(out_shape[i]) << ", ";
  }
  t0 << "}";
  func_def_.PushDecl(t0);

  string params_name = "params_" + to_string(buf_idx_);
  decl << ", " << params_name << ")";
  push_decl(op);
  malloc_params("csinn_reshape_params", params_name);
  t0 << params_name << "->base.layout = CSINN_LAYOUT_NCHW";
  func_def_.PushDecl(t0);
  t0 << params_name << "->base.api = CSINN_ANOLE";
  func_def_.PushDecl(t0);
  t0 << "struct csinn_callback *" << params_name << "_cb = " << params_name << "->base.cb";
  func_def_.PushDecl(t0);
  t0 << params_name << "_cb->est = " << callback;
  func_def_.PushDecl(t0);
  t0 << params_name << "->shape = " << new_shape_name;
  func_def_.PushDecl(t0);
  t0 << params_name << "->shape_num = " << new_shape_dim_num;
  func_def_.PushDecl(t0);

  end_stream(decl, "reshape");
}

void CodegenAnole::ModelBinarySave() {
  std::ostringstream t0;
  t0 << "sess->model.bm_path = \"network.nb\";";
  func_def_.OneLine(t0);
  if (model_save == "run_only") {
    t0 << "sess->model.save_mode = CSINN_RUN_ONLY;";
  } else if (model_save == "save_only") {
    t0 << "sess->model.save_mode = CSINN_SAVE_ONLY;";
  } else if (model_save == "save_and_run") {
    t0 << "sess->model.save_mode = CSINN_SAVE_AND_RUN;";
  } else {
    std::cerr << "Unsupport for model save_mode type: " << model_save << "\n";
    exit(-1);
  }
  func_def_.OneLine(t0);
}

}  // namespace csinn
}  // namespace contrib
}  // namespace relay
}  // namespace tvm
