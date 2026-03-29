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
#ifndef TVM_RELAY_BACKEND_CONTRIB_CSINN_LIGHT_H_
#define TVM_RELAY_BACKEND_CONTRIB_CSINN_LIGHT_H_

#include <algorithm>
#include <string>
#include <vector>

#include "gref.h"

namespace tvm {
namespace relay {
namespace contrib {
namespace csinn {

class LightQuantCalculator : public QuantCalculator {
 public:
  void GetSymScale(float min_value, float max_value, int bits, Qinfo* qinfo) {
    int valid_range = std::pow(2, bits - 1) - 1;
    float abs_max = std::max(std::abs(min_value), std::abs(max_value));
    float scale = valid_range / abs_max;
    int exponent;
    frexp(scale, &exponent);
    qinfo->scale = 1.0f / std::pow(2, exponent - 1);
    qinfo->zero_point = 0;
    qinfo->max = abs_max;
    qinfo->min = -abs_max;
  }
};

class CodegenLight : public CodegenGref {
 public:
  virtual void VisitExpr_(const CallNode* call);

  void ModelBinarySave();
  void EmitHeader(void);
  void EmitSessionSetup(void);
  void EmitJitWrapper(void);
  void EmitNBGSetup(void);
  string get_ccode(void);

  void phase1() final;
};

}  // namespace csinn
}  // namespace contrib
}  // namespace relay
}  // namespace tvm
#endif  // TVM_RELAY_BACKEND_CONTRIB_CSINN_LIGHT_H_
