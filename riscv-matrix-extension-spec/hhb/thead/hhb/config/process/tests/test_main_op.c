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

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "process.h"

void create_img_obj(struct image_data* img, uint32_t height, uint32_t width, uint32_t channel) {
  img->data = (float*)malloc(sizeof(float) * (height * width * channel));  // NOLINT
  img->shape = (uint32_t*)malloc(sizeof(uint32_t) * 3);                    // NOLINT
  img->shape[0] = height;
  img->shape[1] = width;
  img->shape[2] = channel;
  img->dim = 3;
}

void _test_imresize(uint32_t ori_height, uint32_t ori_width, uint32_t ori_channel,
                    uint32_t res_height, uint32_t res_width, uint32_t res_channel,
                    uint32_t case_index) {
  char filename[128];
  uint32_t i;
  struct image_data img;
  create_img_obj(&img, ori_height, ori_width, ori_channel);

  for (i = 0; i < get_size(img); i++) {
    img.data[i] = (rand() % (255 - 0 + 1)) + 0;  // NOLINT
  }
  snprintf(filename, sizeof(filename), "imresize%d_input_%d_%d_%d.txt", case_index, ori_height,
           ori_width, ori_channel);
  save_data_to_file(filename, img.data, get_size(img));

  imresize(&img, res_height, res_width);

  snprintf(filename, sizeof(filename), "imresize%d_output_%d_%d_%d.txt", case_index, res_height,
           res_width, res_channel);
  save_data_to_file(filename, img.data, get_size(img));

  if (img.data) free(img.data);
  if (img.shape) free(img.shape);
}

void test_imresize() {
  /* Shrinking testing */
  _test_imresize(20, 18, 3, 15, 8, 3, 1);

  /* Enlarge testing */
  _test_imresize(25, 34, 3, 40, 50, 3, 2);

  /* Shrinke one slide but enlarge another testing */
  _test_imresize(25, 34, 3, 40, 25, 3, 3);

  /* Single channel*/
  _test_imresize(25, 34, 1, 20, 40, 1, 4);

  /* Normal image*/
  _test_imresize(300, 500, 3, 224, 224, 3, 5);
}

void _test_imrgb2bgr(uint32_t ori_height, uint32_t ori_width, uint32_t ori_channel,
                     uint32_t case_index) {
  char filename[128];
  uint32_t i;
  struct image_data img;
  create_img_obj(&img, ori_height, ori_width, ori_channel);

  for (i = 0; i < get_size(img); i++) {
    img.data[i] = (rand() % (255 - 0 + 1)) + 0;  // NOLINT
  }
  snprintf(filename, sizeof(filename), "imrgb2bgr%d_input_%d_%d_%d.txt", case_index, ori_height,
           ori_width, ori_channel);
  save_data_to_file(filename, img.data, get_size(img));

  imrgb2bgr(&img);

  snprintf(filename, sizeof(filename), "imrgb2bgr%d_output_%d_%d_%d.txt", case_index, ori_height,
           ori_width, ori_channel);
  save_data_to_file(filename, img.data, get_size(img));

  if (img.data) free(img.data);
  if (img.shape) free(img.shape);
}

void test_imrgb2bgr() { _test_imrgb2bgr(224, 224, 3, 1); }

void _test_imhwc2chw(uint32_t ori_height, uint32_t ori_width, uint32_t ori_channel,
                     uint32_t case_index) {
  char filename[128];
  uint32_t i;
  struct image_data img;
  create_img_obj(&img, ori_height, ori_width, ori_channel);

  for (i = 0; i < get_size(img); i++) {
    img.data[i] = (rand() % (255 - 0 + 1)) + 0;  // NOLINT
  }
  snprintf(filename, sizeof(filename), "imhwc2chw%d_input_%d_%d_%d.txt", case_index, ori_height,
           ori_width, ori_channel);
  save_data_to_file(filename, img.data, get_size(img));

  imhwc2chw(&img);

  snprintf(filename, sizeof(filename), "imhwc2chw%d_output_%d_%d_%d.txt", case_index, ori_channel,
           ori_height, ori_width);
  save_data_to_file(filename, img.data, get_size(img));

  if (img.data) free(img.data);
  if (img.shape) free(img.shape);
}

void test_imhwc2chw() { _test_imhwc2chw(224, 224, 3, 1); }

