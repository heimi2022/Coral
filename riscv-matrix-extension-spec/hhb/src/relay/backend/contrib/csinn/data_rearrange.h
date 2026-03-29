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
 * \file src/relay/backend/contrib/csinn/data_rearrange.h
 * \brief The base class for external codegen tools.
 */
#ifndef TVM_RELAY_BACKEND_CONTRIB_CSINN_DATA_REARRANGE_H_
#define TVM_RELAY_BACKEND_CONTRIB_CSINN_DATA_REARRANGE_H_

#include <map>
#include <string>
#include <vector>

#include "csinn.h"

using std::vector;
namespace tvm {
namespace relay {
namespace contrib {
namespace csinn {

CSIConstant* rearrange_data(CSIConstant* src_data, vector<int> shape, string src_layout,
                            string dest_layout);
void layout_to_OxHWIx(void* dest, void* src, vector<int> shape, int align);

}  // namespace csinn
}  // namespace contrib
}  // namespace relay
}  // namespace tvm
#endif  // TVM_RELAY_BACKEND_CONTRIB_CSINN_DATA_REARRANGE_H_
