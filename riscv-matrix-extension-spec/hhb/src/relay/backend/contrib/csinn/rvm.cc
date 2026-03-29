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
 * \file src/relay/backend/contrib/csinn/rvm.cc
 * \brief Implementation of CSINN rvm codegen APIs.
 */

#include "rvm.h"

#include <string>

using namespace tvm::relay::qnn;
namespace tvm {
namespace relay {
namespace contrib {
namespace csinn {

CSIConstant* CodegenRVM::CastParams(CSIConstant* data, string target_dtype,
                                     QuantParams* quant_params, bool depthwise_kernel) {
  Qinfo* q_infos = quant_params->qinfo;
  int q_size = quant_params->q_size;

  CSIConstant* output = new CSIConstant(target_dtype, data->get_shape());
  output->mtype = CSINN_MEM_TYPE_CPU_ALIGNED;
  output->set_align(16);
  if (data->get_dtype() == target_dtype || target_dtype == "float") {
    return data;
  } else {
    float* input_data = GetFloatData(data);
    output->set_name(data->get_name());
    int size = data->element_number();
    int inner_size = size / q_size;
    if (target_dtype == "int8_t") {
      if ((layout_ == "NHWC") && depthwise_kernel) {
        Axis3Cast(data, output, q_infos, target_dtype, q_size, inner_size);
      } else {
        Axis0Cast(data, output, q_infos, target_dtype, q_size, inner_size);
      }
    } else if (target_dtype == "float16") {
      int16_t* out = reinterpret_cast<int16_t*>(output->get_data_buf());
      for (int i = 0; i < size; i++) {
        int16_t out_ = float32_to_float16(input_data[i]);
        out[i] = out_;
      }
    } else {
      LOG(ERROR) << "RVM get error dtype:" << target_dtype;
    }
    free(input_data);
  }
  return output;
}

void CodegenRVM::Conv2d(const CallNode* call, string op_name) {
  std::ostringstream decl;
  const auto* attr = call->attrs.as<QnnCSIConv2DAttrs>();
  CHECK(attr);

  CHECK(call->args.size() == 3) << "Conv2d expects 3 args";

  CSINNOP* op = new CSINNOP;

  /* Make function call with arguments start */
  decl << "(";

  // check for depthwise
  auto ishape = call->args[0]->get_shape();
  auto wshape = call->args[1]->get_shape();
  auto bshape = call->args[2]->get_shape();

  bool depthwise_kernel = is_depthwise(ishape, wshape, attr->groups, layout_);

  /* Emit_ input tensor */
  visit(call->args[0]);
  CHECK(out_.size() == 1) << "Every args expects a single out_";

  string params_name = "params_" + to_string(buf_idx_);
  string complete_name = get_complete_layer_name(op_name, attr->layer_name.c_str());
  op->set_name(complete_name);

  auto input_qinfo = GetCallOPQuant(call, 0);
  string input_name = CreateInputTensor(op, decl, call, 0, input_qinfo);

  /* Emit output tensor */
  auto output_qinfo = GetCallOPQuant(call, 3);
  string output_name = CreateOutputTensor(op, decl, call, output_qinfo);

  collect_quant_info(complete_name, attr->q_params, 3);

  /* Emit kernel tensor */
  visit(call->args[1]);
  CHECK(constant_.size() == 1) << "Every args expects a single constant_";

  auto kernel = constant_[0];
  string kernel_name = "kernel_" + to_string(buf_idx_);

  auto kernel_qinfo = GetCallOPQuant(call, 1);
  CreateConstantTensor(op, kernel, kernel_name, wshape, kernel_qinfo, depthwise_kernel);

  bool gemm_kernel = is_gemm_kernel(depthwise_kernel, op);

  decl << ", " << kernel_name;

  /* Emit bias tensor */
  visit(call->args[2]);
  CHECK(constant_.size() == 1) << "Every args expects a single constant_";

  auto bias = constant_[0];
  string bias_name = "bias_" + to_string(buf_idx_);
  bool fuse_zp = false;
  CreateBiasTensor(op, call, bias, bias_name, attr->q_params, &fuse_zp,
                   depthwise_kernel ? "depthwise_bias" : "conv_bias");
  decl << ", " << bias_name;

  output2params[output_name] = complete_name;

  decl << ", " << params_name << ")";

  /* must after bias fuse zero point */
  if (gemm_kernel && mlen_) {
    CSINNConstantTensor* ct = op->get_constant(0);
    reorder_kernel(ct, attr->groups);
  }

  push_decl(op);
  if (gemm_kernel && mlen_) {
    std::ostringstream t0;
    malloc_params("csinn_conv2d_params", params_name);
    t0 << params_name << "->group = " << to_string(attr->groups);
    func_def_.PushDecl(t0);
    Array<IndexExpr> strides = attr->strides;
    t0 << params_name << "->stride_height = " << to_string(strides[0].as<IntImmNode>()->value);
    func_def_.PushDecl(t0);
    t0 << params_name << "->stride_width = " << to_string(strides[1].as<IntImmNode>()->value);
    func_def_.PushDecl(t0);
    Array<IndexExpr> dilation = attr->dilation;
    t0 << params_name << "->dilation_height = " << to_string(dilation[0].as<IntImmNode>()->value);
    func_def_.PushDecl(t0);
    t0 << params_name << "->dilation_width = " << to_string(dilation[1].as<IntImmNode>()->value);
    func_def_.PushDecl(t0);
    t0 << params_name << "->conv_extra.conv_mode = CSINN_GEMM";
    func_def_.PushDecl(t0);
    t0 << params_name << "->conv_extra.kernel_tm = csinn_alloc_tensor(sess)";
    func_def_.PushDecl(t0);
    t0 << params_name << "->conv_extra.kernel_tm->data = " << kernel_name << "->data";
    func_def_.PushDecl(t0);
    SetupPadding(params_name, attr);
  } else {
    SetupConv2dParams<QnnCSIConv2DAttrs>(params_name, attr);
  }
  if (fuse_zp) {
    std::ostringstream t0;
    t0 << params_name << "->conv_extra.fuse_zp2bias = true";
    func_def_.PushDecl(t0);
  }

  PushOutput(output_name, call, cfg->dtype_weight);

  params_common_setup(decl, call, op_name, params_name, attr->layer_name.c_str(),
                      "CSINN_LAYOUT_NCHW");
  end_stream(decl, op_name);
  FreeTensor(call->args[0], input_name);
}

}  // namespace csinn
}  // namespace contrib
}  // namespace relay
}  // namespace tvm
