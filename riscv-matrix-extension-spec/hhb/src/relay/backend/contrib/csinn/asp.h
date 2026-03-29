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
 * \file src/relay/backend/contrib/csinn/light.h
 * \brief The base class for light.
 */
#ifndef TVM_RELAY_BACKEND_CONTRIB_CSINN_ASP_H_
#define TVM_RELAY_BACKEND_CONTRIB_CSINN_ASP_H_

#include <string>
#include <vector>

#include "gref.h"

namespace tvm {
namespace relay {
namespace contrib {
namespace csinn {

class ASPQuantCalculator : public QuantCalculator {
 public:
  void GetAsymScale(float min_value, float max_value, int bits, Qinfo* qinfo, string dtype);
};

class CodegenASP : public CodegenHGref {
 public:
  CodegenASP() : CodegenHGref() {
    base_dtype_ = "CSINN_DTYPE_INT8";
    target_op_list = {"qnn.csi.conv2d", "qnn.csi.dense", "qnn.csi.avgpool2d", "qnn.csi.maxpool2d"};
    auto ctx = transform::PassContext::Current();
    auto opt = ctx->GetConfig<CSINNConfig>("relay.ext.csinn.options");
    if (!opt.defined()) {
      opt = AttrsWithDefaultValues<CSINNConfig>();
    }
    auto opt_cfg = opt.value();
    structed_sparsity = opt_cfg->structed_sparsity;
    kernel_parallel = opt_cfg->kernel_parallel;
    if (kernel_parallel != 0 && kernel_parallel != 1 && kernel_parallel != 16 &&
        kernel_parallel != 32) {
      LOG(ERROR) << "Error parallel for ASP: " << kernel_parallel;
    }
  }
  virtual ~CodegenASP() {}

  virtual CSINNVarTensor* CreateTensor(string name, string data, std::vector<int> shape,
                                       QuantParams quant_params, string dtype);
  virtual void params_common_setup(std::ostringstream& decl, const CallNode* call, string op_name,
                                   string params_name, string layer_name, string layout);
  virtual CSIConstant* CastParams(CSIConstant* data, string target_dtype, QuantParams* quant_params,
                                  bool depthwise_kernel);
  void create_sparse_mask(CSIConstant* data, QuantParams quant_params, int size);
  void setup_sparse_index(CSIConstant* data);
  void merge_sparse_kernel(CSIConstant* data);
  void depth_fill(CSIConstant* cst, std::vector<int>* shape);
  void convert_constant(CSIConstant* cst, const std::vector<int>& shape);
  void malloc_buf(string out, int out_size) {}
  void EmitSessionSetup();
  void phase1() final;
  void ModelBinarySave() {}
  string get_ccode(void);
  void CreateBiasTensor(CSINNOP* op, const CallNode* call, CSIConstant* data, string name,
                        Array<Array<IndexExpr>> q_params, bool* fuse_zp, string const_kind);
  void SessionRunMode() { func_def_.OneLine("sess->base_run_mode = CSINN_RM_CPU_GRAPH;"); }
  std::string structed_sparsity;
  int kernel_parallel;
};

}  // namespace csinn
}  // namespace contrib
}  // namespace relay
}  // namespace tvm
#endif  // TVM_RELAY_BACKEND_CONTRIB_CSINN_ASP_H_
