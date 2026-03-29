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
 * \file nn.cc
 * \brief Property def of nn operators.
 */

#include <tvm/auto_scheduler/compute_dag.h>
#include <tvm/relay/attrs/custom_op.h>

#include <algorithm>
#include <string>
#include <vector>

#include "convolution.h"
#include "nn.h"

namespace tvm {
namespace relay {

// relay.custom.cache_matmul
TVM_REGISTER_NODE_TYPE(CacheMatMulAttrs);

bool CacheMatMulRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                    const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 4);

  auto* input = types[0].as<TensorTypeNode>();
  CHECK(input != nullptr);
  const auto* param = attrs.as<CacheMatMulAttrs>();
  CHECK(param != nullptr);

  auto shape = param->shape;
  auto axes = param->axes;

  const int ndim = shape.size();
  // construct int_axes
  std::vector<int> int_axes;
  int_axes.reserve(ndim);

  // Construct output shape
  std::vector<int> axis_used(ndim, 0);
  for (const Integer& e : axes) {
    int64_t axis = e;
    // sanity check for axis and ndim
    ICHECK(-ndim <= axis && axis < ndim)
        << "transpose only allows each `axis` in `axes` in range [-data.ndim, data.ndim)"
        << ", but got axis = " << axis << ", and data.ndim = " << ndim;
    axis = axis < 0 ? axis + ndim : axis;
    // sanity check for duplication
    ICHECK(!axis_used[axis]) << "Duplicate axes in transpose: " << axis;
    axis_used[axis] = 1;
    int_axes.push_back(static_cast<int>(axis));
  }

  std::vector<IndexExpr> oshape;
  oshape.reserve(ndim);
  for (int axis : int_axes) {
    oshape.push_back(shape[axis]);
  }

  // Assign output shape
  reporter->Assign(types[3], TensorType(oshape, input->dtype));
  return true;
}

