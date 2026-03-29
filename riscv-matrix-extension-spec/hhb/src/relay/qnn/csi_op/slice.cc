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
 * \file src/relay/qnn/op/slice.cc
 * \brief QNN stride slice operator.
 */
#include <tvm/relay/analysis.h>
#include <tvm/relay/op_attr_types.h>
#include <tvm/relay/qnn/attrs.h>

#include "../op/op_common.h"
#include "../utils.h"

namespace tvm {
namespace relay {
namespace qnn {

// strided_slice
TVM_REGISTER_NODE_TYPE(QnnCSIStridedSliceAttrs);
bool QnnCSIStridedSliceRel(const Array<Type>& types, int num_inputs, const Attrs& attrs,
                           const TypeReporter& reporter) {
  CHECK_EQ(types.size(), 2);
  const auto* data = types[0].as<TensorTypeNode>();
  if (data == nullptr) return false;

  const QnnCSIStridedSliceAttrs* param = attrs.as<QnnCSIStridedSliceAttrs>();
  CHECK(param != nullptr);

  auto dshape = data->shape;
  auto num_axis = dshape.size();

  std::vector<int64_t> stride_vec;
  for (Integer i : param->strides) {
    CHECK(i.defined());
    stride_vec.push_back(i->value);
  }
  for (size_t i = stride_vec.size(); i < num_axis; ++i) {
    stride_vec.push_back(1);
  }
  const int64_t max_range = std::numeric_limits<int64_t>::max();

  std::vector<int64_t> begin_vec;
  for (size_t i = 0; i < param->begin.size(); ++i) {
    if (!param->begin[i].defined()) {
      // value=None
      begin_vec.push_back(stride_vec[i] > 0 ? 0 : max_range);
    } else {
      begin_vec.push_back(param->begin[i]->value);
    }
  }
  for (size_t i = begin_vec.size(); i < num_axis; ++i) {
    begin_vec.push_back(stride_vec[i] > 0 ? 0 : max_range);
  }

  std::vector<int64_t> end_vec;
  for (size_t i = 0; i < param->end.size(); ++i) {
    // allow end to be None
    if (!param->end[i].defined()) {
      end_vec.push_back(stride_vec[i] < 0 ? 0 : max_range);
    } else {
      end_vec.push_back(param->end[i]->value);
    }
  }
  for (size_t i = end_vec.size(); i < num_axis; ++i) {
    end_vec.push_back(stride_vec[i] < 0 ? 0 : max_range);
  }

  std::vector<IndexExpr> oshape(dshape.size());
  for (size_t i = 0; i < num_axis; ++i) {
    int64_t stride_v = stride_vec[i];
    int64_t begin_v = begin_vec[i];
    int64_t end_v = end_vec[i];

    if ((stride_v == 1 && begin_v == 0 && end_v == max_range) ||
        (stride_v == -1 && begin_v == max_range && end_v == 0)) {
      // Quick path, do not slice this dimension.
      oshape[i] = dshape[i];
      continue;
    }
    // Normal path, require the shape to be concrete integer.
    // Require concrete integer as symbolic inference of min/max
    // can get complicated and not very helpful.
    const int64_t* p_dim_size = tir::as_const_int(dshape[i]);
    CHECK(p_dim_size) << "strided_slice requires sliced dimension to be concrete int";
    int64_t dim_size = p_dim_size[0];
    begin_v = (begin_v < 0) ? dim_size + begin_v : begin_v;
    end_v = (end_v < 0) ? dim_size + end_v : end_v;

    int64_t slice_range, step;
    if (stride_v < 0) {
      if (end_v < -1) end_v = -1;
      CHECK_LT(end_v, begin_v) << "strided_slice get empty slice at axis " << i;
      begin_v = std::min(dim_size - 1, begin_v);
      slice_range = begin_v - end_v;
      step = -stride_v;
    } else {
      if (begin_v < 0) begin_v = 0;
      CHECK_GE(stride_v, 0);
      CHECK_LT(begin_v, end_v) << "strided_slice get empty slice at axis " << i;
      end_v = std::min(dim_size, end_v);
      slice_range = end_v - begin_v;
      step = stride_v;
    }
    oshape[i] = tir::make_const(dshape[i].dtype(), (slice_range + step - 1) / step);
  }
  reporter->Assign(types[1], TensorType(oshape, data->dtype));
  return true;
}

// Positional relay function to create StridedSlice operator used by frontend FFI.
Expr MakeQnnCSIStridedSlice(Expr data, Array<Integer> begin, Array<Integer> end,
                            Array<Integer> strides, DataType out_dtype,

                            Array<Array<IndexExpr>> q_params, String layer_name) {
  auto attrs = make_object<QnnCSIStridedSliceAttrs>();
  attrs->begin = std::move(begin);
  attrs->end = std::move(end);
  attrs->strides = std::move(strides);

  attrs->out_dtype = out_dtype;
  attrs->q_params = std::move(q_params);
  attrs->layer_name = std::move(layer_name);

  static const Op& op = Op::Get("qnn.csi.strided_slice");
  return Call(op, {data}, Attrs(attrs), {});
}

RELAY_REGISTER_OP("qnn.csi.strided_slice")
    .describe(R"code(Strided slice of an array.

Examples::

  x = [[  1.,   4.,   7.,  10.],
       [  2.,   5.,   8.,  11.],
       [  3.,   6.,   9.,  12.]]

  strided_slice(x, begin=[0, 1], end=[2, 4], stride=[1, 1]) = [[ 4.,  7.,  10.],
                                                               [ 5.,  8.,  11.]]

  x = [[[ 1.,  2.],
        [ 3.,  4.]],

       [[ 5.,  6.],
        [ 7.,  8.]]]

  strided_slice(x, begin=[0, 0], end=[2, 2]) = [[[ 1.,  2.],
                                                 [ 3.,  4.]],

                                                [[ 5.,  6.],
                                                 [ 7.,  8.]]]
)code" TVM_ADD_FILELINE)
    .set_attrs_type<QnnCSIStridedSliceAttrs>()
    .set_num_inputs(1)
    .add_argument("data", "Tensor", "The quantized data tensor.")
    .set_support_level(11)
    .add_type_rel("QnnCSIStridedSliceRel", QnnCSIStridedSliceRel)
    .set_attr<TOpPattern>("TOpPattern", kOpaque);

TVM_REGISTER_GLOBAL("relay.qnn.op._make.CSIStridedSlice").set_body_typed(MakeQnnCSIStridedSlice);

}  // namespace qnn
}  // namespace relay
}  // namespace tvm
