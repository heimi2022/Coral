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
 * \file src/relay/backend/contrib/csinn/light.cc
 * \brief Implementation of CSINN light codegen APIs.
 */

#include "asp.h"

#include <algorithm>
#include <memory>

#include "data_rearrange.h"

using namespace tvm::relay::qnn;
namespace tvm {
namespace relay {
namespace contrib {
namespace csinn {

CSINNVarTensor* CodegenASP::CreateTensor(string name, string data, std::vector<int> shape,
                                         QuantParams quant_params, string dtype) {
  CSINNVarTensor* tensor = new CSINNVarTensor;
  tensor->name = name.c_str();
  SetDim(tensor, name, shape);
  tensor->tensor->quant_channel = quant_params.q_size;
  tensor->tensor->dtype = GetCSINNTensorDtype(dtype);
  tensor->tensor->layout = GetCSINNTensorActLayout(shape);
  tensor->set_quant(quant_params);
  return tensor;
}

void CodegenASP::params_common_setup(std::ostringstream& decl, const CallNode* call, string op_name,
                                     string params_name, string layer_name, string layout = "") {
  std::ostringstream t0;
  t0 << params_name << "->base.layout = CSINN_LAYOUT_NHWC";
  func_def_.PushDecl(t0);
  t0 << params_name << "->base.name = "
     << "\"" << op_name + "_" + layer_name << "\"";
  func_def_.PushDecl(t0);
  if (InOpList(call)) {
    t0 << params_name << "->base.api = CSINN_ASP";
    func_def_.PushDecl(t0);
  }
  t0 << "csinn_" << op_name << "_init" << decl.str();
  func_def_.PushDecl(t0);
}

void CodegenASP::create_sparse_mask(CSIConstant* cst, QuantParams quant_params, int size) {
  int idx_max, mask_max;

  if (structed_sparsity == "asp4:2") {
    idx_max = 2;
    mask_max = 2;
    cst->sparse.type = CSINN_MEM_TYPE_ASP42;
  } else if (structed_sparsity == "asp4:1") {
    idx_max = 1;
    mask_max = 3;
    cst->sparse.type = CSINN_MEM_TYPE_ASP41;
  } else {
    return;
  }

  int outer = quant_params.shape[0];
  int inner = quant_params.shape[1];
  for (uint i = 2; i < quant_params.shape.size(); i++) {
    inner *= quant_params.shape[i];
  }
  if (inner % 4) {
    LOG(ERROR) << "get error sparse size";
  }
  int element_size = outer * inner;
  uint8_t* smask = reinterpret_cast<uint8_t*>(malloc(element_size));
  if (cst->get_dtype() == "float") {
    float* data_buf = reinterpret_cast<float*>(cst->get_data_buf());

    /* mask_max = 2 or 3: for 4:2 or 4:1 mask */
    for (int i = 0; i < element_size; i += 4) {
      int mask_num = 0;
      if (data_buf[i] == 0) {
        smask[i] = 0;
        mask_num++;
      } else {
        smask[i] = 0xff;
      }
      if (data_buf[i + 1] == 0) {
        smask[i + 1] = 0;
        mask_num++;
      } else {
        smask[i + 1] = 0xff;
      }
      if (data_buf[i + 2] == 0 && mask_num < mask_max) {
        smask[i + 2] = 0;
        mask_num++;
      } else {
        smask[i + 2] = 0xff;
      }
      if (data_buf[i + 3] == 0 && mask_num < mask_max) {
        smask[i + 3] = 0;
        mask_num++;
      } else {
        smask[i + 3] = 0xff;
      }
    }
  } else {
    LOG(ERROR) << "sparse error dtype:" << cst->get_dtype();
  }
  /* mask for idx */
  int8_t* sidx = reinterpret_cast<int8_t*>(malloc(element_size / 4 * idx_max));

  if (idx_max == 1) {
    for (int i = 0; i < element_size; i += 4) {
      if (smask[i] == 0xff) {
        sidx[i / 4] = 0x0;
      } else if (smask[i + 1] == 0xff) {
        sidx[i / 4] = 0x1;
      } else if (smask[i + 2] == 0xff) {
        sidx[i / 4] = 0x2;
      } else if (smask[i + 3] == 0xff) {
        sidx[i / 4] = 0x3;
      } else {
        LOG(ERROR) << "sparse error mask";
      }
    }
  } else {
    /* idx_max = 2 */
    for (int i = 0; i < element_size; i += 4) {
      if (smask[i] == 0xff && smask[i + 1] == 0xff) {
        sidx[i / 2] = 0x0;
        sidx[i / 2 + 1] = 0x1;
      } else if (smask[i] == 0xff && smask[i + 2] == 0xff) {
        sidx[i / 2] = 0x0;
        sidx[i / 2 + 1] = 0x2;
      } else if (smask[i] == 0xff && smask[i + 3] == 0xff) {
        sidx[i / 2] = 0x0;
        sidx[i / 2 + 1] = 0x3;
      } else if (smask[i + 1] == 0xff && smask[i + 2] == 0xff) {
        sidx[i / 2] = 0x1;
        sidx[i / 2 + 1] = 0x2;
      } else if (smask[i + 1] == 0xff && smask[i + 3] == 0xff) {
        sidx[i / 2] = 0x1;
        sidx[i / 2 + 1] = 0x3;
      } else if (smask[i + 2] == 0xff && smask[i + 3] == 0xff) {
        sidx[i / 2] = 0x2;
        sidx[i / 2 + 1] = 0x3;
      } else {
        LOG(ERROR) << "sparse error mask";
      }
    }
  }

  cst->sparse.size = element_size / 4 * idx_max;
  cst->sparse.index = sidx;
}

void CodegenASP::setup_sparse_index(CSIConstant* cst) {
  int8_t* idx_buf = cst->sparse.index;
  int idx_size = cst->sparse.size;
  if (idx_size == 0) {
    return;
  }
  int8_t* sidx = reinterpret_cast<int8_t*>(malloc(idx_size / 4));
  for (int i = 0; i < idx_size; i += 4) {
    sidx[i / 4] = (idx_buf[i + 0] & 0x3) | ((idx_buf[i + 1] << 2) & 0xc) |
                  ((idx_buf[i + 2] << 4) & 0x30) | ((idx_buf[i + 3] << 6) & 0xc0);
  }
  free(idx_buf);
  cst->sparse.index = sidx;
  cst->sparse.size = idx_size / 4;
}

void CodegenASP::merge_sparse_kernel(CSIConstant* cst) {
  int8_t* data_buf = reinterpret_cast<int8_t*>(cst->get_data_buf());
  int8_t* idx_buf = reinterpret_cast<int8_t*>(cst->sparse.index);
  int8_t* dbuf = NULL;
  if (structed_sparsity == "asp4:2") {
    size_t alloc_size = cst->element_number() / 2;
    dbuf = reinterpret_cast<int8_t*>(malloc(alloc_size));
    for (uint i = 0; i < cst->sparse.size; i += 2) {
      if (idx_buf[i] == 0x0 && idx_buf[i + 1] == 0x1) {
        dbuf[i] = data_buf[i * 2];
        dbuf[i + 1] = data_buf[i * 2 + 1];
      } else if (idx_buf[i] == 0x0 && idx_buf[i + 1] == 0x2) {
        dbuf[i] = data_buf[i * 2];
        dbuf[i + 1] = data_buf[i * 2 + 2];
      } else if (idx_buf[i] == 0x0 && idx_buf[i + 1] == 0x3) {
        dbuf[i] = data_buf[i * 2];
        dbuf[i + 1] = data_buf[i * 2 + 3];
      } else if (idx_buf[i] == 0x1 && idx_buf[i + 1] == 0x2) {
        dbuf[i] = data_buf[i * 2 + 1];
        dbuf[i + 1] = data_buf[i * 2 + 2];
      } else if (idx_buf[i] == 0x1 && idx_buf[i + 1] == 0x3) {
        dbuf[i] = data_buf[i * 2 + 1];
        dbuf[i + 1] = data_buf[i * 2 + 3];
      } else if (idx_buf[i] == 0x2 && idx_buf[i + 1] == 0x3) {
        dbuf[i] = data_buf[i * 2 + 2];
        dbuf[i + 1] = data_buf[i * 2 + 3];
      } else {
        LOG(ERROR) << "sparse merge error";
      }
    }
    cst->set_byte_size(alloc_size);
  } else if (structed_sparsity == "asp4:1") {
    size_t alloc_size = cst->element_number() / 4;
    dbuf = reinterpret_cast<int8_t*>(malloc(alloc_size));
    for (uint i = 0; i < cst->sparse.size; i++) {
      dbuf[i] = data_buf[i * 4 + idx_buf[i]];
    }
    cst->set_byte_size(alloc_size);
  } else {
    LOG(ERROR) << "merge sparse error";
  }
  free(data_buf);
  cst->set_data_buf(dbuf);
}

void CodegenASP::depth_fill(CSIConstant* cst, std::vector<int>* shape) {
  if (cst->layout == CSINN_LAYOUT_O32I32 || cst->layout == CSINN_LAYOUT_O32HWI32 ||
      cst->layout == CSINN_LAYOUT_O16I16 || cst->layout == CSINN_LAYOUT_O16HWI16) {
    /* TODO: output channel fill */
    return;
  }
  int dim = shape->size() - 1;
  int depth = (*shape)[dim];
  int outer = 1;
  for (uint i = 0; i < shape->size() - 1; i++) {
    outer *= (*shape)[i];
  }
  int ndepth = depth;
  if (cst->layout == CSINN_LAYOUT_O32I32 || cst->layout == CSINN_LAYOUT_O32HWI32 ||
      cst->layout == CSINN_LAYOUT_O16I16 || cst->layout == CSINN_LAYOUT_O16HWI16) {
    /* TODO: output channel fill */
  } else {
    /* depth align to 32 */
    ndepth = (depth + 31) / 32 * 32;
  }
  int nsize = ndepth * outer;
  int8_t* nbuf = static_cast<int8_t*>(calloc(nsize, 1));
  int8_t* obuf = static_cast<int8_t*>(cst->get_data_buf());
  for (int i = 0; i < outer; i++) {
    memcpy(nbuf + ndepth * i, obuf + depth * i, depth);
  }
  free(cst->get_data_buf());
  cst->set_data_buf(nbuf);
  cst->set_byte_size(nsize);
  (*shape)[dim] = ndepth;
}

void CodegenASP::convert_constant(CSIConstant* cst, const std::vector<int>& shape) {
  int8_t* data = reinterpret_cast<int8_t*>(malloc(cst->byte_size()));
  std::vector<int> sshape = shape;
  int ldim = sshape[sshape.size() - 1];
  if (structed_sparsity == "asp4:2") {
    sshape[sshape.size() - 1] = ldim / 2;
  } else if (structed_sparsity == "asp4:1") {
    sshape[sshape.size() - 1] = ldim / 4;
  }

  int align = 1;

  if (cst->layout == CSINN_LAYOUT_O32I32 || cst->layout == CSINN_LAYOUT_O32HWI32) {
    align = 32;
  } else if (cst->layout == CSINN_LAYOUT_O16I16 || cst->layout == CSINN_LAYOUT_O16HWI16) {
    align = 16;
  }

  layout_to_OxHWIx(data, cst->get_data_buf(), sshape, align);
  cst->set_data_buf(data);
  if (cst->sparse.size) {
    ldim = sshape[sshape.size() - 1];
    if (ldim % 4) {
      LOG(ERROR) << "kernel get error sparse size";
    }
    sshape[sshape.size() - 1] = ldim / 4;

    int8_t* idx = reinterpret_cast<int8_t*>(malloc(cst->sparse.size));
    layout_to_OxHWIx(idx, cst->sparse.index, sshape, align);
    cst->sparse.index = idx;
  }
}

CSIConstant* CodegenASP::CastParams(CSIConstant* data, string target_dtype,
                                    QuantParams* quant_params, bool depthwise_kernel) {
  Qinfo* q_infos = quant_params->qinfo;
  int q_size = quant_params->q_size;

  CSIConstant* output = new CSIConstant(target_dtype, data->get_shape());
  if (data->get_dtype() == target_dtype) {
    return data;
  } else {
    output->set_name(data->get_name());
    int size = data->element_number();
    int inner_size = size / q_size;
    create_sparse_mask(data, *quant_params, size);
    if (target_dtype == "int8_t" || target_dtype == "uint8_t") {
      output->sparse = data->sparse;
      if ((layout_ == "NHWC") && depthwise_kernel) {
        Axis3Cast(data, output, q_infos, target_dtype, q_size, inner_size);
      } else {
        Axis0Cast(data, output, q_infos, target_dtype, q_size, inner_size);
      }
    } else {
      LOG(ERROR) << "get error dtype:" << target_dtype;
    }
    merge_sparse_kernel(output);
    setup_sparse_index(output);
    std::vector<int> sshape = quant_params->shape;
    if (kernel_parallel == 32 || kernel_parallel == 0) {
      if (data->layout == CSINN_LAYOUT_OI) {
        output->layout = CSINN_LAYOUT_O32I32;
      } else if (data->layout == CSINN_LAYOUT_OHWI) {
        output->layout = CSINN_LAYOUT_O32HWI32;
      }
    } else if (kernel_parallel == 16) {
      /* TODO: 16 */
      if (data->layout == CSINN_LAYOUT_OI) {
        output->layout = CSINN_LAYOUT_O16I16;
      } else if (data->layout == CSINN_LAYOUT_OHWI) {
        output->layout = CSINN_LAYOUT_O16HWI16;
      }
    }
    depth_fill(output, &sshape);
    quant_params->shape = sshape;
    /* TODO: use unify call */
    convert_constant(output, sshape);
  }
  /* TODO: set real align */
  output->set_align(32);
  return output;
}

void ASPQuantCalculator::GetAsymScale(float min_value, float max_value, int bits, Qinfo* qinfo,
                                      string dtype) {
  int valid_range = std::pow(2, bits) - 2;
  max_value = std::max(max_value, 0.0f);
  min_value = std::min(min_value, 0.0f);
  if (dtype == "uint8_t") {
    qinfo->scale = (max_value - min_value) / valid_range;
    if (qinfo->scale == 0) {
      qinfo->scale = std::abs(max_value);
    }
    qinfo->zero_point = std::min(
        valid_range, static_cast<int>(std::max(0.0f, std::round(0 - min_value / qinfo->scale))));
  } else if (dtype == "int8_t") {
    qinfo->scale = (max_value - min_value) / valid_range;
    if (qinfo->scale == 0) {
      qinfo->scale = 1;
    }
    float low_bound = -std::pow(2, bits - 1) + 1;
    int high_bound = std::pow(2, bits - 1) - 1;
    qinfo->zero_point = std::min(
        high_bound,
        static_cast<int>(std::max(low_bound, std::round(-127 - min_value / qinfo->scale))));
  } else {
    LOG(ERROR) << "get error dtype:" << dtype;
  }
}

void CodegenASP::CreateBiasTensor(CSINNOP* op, const CallNode* call, CSIConstant* data, string name,
                                  Array<Array<IndexExpr>> q_params, bool* fuse_zp,
                                  string const_kind) {
  bool depthwise_kernel = const_kind == "depthwise_bias" ? true : false;
  std::shared_ptr<std::vector<int32_t>> new_bias;
  if ((cfg->quantization_scheme == "CSINN_QUANT_INT8_ASYM_W_SYM" ||
       cfg->quantization_scheme == "CSINN_QUANT_INT4_ASYM_W_SYM") &&
      cfg->fuse_zp2bias) {
    *fuse_zp = true;
    if (depthwise_kernel) {
      const_kind = "input;depthwise_kernel;depthwise_bias;out";
    } else {
      const_kind = "input;conv_kernel;conv_bias;out";
    }
    QuantParams* base_q_params = GetQuantParams(q_params, cfg, const_kind);
    new_bias = FuseZpToBias(data, op, call, base_q_params, depthwise_kernel);
  }

  auto bshape = call->args[2]->get_shape();
  auto wshape = call->args[1]->get_shape();
  if (*fuse_zp) {
    if (bshape.size() == 0) {
      data->realloc_data_buf(new_bias->size() * 4);
      bshape.push_back(new_bias->size());
    }
    float* data_buf = static_cast<float*>(data->get_data_buf());
    std::copy(new_bias->begin(), new_bias->end(), data_buf);
    data->set_dtype("int32_t");
  }

  QuantParams* in_q_params = GetCallOPQuant(call, 0);
  QuantParams* weight_q_params = GetCallOPQuant(call, 1);
  QuantParams* bias_q_params = GetCallOPQuant(call, 2);

  if (bshape.size() == 0) {
    data->realloc_data_buf(wshape[0] * 4);
    bshape.push_back(wshape[0]);
  }

  CreateConstantTensor(op, data, name, bshape, cfg->dtype_activation, in_q_params, weight_q_params,
                       bias_q_params);
}

void CodegenASP::EmitSessionSetup(void) {
  std::ostringstream t0;
  t0 << "void *" << ext_func_id_ << "_(";
  t0 << "char *params_base) {";
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

  int output_index = 0;
  // emit normal outputs
  for (uint32_t i = 0; i < output_list_.size(); i++) {
    if (!output_list_[i].is_const) {
      string output_name = output_list_[i].name;
      t0 << "csinn_set_output(" << output_index++ << ", " << output_name << ", sess);";
      func_def_.OneLine(t0);
    }
  }

  // emit constant outputs
  for (uint32_t i = 0; i < output_list_.size(); i++) {
    if (output_list_[i].is_const) {
      t0 << output_list_[i].name << "->name = "
         << "\"" << output_list_[i].name << "\";";
      func_def_.OneLine(t0);
      t0 << output_list_[i].name << "->dtype = CSINN_DTYPE_FLOAT32;";
      func_def_.OneLine(t0);
      t0 << output_list_[i].name << "->is_const = 1;";
      func_def_.OneLine(t0);
      t0 << "csinn_set_output(" << output_index++ << ", " << output_list_[i].name << ", sess);";
      func_def_.OneLine(t0);
    }
  }

  func_def_.NewLine();
  func_def_.OneLine("csinn_session_setup(sess);");
  func_def_.OneLine("return sess;");
  func_def_.ExitScope();
  func_def_.OneLine("}");
}

string CodegenASP::get_ccode(void) {
  EmitVersion();
  EmitHeader();
  EmitSessionSetup();
  EmitSessionRun();
  DumpConstant();
  return func_def_.str();
}

void CodegenASP::phase1() {
  QuantConfig* set_config = new QuantConfig(expr_);
  set_config->set_quant_config(cfg);
  expr_ = set_config->get_expr();

  QuantInfo* qinfo = new QuantInfo(expr_);
  ASPQuantCalculator* lqc = new ASPQuantCalculator;
  qinfo->set_quant_calulator(lqc);
  qinfo->calculate_quant_info();
  expr_ = qinfo->get_expr();
}

}  // namespace csinn
}  // namespace contrib
}  // namespace relay
}  // namespace tvm