Expr MakeCacheMatMul(Expr data, Expr weight, Expr bias, Array<Integer> cache_shape,
                     Array<Integer> shape, Array<Integer> axes) {
  auto attrs = make_object<CacheMatMulAttrs>();
  attrs->cache_shape = std::move(cache_shape);
  attrs->shape = std::move(shape);
  attrs->axes = std::move(axes);
  static const Op& op = Op::Get("cache_matmul");
  return Call(op, {data, weight, bias}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("cache_matmul")
    .describe(R"code(
    custom fusion ops.
     (cache)
     Gather   Other
        \      /
         Concat
           |
         MatMUl               --> CacheMatMul
           |
          Add
           |
        Reshape
           |
        Transpose
)code" TVM_ADD_FILELINE)
    .set_num_inputs(3)
    .set_attrs_type<CacheMatMulAttrs>()
    .add_argument("data", "Tensor", "The input data tensor.")
    .add_argument("weight", "Tensor", "The weight tensor.")
    .add_argument("bias", "Tensor", "The bias tensor.")
    .set_support_level(11)
    .add_type_rel("CacheMatMul", CacheMatMulRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.op.custom._make.cache_matmul").set_body_typed(MakeCacheMatMul);

// relay.custom.cache_conv1d
TVM_REGISTER_NODE_TYPE(CacheConv1DAttrs);

bool CacheConv1DRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                    const TypeReporter& reporter) {
  ICHECK_EQ(types.size(), 4);
  const auto* data = types[0].as<TensorTypeNode>();
  const auto* weight = types[1].as<TensorTypeNode>();
  if (data == nullptr) return false;
  static const Layout kNCW("NCW");
  static const Layout kOIW("OIW");

  const CacheConv1DAttrs* param = attrs.as<CacheConv1DAttrs>();
  ICHECK(param != nullptr);
  const Layout in_layout(param->data_layout);
  const Layout kernel_layout(param->kernel_layout);

  const auto trans_in_layout = tir::BijectiveLayout(in_layout, kNCW);
  ICHECK(trans_in_layout.defined())
      << "Conv only support input layouts that are convertible from NCW."
      << " But got " << in_layout;

  const auto trans_kernel_layout = tir::BijectiveLayout(kernel_layout, kOIW);
  ICHECK(trans_kernel_layout.defined())
      << "Conv only support kernel layouts that are convertible from OIW."
      << " But got " << kernel_layout;

  Layout out_layout(param->out_layout == "" ? param->data_layout : param->out_layout);
  const auto trans_out_layout = tir::BijectiveLayout(out_layout, kNCW);
  ICHECK(trans_out_layout.defined())
      << "Conv only support output layouts that are convertible from NCW."
      << " But got " << out_layout;

  Array<IndexExpr> dshape_nwc = trans_in_layout.ForwardShape(data->shape);

  IndexExpr channels, dilated_ksize;
  // infer weight if the kernel_size and channels are defined
  if (param->kernel_size.defined() && param->channels.defined()) {
    Array<IndexExpr> wshape;

    wshape = {{param->channels, dshape_nwc[2], param->kernel_size[0]}};

    wshape = trans_kernel_layout.BackwardShape(wshape);
    channels = param->channels;
    dilated_ksize = 1 + (param->kernel_size[0] - 1) * param->dilation[0];
    DataType weight_dtype = data->dtype;
    if (weight != nullptr) {
      weight_dtype = weight->dtype;
    }
    // assign result to reporter
    reporter->Assign(types[1], TensorType(wshape, weight_dtype));
  } else {
    // use weight to infer the conv shape.
    if (weight == nullptr) return false;
    auto wshape = trans_kernel_layout.ForwardShape(weight->shape);
    if (param->kernel_size.defined()) {
      // check the size
      ICHECK(reporter->AssertEQ(param->kernel_size[0], wshape[2]))
          << "Conv1D: shape of weight is inconsistent with kernel_size, "
          << " kernel_size=" << param->kernel_size << " wshape=" << wshape;
    }
    if (param->channels.defined()) {
      ICHECK(reporter->AssertEQ(param->channels, wshape[0]))
          << "Conv1D: shape of weight is inconsistent with channels, "
          << " channels=" << param->channels << " wshape=" << wshape;
    }
    if (!dshape_nwc[2].as<tir::AnyNode>() && !wshape[1].as<tir::AnyNode>()) {
      ICHECK(reporter->AssertEQ(dshape_nwc[2], wshape[1]));
    }
    channels = wshape[0];
    dilated_ksize = 1 + (wshape[2] - 1) * param->dilation[0];
  }
  // dilation
  Array<IndexExpr> oshape({dshape_nwc[0], channels, 0});

  if (!dshape_nwc[1].as<tir::AnyNode>()) {
    oshape.Set(2, param->cache_shape[2] + dshape_nwc[1]);
  } else {
    oshape.Set(2, dshape_nwc[1]);
  }

  DataType out_dtype = param->out_dtype;
  if (out_dtype.bits() == 0) {
    out_dtype = data->dtype;
  }
  oshape = trans_out_layout.BackwardShape(oshape);
  // assign output type
  reporter->Assign(types[3], TensorType(oshape, out_dtype));
  return true;
}

Expr MakeCacheConv1d(Expr data, Expr weight, Expr bias, Array<Integer> cache_shape,
                     Array<IndexExpr> strides, Array<IndexExpr> padding, Array<IndexExpr> dilation,
                     int groups, IndexExpr channels, Array<IndexExpr> kernel_size,
                     String data_layout, String kernel_layout, String out_layout,
                     DataType out_dtype) {
  auto attrs = make_object<CacheConv1DAttrs>();
  attrs->cache_shape = std::move(cache_shape);
  attrs->strides = std::move(strides);
  attrs->padding = std::move(padding);
  attrs->dilation = std::move(dilation);
  attrs->groups = groups;
  attrs->channels = std::move(channels);
  attrs->kernel_size = std::move(kernel_size);
  attrs->data_layout = std::move(data_layout);
  attrs->kernel_layout = std::move(kernel_layout);
  attrs->out_layout = std::move(out_layout);
  attrs->out_dtype = std::move(out_dtype);
  const Op& op = Op::Get("cache_conv1d");
  return Call(op, {data, weight, bias}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("cache_conv1d")
    .describe(R"code(
    custom fusion ops.
    (Cache)    Input
      |          |
    Gather   Transpose
       \        /
         Concat               --> CacheConv1d
           |
         Conv1d
           |
        BiasAdd

)code" TVM_ADD_FILELINE)
    .set_num_inputs(3)
    .set_attrs_type<CacheConv1DAttrs>()
    .add_argument("data", "Tensor", "The input data tensor.")
    .add_argument("weight", "Tensor", "The weight tensor.")
    .add_argument("bias", "Tensor", "The bias tensor.")
    .set_support_level(11)
    .add_type_rel("CacheConv1d", CacheConv1DRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.op.custom._make.cache_conv1d").set_body_typed(MakeCacheConv1d);

}  // namespace relay
}  // namespace tvm
