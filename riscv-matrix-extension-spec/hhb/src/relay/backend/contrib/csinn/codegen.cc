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
 * \file src/relay/backend/contrib/csinn/codegen.cc
 * \brief Implementation of CSINN codegen APIs.
 */

#include "shl.h"

using namespace tvm::relay::qnn;
namespace tvm {
namespace relay {
namespace contrib {
using namespace quantize;

static Map<String, Array<Array<Array<IndexExpr>>>> quant_info;

/*!
 * \brief The CSINN codegen helper to generate wrapepr function calls of CSINN
 * libraries. The code is a CSourceModule that can be compiled separately and
 * linked together with a DSOModule.
 */
class CSINNModuleCodegen : public CSourceModuleCodegenBase {
 public:
  CSINNModuleCodegen() {}

  // Create a corresponding CSINN function for the given relay Function.
  void GenCSINNFunc(const Function& func) {
    CHECK(func.defined()) << "Input error: expect a Relay function.";

    csinn::SHL shl_backend;
    shl_backend.import_realy_expr(func->body);
    shl_backend.SetExtFuncId(backend::GetExtSymbol(func));
    shl_backend.compiler();
    code_stream_ << shl_backend.get_ccode();
    quant_info = shl_backend.ret_quant_info();
  }

  /*!
   * \brief The overridden function that will create a CSourceModule. In order
   * to compile the generated C source code, users need to specify the paths to
   * some libraries, including some TVM required and csinn specific ones. To make
   * linking simpiler, the CSINN kernels are wrapped in a TVM compatible manner
   * and live under tvm/src/runtime/contrib/csinn folder.
   *
   * \param ref An object ref that could be either a Relay function or module.
   *
   * \return The runtime module that contains C source code.
   */
  runtime::Module CreateCSourceModule(const ObjectRef& ref) override {
    if (ref->IsInstance<FunctionNode>()) {
      GenCSINNFunc(Downcast<Function>(ref));
    } else if (ref->IsInstance<IRModuleNode>()) {
      IRModule mod = Downcast<IRModule>(ref);
      for (const auto& it : mod->functions) {
        GenCSINNFunc(Downcast<Function>(it.second));
      }
    } else {
      LOG(FATAL) << "The input ref is expected to be a Relay function or module"
                 << "\n";
    }

    std::string code = code_stream_.str();
    String sym = backend::GetExtSymbol(Downcast<Function>(ref));
    Array<String> variables = {};
    // Create a CSourceModule
    const auto* pf = runtime::Registry::Get("runtime.CSourceModuleCreate");
    CHECK(pf != nullptr) << "Cannot find csource module to create the external runtime module";
    return (*pf)(code_stream_.str(), "c", Array<String>{sym}, variables);
  }

 private:
  /*!
   * \brief The code stream that prints the code that will be compiled using
   * external codegen tools.
   */
  std::ostringstream code_stream_;
  tvm::Target target_;
  string params_path_;
};

runtime::Module CSINNCompiler(const ObjectRef& ref) {
  CSINNModuleCodegen csinn;
  return csinn.CreateCSourceModule(ref);
}

Map<String, Array<Array<Array<IndexExpr>>>> CollectQuantInfo() { return quant_info; }

TVM_REGISTER_GLOBAL("relay.ext.csinn.collect_quant_info").set_body_typed(CollectQuantInfo);
TVM_REGISTER_GLOBAL("relay.ext.csinn").set_body_typed(CSINNCompiler);
TVM_REGISTER_NODE_TYPE(csinn::CSINNConfigNode);
TVM_REGISTER_PASS_CONFIG_OPTION("relay.ext.csinn.options", csinn::CSINNConfig);

}  // namespace contrib
}  // namespace relay
}  // namespace tvm
