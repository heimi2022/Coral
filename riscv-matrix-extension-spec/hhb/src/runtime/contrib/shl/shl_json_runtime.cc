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
 * \file src/runtime/contrib/shl/shl_json_runtime.cc
 * \brief A simple JSON runtime for SHL.
 */

#include <tvm/runtime/ndarray.h>
#include <tvm/runtime/registry.h>

#include <cstddef>
#include <string>
#include <vector>

#include "../json/json_node.h"
#include "../json/json_runtime.h"
#include "csi_nn.h"

namespace tvm {
namespace runtime {
namespace contrib {

using namespace tvm::runtime;
using namespace tvm::runtime::json;

class SHLJSONRuntime : public JSONRuntimeBase {
 public:
  SHLJSONRuntime(const std::string& symbol_name, const std::string& graph_json,
                 const Array<String> const_names)
      : JSONRuntimeBase(symbol_name, graph_json, const_names) {}

  const char* type_key() const { return "shl_json"; }

  void Init(const Array<NDArray>& consts) override {
    // Setup constants entries for weights.
    SetupConstants(consts);
    sess = csinn_alloc_session();
    sess->base_dtype = CSINN_DTYPE_FLOAT32;
    sess->base_layout = CSINN_LAYOUT_NCHW;
    sess->base_run_mode = CSINN_RM_CPU_GRAPH;
    sess->base_api = CSINN_REF;
    // sess->debug_level = CSINN_DEBUG_LEVEL_INFO;
    csinn_session_init(sess);
    BuildEngine();
    csinn_session_setup(sess);
  }

  void Run() override {
    // Fill in the input buffers.
    for (size_t i = 0; i < input_nodes_.size(); ++i) {
      auto nid = input_nodes_[i];
      auto eid = EntryID(nid, 0);
      if (nodes_[nid].GetOpType() == "input") {
        struct csinn_tensor* input_tensor = csinn_alloc_tensor(NULL);
        input_tensor->data = data_entry_[eid]->data;
        csinn_update_input(i, input_tensor, sess);
      }
    }

    // Invoke the engine through intepreting the stream.
    csinn_session_run(sess);

    // Read output buffers.
    for (size_t i = 0; i < outputs_.size(); ++i) {
      struct csinn_tensor* output = csinn_alloc_tensor(NULL);
      auto eid = EntryID(outputs_[i]);
      size_t buffer_size = GetDataSize(*data_entry_[eid]);
      csinn_get_output(i, output, sess);
      memcpy(data_entry_[eid]->data, output->data, buffer_size);
    }
  }

 private:
  struct csinn_tensor* BindSHLTensor(const JSONGraphNodeEntry& entry) {
    auto eid = EntryID(entry);
    if (entry_out_tensor_.count(eid) == 0) {
      struct csinn_tensor* tensor = csinn_alloc_tensor(sess);
      entry_out_tensor_[eid] = tensor;
    }
    return entry_out_tensor_[eid];
  }

