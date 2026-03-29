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

import os

import numpy as np
import cv2


def init_tests():
    os.system("make clean")
    os.system("make")
    os.system("./test_main_op")


def _test_imresize(inputfile, outputfile):
    input_data = np.fromfile(inputfile, sep="\n").astype(np.float32)
    h, w, c = inputfile.split(".")[0].split("_")[-3:]
    h, w, c = int(h), int(w), int(c)
    input_data = np.reshape(input_data, (h, w, c))

    h, w, c = outputfile.split(".")[0].split("_")[-3:]
    h, w, c = int(h), int(w), int(c)
    actual_output = cv2.resize(input_data, (w, h))
    if c == 1:
        actual_output = np.expand_dims(actual_output, axis=2)

    real_output = np.fromfile(outputfile, sep="\n").astype(np.float32)
    real_output = np.reshape(real_output, (h, w, c))

    np.testing.assert_allclose(actual_output, real_output, atol=1e-2, rtol=1e-2)


def test_imresize():
    # Shrinking testing
    _test_imresize("imresize1_input_20_18_3.txt", "imresize1_output_15_8_3.txt")

    # Enlarge testing
    _test_imresize("imresize2_input_25_34_3.txt", "imresize2_output_40_50_3.txt")

    # Shrinke one slide but enlarge another testing
    _test_imresize("imresize3_input_25_34_3.txt", "imresize3_output_40_25_3.txt")

    # Single channel
    _test_imresize("imresize4_input_25_34_1.txt", "imresize4_output_20_40_1.txt")

    # Normal image
    _test_imresize("imresize5_input_300_500_3.txt", "imresize5_output_224_224_3.txt")

    print("imresize func testing pass!")


def _test_imrgb2bgr(inputfile, outputfile):
    input_data = np.fromfile(inputfile, sep="\n").astype(np.float32)
    h, w, c = inputfile.split(".")[0].split("_")[-3:]
    h, w, c = int(h), int(w), int(c)
    input_data = np.reshape(input_data, (h, w, c))

    h, w, c = outputfile.split(".")[0].split("_")[-3:]
    h, w, c = int(h), int(w), int(c)
    actual_output = input_data[:, :, ::-1]

    real_output = np.fromfile(outputfile, sep="\n").astype(np.float32)
    real_output = np.reshape(real_output, (h, w, c))

    np.testing.assert_allclose(actual_output, real_output, atol=1e-5, rtol=1e-5)


def test_imrgb2bgr():
    _test_imrgb2bgr("imrgb2bgr1_input_224_224_3.txt", "imrgb2bgr1_output_224_224_3.txt")

    print("imrgb2bgr func testing pass!")


def _test_imhwc2chw(inputfile, outputfile):
    input_data = np.fromfile(inputfile, sep="\n").astype(np.float32)
    h, w, c = inputfile.split(".")[0].split("_")[-3:]
    h, w, c = int(h), int(w), int(c)
    input_data = np.reshape(input_data, (h, w, c))

    c, h, w = outputfile.split(".")[0].split("_")[-3:]
    c, h, w = int(c), int(h), int(w)

    actual_output = np.transpose(input_data, (2, 0, 1))

    real_output = np.fromfile(outputfile, sep="\n").astype(np.float32)
    real_output = np.reshape(real_output, (c, h, w))

    np.testing.assert_allclose(actual_output, real_output, atol=1e-5, rtol=1e-5)


def test_imhwc2chw():
    _test_imhwc2chw("imhwc2chw1_input_224_224_3.txt", "imhwc2chw1_output_3_224_224.txt")

    print("imhwc2chw func testing pass!")


def _test_im2rgb(inputfile, outputfile):
    input_data = np.fromfile(inputfile, sep="\n").astype(np.float32)
    h, w, c = inputfile.split(".")[0].split("_")[-3:]
    h, w, c = int(h), int(w), int(c)
    input_data = np.reshape(input_data, (h, w, c))

    h, w, c = outputfile.split(".")[0].split("_")[-3:]
    h, w, c = int(h), int(w), int(c)

    if input_data.shape[2] == 3:
        actual_output = input_data
    if input_data.shape[2] == 1:
        actual_output = np.concatenate([input_data] * 3, axis=2)
    if input_data.shape[2] == 4:
        actual_output = input_data[:, :, :3]

    real_output = np.fromfile(outputfile, sep="\n").astype(np.float32)
    real_output = np.reshape(real_output, (h, w, c))

    np.testing.assert_allclose(actual_output, real_output, atol=1e-5, rtol=1e-5)


