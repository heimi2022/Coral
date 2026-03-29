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
 * \file src/relay/backend/contrib/csinn/ref.cc
 * \brief Implementation of CSINN codegen APIs.
 */

#include "i805.h"

using namespace tvm::relay::qnn;
namespace tvm {
namespace relay {
namespace contrib {
namespace csinn {

void CodegenI805::GenerateBackendCFunc(const string& func_name, const Array<Var>& args,
                                       const output_element& out) {
  func_def_.NewLine();
  std::ostringstream t0;
  string in_dtype = cfg->dtype_input;
  string weight_dtype = cfg->dtype_weight;
  func_def_.NewLine();
  t0 << "int " << func_name << "_runtime_wrapper_(";
  t0 << "int64_t* arg_value, ";
  t0 << "int64_t* arg_type, ";
  t0 << "int64_t* arg_size, ";
  t0 << "int64_t* ret_vale, int64_t* ret_type_code" << args.size() << ") {";
  func_def_.OneLine(t0);

  func_def_.EnterScope();
  func_def_.OneLine("char** inputs = (char**)(uintptr_t)arg_value[0];");
  func_def_.OneLine("char** outputs = (char**)(uintptr_t)arg_value[1];");
  func_def_.OneLine("char *params_base = (char *)(uintptr_t)arg_value[2];");

  string out_dtype = GetCSINNDtype(weight_dtype);

  for (uint i = 0; i < args.size(); i++) {
    const auto& dtype_str = GetDtypeString(args[i]);
    std::string new_name = replace(args[i]->name_hint());
    t0 << weight_dtype << "* __" << new_name << " = (" << weight_dtype << "*)inputs[" << i << "];";
    func_def_.OneLine(t0);
  }

  for (uint i = 0; i < output_list_.size(); i++) {
    t0 << weight_dtype << " *out_" << i << " = (" << weight_dtype << " *)outputs[" << i << "];";
    func_def_.NewLine();
    func_def_.OneLine(t0);
  }

  t0 << func_name << "_(";
  for (const auto& arg : args) {
    std::string new_name = replace(arg->name_hint());
    t0 << "__" << new_name << ", ";
  }

  for (uint i = 0; i < output_list_.size(); i++) {
    t0 << "out_" << i << ", ";
  }
  t0 << "params_base);\n";
  func_def_.OneLine(t0);
  func_def_.OneLine("return 0;");
  func_def_.ExitScope();
  func_def_.OneLine("}");
}

}  // namespace csinn
}  // namespace contrib
}  // namespace relay
}  // namespace tvm
