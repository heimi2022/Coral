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
 * \file src/relay/backend/contrib/csinn/shl.cc
 * \brief Implementation of SHL backend.
 */

#include "shl.h"

namespace tvm {
namespace relay {
namespace contrib {
namespace csinn {

template <typename T>
void SHL::target_build(T* builder) {
  builder->compile(expr);
  code_stream_ = builder->get_ccode();
  quant_info = builder->ret_quant_info();
}

void SHL::compiler(void) {
  auto ctx = transform::PassContext::Current();
  auto cfg = ctx->GetConfig<CSINNConfig>("relay.ext.csinn.options");
  if (!cfg.defined()) {
    cfg = AttrsWithDefaultValues<CSINNConfig>();
  }
  String device = cfg.value()->target;
  bool auto_quant = cfg.value()->auto_hybrid_quantization;

  if (device == "anole") {
    CodegenAnole* builder = new CodegenAnole;
    target_build<CodegenAnole>(builder);
  } else if (device == "light" && !auto_quant) {
    CodegenLight* builder = new CodegenLight;
    target_build<CodegenLight>(builder);
  } else if (device == "hlight" || (device == "light" && auto_quant)) {
    CodegenHLight* builder = new CodegenHLight;
    target_build<CodegenHLight>(builder);
  } else if (device == "asp") {
    CodegenASP* builder = new CodegenASP;
    target_build<CodegenASP>(builder);
  } else if (device == "e907") {
    CodegenE907* builder = new CodegenE907;
    target_build<CodegenE907>(builder);
  } else if (device == "c906") {
    CodegenC906* builder = new CodegenC906;
    target_build<CodegenC906>(builder);
  } else if (device == "rvm") {
    CodegenRVM* builder = new CodegenRVM;
    target_build<CodegenRVM>(builder);
  } else if (device == "c908") {
    CodegenC908* builder = new CodegenC908;
    target_build<CodegenC908>(builder);
  } else if (device == "i805") {
    CodegenI805* builder = new CodegenI805;
    target_build<CodegenI805>(builder);
  } else {
    CodegenRef* builder = new CodegenRef;
    builder->SetExtFuncId(ext_func_id_);
    target_build<CodegenRef>(builder);
  }
}

}  // namespace csinn
}  // namespace contrib
}  // namespace relay
}  // namespace tvm
