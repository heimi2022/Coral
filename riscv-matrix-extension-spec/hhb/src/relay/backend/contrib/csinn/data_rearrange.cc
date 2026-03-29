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
 * \file src/relay/backend/contrib/csinn/data_rearrange.cc
 * \brief Implementation of CSINN codegen APIs.
 */

#include "data_rearrange.h"

using namespace tvm::relay::qnn;
namespace tvm {
namespace relay {
namespace contrib {
namespace csinn {

void layout_to_OxHWIx(void* dest, void* src, vector<int> shape, int align) {
  int b_len = 1;
  for (uint i = 1; i < shape.size(); i++) {
    b_len *= shape[i];
  }

  int8_t* src_addr = reinterpret_cast<int8_t*>(src);
  int8_t* dest_addr = reinterpret_cast<int8_t*>(dest);
  int src_idx = 0;
  int idx_base = 0;
  int dest_idx = 0;
  /* read src stride, write in order */
  for (int i = 0; i < shape[0] / align; i++) {
    idx_base = i * align * b_len;
    dest_idx = idx_base;
    for (int j = 0; j < b_len; j++) {
      for (int k = 0; k < align; k++) {
        src_idx = idx_base + k * b_len + j;
        dest_addr[dest_idx] = src_addr[src_idx];
        dest_idx++;
      }
    }
  }
  idx_base = (shape[0] / align) * align * b_len;
  dest_idx = idx_base;
  for (int j = 0; j < b_len; j++) {
    for (int k = 0; k < shape[0] % align; k++) {
      src_idx = idx_base + k * b_len + j;
      dest_idx = idx_base + k + align * j;
      dest_addr[dest_idx] = src_addr[src_idx];
    }
  }
}

void layout_to_1HWxOx(void* dest, void* src, vector<int> shape, int align) {
  int b_len = align * shape[1] * shape[2];

  int8_t* src_addr = reinterpret_cast<int8_t*>(src);
  int8_t* dest_addr = reinterpret_cast<int8_t*>(dest);
  /* read in src order, write stride */
  for (int i = 0; i < shape[1] * shape[2]; i++) {
    for (int j = 0; j < shape[3] / align; j++) {
      dest_addr = dest_addr + j * b_len + i * align;
      memcpy(dest_addr, src_addr, align);
      src_addr += align;
    }
    if (shape[3] % align) {
      dest_addr = dest_addr + (shape[3] / align) * b_len + i * align;
      memcpy(dest_addr, src_addr, shape[3] % align);
      src_addr += shape[3] % align;
    }
  }
}

std::map<string, uint> align_map{
    {"O32I32", 32},
    {"1HW32O32", 32},
    {"O32HWI32", 32},
};

template <typename T>
bool is_one_of(T target_item, std::initializer_list<T> arr) {
  for (auto item : arr) {
    if (item == target_item) {
      return true;
    }
  }
  return false;
}

CSIConstant* rearrange_data(CSIConstant* src_data, vector<int> shape, string src_layout,
                            string dest_layout) {
  CHECK(is_one_of<string>(src_layout, {"OI", "1HWO", "OHWI"}));
  CHECK(is_one_of<string>(dest_layout, {"O32I32", "1HW32O32", "O32HWI32"}));
  CHECK((src_data->get_dtype() == "uint8_t" || src_data->get_dtype() == "int8_t"));

  CSIConstant* new_data = new CSIConstant(src_data->get_dtype(), src_data->get_shape());
  new_data->set_name(src_data->get_name());

  if (src_layout == "1HWO" && dest_layout == "1HW32O32") {
    layout_to_1HWxOx(new_data->get_data_buf(), src_data->get_data_buf(), shape,
                     align_map[dest_layout]);
  } else if (src_layout == "OI" && dest_layout == "O32I32") {
    layout_to_OxHWIx(new_data->get_data_buf(), src_data->get_data_buf(), shape,
                     align_map[dest_layout]);
  } else if (src_layout == "OHWI" && dest_layout == "O32HWI32") {
    layout_to_OxHWIx(new_data->get_data_buf(), src_data->get_data_buf(), shape,
                     align_map[dest_layout]);
  }

  return new_data;
}

}  // namespace csinn
}  // namespace contrib
}  // namespace relay
}  // namespace tvm