  // Build up the engine based on the input graph.
  void BuildEngine() {
    csinn_set_input_number(input_nodes_.size(), sess);
    csinn_set_output_number(outputs_.size(), sess);
    for (size_t i = 0; i < input_nodes_.size(); ++i) {
      auto nid = input_nodes_[i];
      auto node = nodes_[nid];
      uint32_t eid = EntryID(nid, 0);
      if (node.GetOpType() == "input") {
        JSONGraphNodeEntry out_entry(nid, 0);
        struct csinn_tensor* input_tensor = BindSHLTensor(out_entry);
        csinn_set_tensor_entry(input_tensor, sess);
        csinn_set_input(i, input_tensor, sess);
      } else if (node.GetOpType() == "const") {
        JSONGraphNodeEntry out_entry(nid, 0);
        struct csinn_tensor* const_tensor = BindSHLTensor(out_entry);
        const_tensor->data = data_entry_[eid]->data;
      }
    }
    // Build subgraph engine.
    for (size_t nid = 0; nid < nodes_.size(); ++nid) {
      const auto& node = nodes_[nid];
      if (node.GetOpType() == "kernel") {
        ICHECK_EQ(node.GetOpType(), "kernel");
        auto op_name = node.GetOpName();
        if ("nn.conv2d" == op_name) {
          conv2d(nid);
        } else if ("shl.conv2d" == op_name) {
          conv2d(nid, true);
        } else if ("shl.depthwise_conv2d" == op_name) {
          depthwise_conv2d(nid, true);
        } else if ("nn.dense" == op_name) {
          dense(nid);
        } else if ("shl.dense" == op_name) {
          dense(nid, true);
        } else if ("nn.relu" == op_name) {
          relu(nid);
        } else if ("nn.max_pool2d" == op_name) {
          maxpool(nid);
        } else if ("nn.avg_pool2d" == op_name) {
          avgpool(nid);
        } else if ("nn.softmax" == op_name) {
          softmax(nid);
        } else {
          LOG(FATAL) << "Unsupported op: " << op_name;
        }
      }
    }
    for (size_t i = 0; i < outputs_.size(); ++i) {
      struct csinn_tensor* output = BindSHLTensor(outputs_[i]);
      csinn_set_output(i, output, sess);
    }
  }

  void conv2d(const size_t& nid, const bool has_bias = false) {
    auto node = nodes_[nid];

    struct csinn_conv2d_params* params = static_cast<struct csinn_conv2d_params*>(
        csinn_alloc_params(sizeof(struct csinn_conv2d_params), sess));
    auto data_entry = node.GetInputs()[0];
    auto weight_entry = node.GetInputs()[1];
    struct csinn_tensor* input = BindSHLTensor(data_entry);
    struct csinn_tensor* kernel = BindSHLTensor(weight_entry);

    auto input_shape = nodes_[data_entry.id_].GetOpShape()[data_entry.index_];
    auto weight_shape = nodes_[weight_entry.id_].GetOpShape()[weight_entry.index_];
    std::vector<std::string> strides = node.GetAttr<std::vector<std::string>>("strides");
    std::vector<std::string> padding = node.GetAttr<std::vector<std::string>>("padding");
    std::vector<std::string> dilation = node.GetAttr<std::vector<std::string>>("dilation");
    auto groups = std::stoi(node.GetAttr<std::vector<std::string>>("groups")[0]);

    input->dim_count = input_shape.size();
    input->dim[0] = input_shape[0];
    input->dim[1] = input_shape[1];
    input->dim[2] = input_shape[2];
    input->dim[3] = input_shape[3];
    input->layout = CSINN_LAYOUT_NCHW;
    kernel->dim_count = weight_shape.size();
    kernel->dim[0] = weight_shape[0];
    kernel->dim[1] = weight_shape[1];
    kernel->dim[2] = weight_shape[2];
    kernel->dim[3] = weight_shape[3];
    kernel->is_const = 1;
    kernel->layout = CSINN_LAYOUT_OIHW;

    params->group = groups;
    params->stride_height = std::stoi(strides[0]);
    params->stride_width = std::stoi(strides[1]);
    params->pad_top = std::stoi(padding[0]);
    params->pad_left = std::stoi(padding[1]);
    params->pad_down = std::stoi(padding[2]);
    params->pad_right = std::stoi(padding[3]);
    params->dilation_height = std::stoi(dilation[0]);
    params->dilation_width = std::stoi(dilation[1]);
    std::string name = "conv_" + std::to_string(layer_index++);
    params->base.name = const_cast<char*>(name.c_str());

    struct csinn_tensor* bias = NULL;
    if (has_bias) {
      auto bias_entry = node.GetInputs()[2];
      auto bias_shape = nodes_[bias_entry.id_].GetOpShape()[bias_entry.index_];
      bias = BindSHLTensor(bias_entry);
      bias->dim_count = bias_shape.size();
      bias->dim[0] = bias_shape[0];
      bias->is_const = 1;
    } else {
      bias = csinn_alloc_tensor(sess);
      bias->dim_count = 0;
      bias->dim[0] = 0;
      bias->is_const = 1;
    }

    JSONGraphNodeEntry out_entry(nid, 0);
    struct csinn_tensor* output = BindSHLTensor(out_entry);
    auto output_shape = node.GetOpShape()[0];
    output->dim_count = output_shape.size();
    output->dim[0] = output_shape[0];
    output->dim[1] = output_shape[1];
    output->dim[2] = output_shape[2];
    output->dim[3] = output_shape[3];
    output->layout = CSINN_LAYOUT_NCHW;

    csinn_conv2d_init(input, output, kernel, bias, params);
    csinn_conv2d(input, output, kernel, bias, params);
  }

