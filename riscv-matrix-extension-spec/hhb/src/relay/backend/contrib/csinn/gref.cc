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
 * \file src/relay/backend/contrib/csinn/gref.cc
 * \brief Implementation of CSINN gref codegen APIs.
 */

#include "gref.h"

#include <algorithm>
#include <string>
#include <vector>

using namespace tvm::relay::qnn;
namespace tvm {
namespace relay {
namespace contrib {
namespace csinn {

string CodegenGref::get_ccode(void) {
  EmitVersion();
  EmitHeader();
  EmitSessionSetup();
  EmitSessionRun();
  EmitNBGSetup();
  DumpConstant();
  return func_def_.str();
}

void CodegenGref::EmitNBGSetup(void) {
  std::ostringstream t0;
  std::vector<string> nbg_func_;
  int output_index = 0;
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
      t0 << "csinn_set_output(" << output_index++ << ", " << output_name << ", sess);";
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
  t0 << "void *csinn_nbg(char *path) {";
  func_def_.OneLine(t0);
  func_def_.EnterScope();

  // function body
  func_def_.OneLine("struct csinn_session *sess = csinn_alloc_session();");
  t0 << "sess->base_api = " << target_name_ << ";";
  func_def_.OneLine(t0);
  t0 << "sess->base_dtype = " << base_dtype_ << ";";
  func_def_.OneLine(t0);
  func_def_.OneLine("csinn_session_init(sess);");

  t0 << "csinn_set_input_number(" << ext_func_args_.size() << ", sess);";
  func_def_.OneLine(t0);
  t0 << "csinn_set_output_number(" << output_index << ", sess);";
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

// bool CodegenGref::IsIntegralOrNot(string const_kind) {
//   std::vector<string> per_channel = {"conv_kernel", "dense_kernel", "depthwise_kernel",
//                                      "conv_bias",   "dense_bias",   "depthwise_bias"};
//   if ((cfg->quantization_scheme == "CSINN_QUANT_INT8_ASYM_W_SYM" ||
//        cfg->quantization_scheme == "CSINN_QUANT_INT4_ASYM_W_SYM") &&
//       !is_contain_item<string>(per_channel, const_kind)) {
//     return true;
//   }
//   return false;
// }

}  // namespace csinn
}  // namespace contrib
}  // namespace relay
}  // namespace tvm
