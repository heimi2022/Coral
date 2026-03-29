# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.


#####################################################
#                      im2col                       #
#####################################################
# def convert_conv(self, op):
#     params = self._parse_conv_params(op)
#     weight_bias_blobs = self.init_layer_dict[op.name].blobs
#     conv_params = op.convolution_param
#     inputs = op.bottom
#     # process weight and bias blobs
#     weight, bias = None, None
#     if len(weight_bias_blobs) > 1:
#         weight = weight_bias_blobs[0]
#         bias = weight_bias_blobs[1]
#     else:
#         weight = weight_bias_blobs[0]
#     if weight:
#         kh, kw = params['kernel_size']
#         weight_shape = [conv_params.num_output, -1, kh, kw]
#         weight_value = np.asarray(weight.data, np.float32)
#         weight_value = np.reshape(weight_value, weight_shape)
#     else:
#         raise Exception('No weight value of layer {} in caffemodel'.format(
#             op.name))
#     N, C, W, H = _infer_shape(in_expr)
#     pad_h, pad_w = params["padding"]
#     stride_h, stride_w = params["strides"]
#     k_h, k_w = params["kernel_size"]
#     output_size_h = int(np.floor((W + 2 * pad_h - k_h) / stride_h + 1))
#     output_size_w = int(np.floor((W + 2 * pad_w - k_w) / stride_w + 1))

#     # padding
#     in_expr = _op.nn.pad(in_expr,
#                          pad_width=((0, 0), (0, 0), (pad_h, pad_h), (pad_w,
#                                                                      pad_w)))

#     # gather_nd index
#     temp_n = []
#     temp_x = []
#     temp_y = []
#     temp_channel = []
#     for w in range(output_size_w):
#         for h in range(output_size_h):
#             x = np.arange(w * stride_h, w * stride_h + k_h)
#             z = np.arange(h * stride_w, h * stride_w + k_w)
#             y = np.arange(0, C)
#             xv, yv, zv = np.meshgrid(x, y, z)
#             temp_x.append(xv.reshape(-1))
#             temp_y.append(zv.reshape(-1))
#             temp_channel.append(yv.reshape(-1))

#     for n in range(N):
#         temp_n = np.append(
#             temp_n, np.full(output_size_h * output_size_w * k_h * k_w * C, n))

#     temp = np.stack(
#         (temp_n, np.array(temp_channel).reshape(-1),
#          np.array(temp_x).reshape(-1), np.array(temp_y).reshape(-1)))
#     index_expr = self.exp_tab.new_const(temp, dtype='float32')

#     # get input value
#     re_input = _op.transform.gather_nd(in_expr, index_expr)
#     re_input = _op.reshape(re_input,
#                            (1, output_size_h * output_size_w, k_h * k_w * C))

#     # weight
#     if len(weight_bias_blobs) > 1:
#         weight = weight_bias_blobs[0]
#         bias = weight_bias_blobs[1]
#     else:
#         weight = weight_bias_blobs[0]
#     if weight:
#         kh, kw = params['kernel_size']
#         weight_shape = [params['channels'], kh * kw * C]

#         weight_value = np.asarray(weight.data, np.float32)
#         weight_value = np.reshape(weight_value,
#                                   (1, weight_shape[0], weight_shape[1]))
#     else:
#         raise Exception('No weight value of layer {} in caffemodel'.format(
#             op.name))

#     weight_expr = self.exp_tab.new_const(weight_value, dtype='float32')

#     # matmul
#     out = _op.nn.batch_matmul(re_input, weight_expr)
#     out = _op.transpose(out, (0, 2, 1))

#     out = _op.reshape(out,
#                       (N, params['channels'], output_size_h, output_size_w))
#     if bias:
#         bias_value = np.asarray(bias.data, np.float32)
#         bias_expr = self.exp_tab.new_const(bias_value, dtype='float32')
#         out = _op.nn.bias_add(out, bias_expr, axis=params["axis"])
#     return out