  void depthwise_conv2d(const size_t& nid, const bool has_bias = false) {
    auto node = nodes_[nid];

    struct csinn_conv2d_params* params = static_cast<struct csinn_conv2d_params*>(
        csinn_alloc_params(sizeof(struct csinn_conv2d_params), sess));
    auto data_entry = node.GetInputs()[0];
    auto weight_entry = node.GetInputs()[1];
    struct csinn_tensor* input = BindSHLTensor(data_entry);
    struct csinn_tensor* kernel = BindSHLTensor(weight_entry);

    auto input_shape = nodes_[data_entry.id_].GetOpShape()[data_entry.index_];
    auto weight_shape = nodes_[weight_entry.id_].GetOpShape()[weight_entry.index_];
    std::vector<std::string> strides = node.GetAttr<std::vector<std::string>>("strides");
    std::vector<std::string> padding = node.GetAttr<std::vector<std::string>>("padding");
    std::vector<std::string> dilation = node.GetAttr<std::vector<std::string>>("dilation");
    auto groups = std::stoi(node.GetAttr<std::vector<std::string>>("groups")[0]);

    input->dim_count = input_shape.size();
    input->dim[0] = input_shape[0];
    input->dim[1] = input_shape[1];
    input->dim[2] = input_shape[2];
    input->dim[3] = input_shape[3];
    input->layout = CSINN_LAYOUT_NCHW;
    kernel->dim_count = weight_shape.size();
    kernel->dim[0] = weight_shape[0];
    kernel->dim[1] = weight_shape[1];
    kernel->dim[2] = weight_shape[2];
    kernel->dim[3] = weight_shape[3];
    kernel->is_const = 1;
    kernel->layout = CSINN_LAYOUT_O1HW;

    params->group = groups;
    params->stride_height = std::stoi(strides[0]);
    params->stride_width = std::stoi(strides[1]);
    params->pad_top = std::stoi(padding[0]);
    params->pad_left = std::stoi(padding[1]);
    params->pad_down = std::stoi(padding[2]);
    params->pad_right = std::stoi(padding[3]);
    params->dilation_height = std::stoi(dilation[0]);
    params->dilation_width = std::stoi(dilation[1]);
    std::string name = "depthwise_conv_" + std::to_string(layer_index++);
    params->base.name = const_cast<char*>(name.c_str());

    struct csinn_tensor* bias = NULL;
    if (has_bias) {
      auto bias_entry = node.GetInputs()[2];
      auto bias_shape = nodes_[bias_entry.id_].GetOpShape()[bias_entry.index_];
      bias = BindSHLTensor(bias_entry);
      bias->dim_count = bias_shape.size();
      bias->dim[0] = bias_shape[0];
      bias->is_const = 1;
    } else {
      bias = csinn_alloc_tensor(sess);
      bias->dim_count = 0;
      bias->dim[0] = 0;
      bias->is_const = 1;
    }

    JSONGraphNodeEntry out_entry(nid, 0);
    struct csinn_tensor* output = BindSHLTensor(out_entry);
    auto output_shape = node.GetOpShape()[0];
    output->dim_count = output_shape.size();
    output->dim[0] = output_shape[0];
    output->dim[1] = output_shape[1];
    output->dim[2] = output_shape[2];
    output->dim[3] = output_shape[3];
    output->layout = CSINN_LAYOUT_NCHW;

    csinn_conv2d_init(input, output, kernel, bias, params);
    csinn_conv2d(input, output, kernel, bias, params);
  }

