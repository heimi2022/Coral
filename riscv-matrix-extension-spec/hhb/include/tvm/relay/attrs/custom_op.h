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
 * \file tvm/relay/attrs/custom_op.h
 * \brief Auxiliary attributes for nn operators.
 */
#ifndef TVM_RELAY_ATTRS_CUSTOM_OP_H_
#define TVM_RELAY_ATTRS_CUSTOM_OP_H_

#include <tvm/ir/attrs.h>
#include <tvm/relay/base.h>

#include <string>

namespace tvm {
namespace relay {

/*! \brief Attributes used in CacheMatMul operator */
struct CacheMatMulAttrs : public tvm::AttrsNode<CacheMatMulAttrs> {
  Array<Integer> cache_shape;
  // shape for reshape
  Array<Integer> shape;
  // axes for transpose
  Array<Integer> axes;

  TVM_DECLARE_ATTRS(CacheMatMulAttrs, "relay.attrs.CacheMatMulAttrs") {
    TVM_ATTR_FIELD(cache_shape).describe("The target shape before transpose.");
    TVM_ATTR_FIELD(shape).describe("The target shape before transpose.");
    TVM_ATTR_FIELD(axes).describe("The target axes order.");
  }
};  // struct CacheMatMulAttrs

/*! \brief Attributes used in 1D convolution operators */
struct CacheConv1DAttrs : public tvm::AttrsNode<CacheConv1DAttrs> {
  Array<Integer> cache_shape;
  Array<IndexExpr> strides;
  Array<IndexExpr> padding;
  Array<IndexExpr> dilation;
  int groups;
  IndexExpr channels;
  Array<IndexExpr> kernel_size;
  std::string data_layout;
  std::string kernel_layout;
  std::string out_layout;
  DataType out_dtype;

  TVM_DECLARE_ATTRS(CacheConv1DAttrs, "relay.attrs.CacheConv1DAttrs") {
    TVM_ATTR_FIELD(cache_shape).describe("cache shape of the conv1d.");
    TVM_ATTR_FIELD(strides)
        .set_default(Array<IndexExpr>({
            1,
        }))
        .describe("Specifies the stride of the convolution.");
    TVM_ATTR_FIELD(padding)
        .set_default(Array<IndexExpr>({0, 0}))
        .describe(
            "If padding is non-zero, then the input is implicitly zero-padded"
            "on both sides for padding number of points");
    TVM_ATTR_FIELD(dilation)
        .set_default(Array<IndexExpr>({
            1,
        }))
        .describe("Specifies the dilation rate to use for dilated convolution.");
    TVM_ATTR_FIELD(groups).set_default(1).describe(
        "Currently unused but may be added in the future.");
    TVM_ATTR_FIELD(channels)
        .describe(
            "The number of output channels in the convolution."
            " If it is not set, inferred by shape of the weight.")
        .set_default(NullValue<IndexExpr>());
    TVM_ATTR_FIELD(kernel_size)
        .describe("Specifies the dimensions of the convolution window.")
        .set_default(NullValue<Array<IndexExpr>>());
    TVM_ATTR_FIELD(data_layout)
        .set_default("NCW")
        .describe(
            "Dimension ordering of input data. Can be 'NCW', 'NWC', etc."
            "'N', 'C', 'W' stands for batch, channel, and width"
            "dimensions respectively. Convolution is applied on the 'W'"
            "dimension.");
    TVM_ATTR_FIELD(kernel_layout)
        .set_default("OIW")
        .describe(
            "Dimension ordering of weight. Can be 'OIW', or 'WIO', etc."
            "'O', 'I', 'W' stands for num_filter, input_channel, and width"
            "dimensions respectively.");
    TVM_ATTR_FIELD(out_layout)
        .set_default("")
        .describe(
            "Dimension ordering of output. Can be 'NCW', 'NWC', etc."
            "'N', 'C', 'W' stands for batch, channel, and width"
            "dimensions respectively. Default to be same as input layout.");
    // use 0 bits to indicate none.
    TVM_ATTR_FIELD(out_dtype)
        .set_default(NullValue<DataType>())
        .describe("Output data type, set to explicit type under mixed precision setting");
  }
};

}  // namespace relay
}  // namespace tvm
#endif  // TVM_RELAY_ATTRS_CUSTOM_OP_H_