void _test_im2rgb(uint32_t ori_height, uint32_t ori_width, uint32_t ori_channel,
                  uint32_t case_index) {
  char filename[128];
  uint32_t i;
  struct image_data img;
  create_img_obj(&img, ori_height, ori_width, ori_channel);

  for (i = 0; i < get_size(img); i++) {
    img.data[i] = (rand() % (255 - 0 + 1)) + 0;  // NOLINT
  }
  snprintf(filename, sizeof(filename), "im2rgb%d_input_%d_%d_%d.txt", case_index, ori_height,
           ori_width, ori_channel);
  save_data_to_file(filename, img.data, get_size(img));

  im2rgb(&img);

  snprintf(filename, sizeof(filename), "im2rgb%d_output_%d_%d_%d.txt", case_index, ori_height,
           ori_width, img.shape[2]);
  save_data_to_file(filename, img.data, get_size(img));

  if (img.data) free(img.data);
  if (img.shape) free(img.shape);
}

void test_im2rgb() {
  _test_im2rgb(224, 224, 1, 1);
  _test_im2rgb(224, 224, 3, 2);
  _test_im2rgb(224, 224, 4, 3);
}

void _test_sub_mean(uint32_t ori_height, uint32_t ori_width, uint32_t ori_channel, float b_mean,
                    float g_mean, float r_mean, uint32_t case_index) {
  char filename[128];
  uint32_t i;
  struct image_data img;
  create_img_obj(&img, ori_height, ori_width, ori_channel);

  for (i = 0; i < get_size(img); i++) {
    img.data[i] = (rand() % (255 - 0 + 1)) + 0;  // NOLINT
  }
  snprintf(filename, sizeof(filename), "sub_mean%d_input_%d_%d_%d_%f_%f_%f.txt", case_index,
           ori_height, ori_width, ori_channel, b_mean, g_mean, r_mean);
  save_data_to_file(filename, img.data, get_size(img));

  sub_mean(&img, b_mean, g_mean, r_mean);

  snprintf(filename, sizeof(filename), "sub_mean%d_output_%d_%d_%d_%f_%f_%f.txt", case_index,
           ori_height, ori_width, img.shape[2], b_mean, g_mean, r_mean);
  save_data_to_file(filename, img.data, get_size(img));

  if (img.data) free(img.data);
  if (img.shape) free(img.shape);
}

void test_sub_mean() {
  _test_sub_mean(224, 224, 3, 123.68, 116.779, 103.939, 1);
  _test_sub_mean(224, 224, 1, 123.68, 116.779, 103.939, 2);
}

void _test_data_scale(uint32_t ori_height, uint32_t ori_width, uint32_t ori_channel, float scale,
                      uint32_t case_index) {
  char filename[128];
  uint32_t i;
  struct image_data img;
  create_img_obj(&img, ori_height, ori_width, ori_channel);

  for (i = 0; i < get_size(img); i++) {
    img.data[i] = (rand() % (255 - 0 + 1)) + 0;  // NOLINT
  }
  snprintf(filename, sizeof(filename), "data_scale%d_input_%d_%d_%d_%f.txt", case_index, ori_height,
           ori_width, ori_channel, scale);
  save_data_to_file(filename, img.data, get_size(img));

  data_scale(&img, scale);

  snprintf(filename, sizeof(filename), "data_scale%d_output_%d_%d_%d_%f.txt", case_index,
           ori_height, ori_width, img.shape[2], scale);
  save_data_to_file(filename, img.data, get_size(img));

  if (img.data) free(img.data);
  if (img.shape) free(img.shape);
}

void test_data_scale() { _test_data_scale(224, 224, 3, 58.8, 1); }

void _test_data_crop(uint32_t ori_height, uint32_t ori_width, uint32_t ori_channel, uint32_t height,
                     uint32_t width, uint32_t case_index) {
  char filename[128];
  uint32_t i;
  struct image_data img;
  create_img_obj(&img, ori_height, ori_width, ori_channel);

  for (i = 0; i < get_size(img); i++) {
    img.data[i] = (rand() % (255 - 0 + 1)) + 0;  // NOLINT
  }
  snprintf(filename, sizeof(filename), "data_crop%d_input_%d_%d_%d_%d_%d.txt", case_index,
           ori_height, ori_width, ori_channel, height, width);
  save_data_to_file(filename, img.data, get_size(img));

  data_crop(&img, height, width);

  snprintf(filename, sizeof(filename), "data_crop%d_output_%d_%d_%d_%d_%d.txt", case_index,
           img.shape[0], img.shape[1], img.shape[2], height, width);
  save_data_to_file(filename, img.data, get_size(img));

  if (img.data) free(img.data);
  if (img.shape) free(img.shape);
}

void test_data_crop() {
  _test_data_crop(300, 400, 3, 256, 256, 1);
  _test_data_crop(5, 7, 1, 3, 3, 1);
}

int main() {
  test_imresize();
  test_imrgb2bgr();
  test_imhwc2chw();
  test_im2rgb();
  test_sub_mean();
  test_data_scale();
  test_data_crop();
  return 0;