  void dense(const size_t& nid, const bool has_bias = false) {
    auto node = nodes_[nid];

    struct csinn_fc_params* params = static_cast<struct csinn_fc_params*>(
        csinn_alloc_params(sizeof(struct csinn_fc_params), sess));
    auto data_entry = node.GetInputs()[0];
    auto weight_entry = node.GetInputs()[1];
    struct csinn_tensor* input = BindSHLTensor(data_entry);
    struct csinn_tensor* kernel = BindSHLTensor(weight_entry);

    auto input_shape = nodes_[data_entry.id_].GetOpShape()[data_entry.index_];
    auto weight_shape = nodes_[weight_entry.id_].GetOpShape()[weight_entry.index_];

    input->dim_count = input_shape.size();
    input->dim[0] = input_shape[0];
    input->dim[1] = input_shape[1];
    input->dim[2] = input_shape[2];
    input->dim[3] = input_shape[3];
    input->layout = CSINN_LAYOUT_NCHW;
    kernel->dim_count = weight_shape.size();
    kernel->dim[0] = weight_shape[0];
    kernel->dim[1] = weight_shape[1];
    kernel->dim[2] = weight_shape[2];
    kernel->dim[3] = weight_shape[3];
    kernel->is_const = 1;
    kernel->layout = CSINN_LAYOUT_OIHW;
    std::string name = "dense_" + std::to_string(layer_index++);
    params->base.name = const_cast<char*>(name.c_str());

    struct csinn_tensor* bias = NULL;
    if (has_bias) {
      auto bias_entry = node.GetInputs()[2];
      auto bias_shape = nodes_[bias_entry.id_].GetOpShape()[bias_entry.index_];
      bias = BindSHLTensor(bias_entry);
      bias->dim_count = bias_shape.size();
      bias->dim[0] = bias_shape[0];
      bias->is_const = 1;
    } else {
      bias = csinn_alloc_tensor(sess);
      bias->dim_count = 0;
      bias->dim[0] = 0;
      bias->is_const = 1;
    }

    JSONGraphNodeEntry out_entry(nid, 0);
    struct csinn_tensor* output = BindSHLTensor(out_entry);
    auto output_shape = node.GetOpShape()[0];
    output->dim_count = output_shape.size();
    output->dim[0] = output_shape[0];
    output->dim[1] = output_shape[1];
    output->dim[2] = output_shape[2];
    output->dim[3] = output_shape[3];
    output->layout = CSINN_LAYOUT_NCHW;

    csinn_fullyconnected_init(input, output, kernel, bias, params);
    csinn_fullyconnected(input, output, kernel, bias, params);
  }