def test_im2rgb():
    _test_im2rgb("im2rgb1_input_224_224_1.txt", "im2rgb1_output_224_224_3.txt")
    _test_im2rgb("im2rgb2_input_224_224_3.txt", "im2rgb2_output_224_224_3.txt")
    _test_im2rgb("im2rgb3_input_224_224_4.txt", "im2rgb3_output_224_224_3.txt")

    print("im2rgb func testing pass!")


def _test_sub_mean(inputfile, outputfile):
    input_data = np.fromfile(inputfile, sep="\n").astype(np.float32)
    h, w, c, b, g, r = inputfile.split(".txt")[0].split("_")[-6:]
    h, w, c = int(h), int(w), int(c)
    b, g, r = float(b), float(g), float(r)
    input_data = np.reshape(input_data, (h, w, c))

    if c == 1:
        actual_output = input_data - np.array([b], dtype=np.float32)
    else:
        actual_output = input_data - np.array([b, g, r], dtype=np.float32)

    real_output = np.fromfile(outputfile, sep="\n").astype(np.float32)
    real_output = np.reshape(real_output, (h, w, c))

    np.testing.assert_allclose(actual_output, real_output, atol=1e-5, rtol=1e-5)


def test_sub_mean():
    _test_sub_mean(
        "sub_mean1_input_224_224_3_123.680000_116.778999_103.939003.txt",
        "sub_mean1_output_224_224_3_123.680000_116.778999_103.939003.txt",
    )
    _test_sub_mean(
        "sub_mean2_input_224_224_1_123.680000_116.778999_103.939003.txt",
        "sub_mean2_output_224_224_1_123.680000_116.778999_103.939003.txt",
    )

    print("sub_mean func testing pass!")


def _test_data_scale(inputfile, outputfile):
    input_data = np.fromfile(inputfile, sep="\n").astype(np.float32)
    h, w, c, scale = inputfile.split(".txt")[0].split("_")[-4:]
    h, w, c = int(h), int(w), int(c)
    scale = float(scale)
    input_data = np.reshape(input_data, (h, w, c))

    actual_output = input_data * scale

    real_output = np.fromfile(outputfile, sep="\n").astype(np.float32)
    real_output = np.reshape(real_output, (h, w, c))

    np.testing.assert_allclose(actual_output, real_output, atol=1e-5, rtol=1e-5)


def test_data_scale():
    _test_data_scale(
        "data_scale1_input_224_224_3_58.799999.txt", "data_scale1_output_224_224_3_58.799999.txt"
    )

    print("sub_scale func testing pass!")


def _test_data_crop(inputfile, outputfile):
    input_data = np.fromfile(inputfile, sep="\n").astype(np.float32)
    h, w, c, new_height, new_width = inputfile.split(".txt")[0].split("_")[-5:]
    h, w, c = int(h), int(w), int(c)
    new_height = int(new_height)
    new_width = int(new_width)
    input_data = np.reshape(input_data, (h, w, c))

    starth = h // 2 - new_height // 2
    startw = w // 2 - new_width // 2
    actual_output = input_data[starth : starth + new_height, startw : startw + new_width, :]

    real_output = np.fromfile(outputfile, sep="\n").astype(np.float32)
    real_output = np.reshape(real_output, (new_height, new_width, c))

    np.testing.assert_allclose(actual_output, real_output, atol=1e-5, rtol=1e-5)


def test_data_crop():
    _test_data_crop(
        "data_crop1_input_300_400_3_256_256.txt", "data_crop1_output_256_256_3_256_256.txt"
    )
    _test_data_crop("data_crop1_input_5_7_1_3_3.txt", "data_crop1_output_3_3_1_3_3.txt")

    print("data_crop func testing pass!")


if __name__ == "__main__":
    init_tests()

    test_imresize()
    test_imrgb2bgr()
    test_imhwc2chw()
    test_im2rgb()
    test_sub_mean()
    test_data_scale()
    test_data_crop()
