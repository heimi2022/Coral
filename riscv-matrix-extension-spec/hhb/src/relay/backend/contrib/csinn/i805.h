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
 * \file src/relay/backend/contrib/csinn/ref.h
 * \brief The base class for external codegen tools.
 */
#ifndef TVM_RELAY_BACKEND_CONTRIB_CSINN_I805_H_
#define TVM_RELAY_BACKEND_CONTRIB_CSINN_I805_H_

#include <string>
#include <vector>

#include "csinn.h"
#include "ref.h"

namespace tvm {
namespace relay {
namespace contrib {
namespace csinn {

class CodegenI805 : public CodegenRef {
 public:
  CodegenI805() : CodegenRef() {}
  virtual ~CodegenI805() {}

  virtual void GenerateBackendCFunc(const string& func_name, const Array<Var>& args,
                                    const output_element& out);
};

}  // namespace csinn
}  // namespace contrib
}  // namespace relay
}  // namespace tvm
#endif  // TVM_RELAY_BACKEND_CONTRIB_CSINN_I805_H_