  void maxpool(const size_t& nid) {
    auto node = nodes_[nid];

    struct csinn_pool_params* params = static_cast<struct csinn_pool_params*>(
        csinn_alloc_params(sizeof(struct csinn_pool_params), sess));
    auto data_entry = node.GetInputs()[0];
    struct csinn_tensor* input = BindSHLTensor(data_entry);

    auto input_shape = nodes_[data_entry.id_].GetOpShape()[data_entry.index_];
    std::vector<std::string> strides = node.GetAttr<std::vector<std::string>>("strides");
    std::vector<std::string> padding = node.GetAttr<std::vector<std::string>>("padding");
    std::vector<std::string> attr_pool_size = node.GetAttr<std::vector<std::string>>("pool_size");
    bool ceil_mode = std::stoi(node.GetAttr<std::vector<std::string>>("ceil_mode")[0]);

    input->dim_count = input_shape.size();
    input->dim[0] = input_shape[0];
    input->dim[1] = input_shape[1];
    input->dim[2] = input_shape[2];
    input->dim[3] = input_shape[3];
    input->layout = CSINN_LAYOUT_NCHW;

    params->stride_height = std::stoi(strides[0]);
    params->stride_width = std::stoi(strides[1]);
    params->pad_top = std::stoi(padding[0]);
    params->pad_left = std::stoi(padding[1]);
    params->pad_down = std::stoi(padding[2]);
    params->pad_right = std::stoi(padding[3]);
    params->filter_height = std::stoi(attr_pool_size[0]);
    params->filter_width = std::stoi(attr_pool_size[1]);
    params->ceil_mode = ceil_mode;
    bool count_include_pad = false;
    if (node.HasAttr("count_include_pad")) {
      count_include_pad = std::stoi(node.GetAttr<std::vector<std::string>>("count_include_pad")[0]);
    }
    params->count_include_pad = count_include_pad;
    std::string name = "maxpool_" + std::to_string(layer_index++);
    params->base.name = const_cast<char*>(name.c_str());

    JSONGraphNodeEntry out_entry(nid, 0);
    struct csinn_tensor* output = BindSHLTensor(out_entry);
    auto output_shape = node.GetOpShape()[0];
    output->dim_count = output_shape.size();
    output->dim[0] = output_shape[0];
    output->dim[1] = output_shape[1];
    output->dim[2] = output_shape[2];
    output->dim[3] = output_shape[3];
    output->layout = CSINN_LAYOUT_NCHW;

    csinn_maxpool2d_init(input, output, params);
    csinn_maxpool2d(input, output, params);
  }

  void avgpool(const size_t& nid) {
    auto node = nodes_[nid];

    struct csinn_pool_params* params = static_cast<struct csinn_pool_params*>(
        csinn_alloc_params(sizeof(struct csinn_pool_params), sess));
    auto data_entry = node.GetInputs()[0];
    struct csinn_tensor* input = BindSHLTensor(data_entry);

    auto input_shape = nodes_[data_entry.id_].GetOpShape()[data_entry.index_];
    std::vector<std::string> strides = node.GetAttr<std::vector<std::string>>("strides");
    std::vector<std::string> padding = node.GetAttr<std::vector<std::string>>("padding");
    std::vector<std::string> attr_pool_size = node.GetAttr<std::vector<std::string>>("pool_size");
    bool ceil_mode = std::stoi(node.GetAttr<std::vector<std::string>>("ceil_mode")[0]);

    input->dim_count = input_shape.size();
    input->dim[0] = input_shape[0];
    input->dim[1] = input_shape[1];
    input->dim[2] = input_shape[2];
    input->dim[3] = input_shape[3];
    input->layout = CSINN_LAYOUT_NCHW;

    params->stride_height = std::stoi(strides[0]);
    params->stride_width = std::stoi(strides[1]);
    params->pad_top = std::stoi(padding[0]);
    params->pad_left = std::stoi(padding[1]);
    params->pad_down = std::stoi(padding[2]);
    params->pad_right = std::stoi(padding[3]);
    params->filter_height = std::stoi(attr_pool_size[0]);
    params->filter_width = std::stoi(attr_pool_size[1]);
    params->ceil_mode = ceil_mode;
    bool count_include_pad = false;
    if (node.HasAttr("count_include_pad")) {
      count_include_pad = std::stoi(node.GetAttr<std::vector<std::string>>("count_include_pad")[0]);
    }
    params->count_include_pad = count_include_pad;
    std::string name = "avgpool_" + std::to_string(layer_index++);
    params->base.name = const_cast<char*>(name.c_str());

    JSONGraphNodeEntry out_entry(nid, 0);
    struct csinn_tensor* output = BindSHLTensor(out_entry);
    auto output_shape = node.GetOpShape()[0];
    output->dim_count = output_shape.size();
    output->dim[0] = output_shape[0];
    output->dim[1] = output_shape[1];
    output->dim[2] = output_shape[2];
    output->dim[3] = output_shape[3];
    output->layout = CSINN_LAYOUT_NCHW;

    csinn_avgpool2d_init(input, output, params);
    csinn_avgpool2d(input, output, params);
  }

  void relu(const size_t& nid) {
    auto node = nodes_[nid];

    struct csinn_relu_params* params = static_cast<struct csinn_relu_params*>(
        csinn_alloc_params(sizeof(struct csinn_relu_params), sess));
    auto data_entry = node.GetInputs()[0];
    struct csinn_tensor* input = BindSHLTensor(data_entry);

    auto input_shape = nodes_[data_entry.id_].GetOpShape()[data_entry.index_];

    input->dim_count = input_shape.size();
    input->dim[0] = input_shape[0];
    input->dim[1] = input_shape[1];
    input->dim[2] = input_shape[2];
    input->dim[3] = input_shape[3];
    input->layout = CSINN_LAYOUT_NCHW;

    std::string name = "relu_" + std::to_string(layer_index++);
    params->base.name = const_cast<char*>(name.c_str());

    JSONGraphNodeEntry out_entry(nid, 0);
    struct csinn_tensor* output = BindSHLTensor(out_entry);
    auto output_shape = node.GetOpShape()[0];
    output->dim_count = output_shape.size();
    output->dim[0] = output_shape[0];
    output->dim[1] = output_shape[1];
    output->dim[2] = output_shape[2];
    output->dim[3] = output_shape[3];
    output->layout = CSINN_LAYOUT_NCHW;

    csinn_relu_init(input, output, params);
    csinn_relu(input, output, params);
  }

  void softmax(const size_t& nid) {
    auto node = nodes_[nid];

    struct csinn_softmax_params* params = static_cast<struct csinn_softmax_params*>(
        csinn_alloc_params(sizeof(struct csinn_softmax_params), sess));
    auto data_entry = node.GetInputs()[0];
    auto axis = std::stoi(node.GetAttr<std::vector<std::string>>("axis")[0]);
    params->axis = axis;
    std::string name = "softmax_" + std::to_string(layer_index++);
    params->base.name = const_cast<char*>(name.c_str());
    struct csinn_tensor* input = BindSHLTensor(data_entry);

    auto input_shape = nodes_[data_entry.id_].GetOpShape()[data_entry.index_];

    input->dim_count = input_shape.size();
    input->dim[0] = input_shape[0];
    input->dim[1] = input_shape[1];
    input->dim[2] = input_shape[2];
    input->dim[3] = input_shape[3];
    input->layout = CSINN_LAYOUT_NCHW;

    JSONGraphNodeEntry out_entry(nid, 0);
    struct csinn_tensor* output = BindSHLTensor(out_entry);
    auto output_shape = node.GetOpShape()[0];
    output->dim_count = output_shape.size();
    output->dim[0] = output_shape[0];
    output->dim[1] = output_shape[1];
    output->dim[2] = output_shape[2];
    output->dim[3] = output_shape[3];
    output->layout = CSINN_LAYOUT_NCHW;

    csinn_softmax_init(input, output, params);
    csinn_softmax(input, output, params);
  }

  /* The network layers that are represented in shl primitives. */
  struct csinn_session* sess;

  int layer_index{0};

  /* The entry ID to its corresponding output tensor. */
  std::unordered_map<uint32_t, struct csinn_tensor*> entry_out_tensor_;
};

runtime::Module SHLJSONRuntimeCreate(String symbol_name, String graph_json,
                                     const Array<String>& const_names) {
  auto n = make_object<SHLJSONRuntime>(symbol_name, graph_json, const_names);
  return runtime::Module(n);
}

TVM_REGISTER_GLOBAL("runtime.SHLJSONRuntimeCreate").set_body_typed(SHLJSONRuntimeCreate);

TVM_REGISTER_GLOBAL("runtime.module.loadbinary_shl_json")
    .set_body_typed(JSONRuntimeBase::LoadFromBinary<SHLJSONRuntime>);

}  // namespace contrib
}  // namespace runtime
}  // namespace tvm
