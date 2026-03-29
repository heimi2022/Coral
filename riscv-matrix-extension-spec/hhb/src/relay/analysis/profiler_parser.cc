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
 * \file profiler_parser.cc
 * \brief ai trace data parser implementations.
 */

#include "profiler_parser.h"

#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

void AiTraceVersion::Parse(const std::vector<char> data) {
  if (data.empty() || data[0] != AI_TRACE_VERSION) {
    std::cout << "this is not version data." << std::endl;
    return;
  }
  major_ = data[1] & 0b00001111;
  minor_ = data[2];
  patch_ = data[3];

  version_str_ =
      std::to_string(major_) + "." + std::to_string(minor_) + "." + std::to_string(patch_);
}

std::vector<char> AiTraceVersion::Dump() {
  std::vector<char> res;

  char version_header = AI_TRACE_VERSION;
  char major = major_ & 0b00001111;

  res.push_back(version_header);
  res.push_back(major);
  res.push_back(minor_);
  res.push_back(patch_);

  return res;
}

void AiTraceCalAmountData::Parse(const std::vector<char>& data) {
  if (data.empty() || data.size() != (CAL_AMOUNT_IND_BYTE_NUM + 1)) {
    std::cout << "this is not calculation amount data." << std::endl;
    return;
  }

  uint64_t indicator;
  std::memcpy(&indicator, data.data() + 1, CAL_AMOUNT_IND_BYTE_NUM);
  switch (data[0]) {
    case AI_TRACE_FUSED_MUL_ADD_NUM:
      fused_mul_add_ = indicator;
      break;
    case AI_TRACE_MUL_NUM:
      mul_ = indicator;
      break;
    case AI_TRACE_DIV_NUM:
      div_ = indicator;
      break;
    case AI_TRACE_ADD_NUM:
      add_ = indicator;
      break;
    case AI_TRACE_SUB_NUM:
      sub_ = indicator;
      break;
    case AI_TRACE_EXP_NUM:
      exp_ = indicator;
      break;
    case AI_TRACE_COMP_NUM:
      comp_ = indicator;
      break;
    default:
      std::cout << "unrecognize calculation amount data." << std::endl;
      break;
  }
}

std::vector<char> AiTraceCalAmountData::Dump(uint8_t type) {
  std::vector<char> res;
  char ind_header = static_cast<char>(type);
  res.push_back(ind_header);

  uint64_t data = 0;
  switch (type) {
    case AI_TRACE_FUSED_MUL_ADD_NUM:
      data = add_;
      break;
    case AI_TRACE_MUL_NUM:
      data = mul_;
      break;
    case AI_TRACE_DIV_NUM:
      data = div_;
      break;
    case AI_TRACE_ADD_NUM:
      data = add_;
      break;
    case AI_TRACE_SUB_NUM:
      data = sub_;
      break;
    case AI_TRACE_EXP_NUM:
      data = exp_;
      break;
    case AI_TRACE_COMP_NUM:
      data = comp_;
      break;
    default:
      break;
  }

  char value[CAL_AMOUNT_IND_BYTE_NUM];
  std::memcpy(value, &data, CAL_AMOUNT_IND_BYTE_NUM);
  for (int i = 0; i < CAL_AMOUNT_IND_BYTE_NUM; i++) {
    res.push_back(value[i]);
  }

  return res;
}

void AiTraceMemory::Parse(const std::vector<char>& data) {
  if (data.empty() || data.size() != (MEMORY_IND_BYTE_NUM + 1)) {
    std::cout << "this is not calculation amount data." << std::endl;
    return;
  }

  uint64_t indicator;
  std::memcpy(&indicator, data.data() + 1, MEMORY_IND_BYTE_NUM);
  switch (data[0]) {
    case AI_TRACE_PARAMS_NUM:
      params_ = indicator;
      break;
    case AI_TRACE_OUTPUT_NUM:
      output_ = indicator;
      break;
    default:
      std::cout << "unrecognize memory data." << std::endl;
      break;
  }
}

std::vector<char> AiTraceMemory::Dump(uint8_t type) {
  std::vector<char> res;
  char ind_header = static_cast<char>(type);
  res.push_back(ind_header);

  uint64_t data = 0;
  switch (type) {
    case AI_TRACE_PARAMS_NUM:
      data = params_;
      break;
    case AI_TRACE_OUTPUT_NUM:
      data = output_;
      break;
    default:
      break;
  }

  char value[MEMORY_IND_BYTE_NUM];
  std::memcpy(value, &data, MEMORY_IND_BYTE_NUM);
  for (int i = 0; i < MEMORY_IND_BYTE_NUM; i++) {
    res.push_back(value[i]);
  }

  return res;
}

void AiTraceBlock::Parse(const std::vector<char>& data) {
  size_t index = 0;
  if (data.empty() || (data[index] != AI_TRACE_INSN_TYPE && data[index] != AI_TRACE_INSN_NAME)) {
    std::cout << "ai trace block is empty." << std::endl;
    return;
  }
  // instruction type and name
  for (int i = 0; i < 2; i++) {
    if (data[index] == AI_TRACE_INSN_TYPE) {
      std::memcpy(&insn_type_, data.data() + index + 1, INSN_TYPE_BYTE_NUM);
      index += (INSN_TYPE_BYTE_NUM + 1);
    } else if (data[index] == AI_TRACE_INSN_NAME) {
      insn_name_ = std::string(data.data() + index + 1, INSN_NAME_BYTE_NUM);
      index += (INSN_NAME_BYTE_NUM + 1);
    }
  }
  if (data[index] == AI_TRACE_PARAMS_NUM || data[index] == AI_TRACE_OUTPUT_NUM) {
    // calculation amount
    at_cal_data_.have_cal_data_ = true;
    for (size_t i = index; i < data.size() - 1; i += (CAL_AMOUNT_IND_BYTE_NUM + 1)) {
      std::vector<char> tmp_data;
      tmp_data.insert(tmp_data.begin(), data.begin() + i,
                      data.begin() + i + (CAL_AMOUNT_IND_BYTE_NUM + 1));

      at_cal_data_.Parse(tmp_data);
    }
  } else {
    // memory data
    at_mem_data_.have_mem_data_ = true;
    for (size_t i = index; i < data.size() - 1; i += (MEMORY_IND_BYTE_NUM + 1)) {
      std::vector<char> tmp_data;
      tmp_data.insert(tmp_data.begin(), data.begin() + i,
                      data.begin() + i + (MEMORY_IND_BYTE_NUM + 1));

      at_mem_data_.Parse(tmp_data);
    }
  }
}

std::vector<char> AiTraceBlock::Dump() {
  std::vector<char> res;
  if (insn_type_ == 0 && insn_name_ == "") {
    std::cout << "there is no data in AiTraceBlock instance, so can not be dumped." << std::endl;
    return res;
  }
  if (insn_type_ != NOOP) {
    res.push_back(AI_TRACE_INSN_TYPE);
    char value[2];
    std::memcpy(value, &insn_type_, INSN_TYPE_BYTE_NUM);
    for (int i = 0; i < INSN_TYPE_BYTE_NUM; i++) {
      res.push_back(value[i]);
    }
  }
  if (insn_name_ != "") {
    res.push_back(AI_TRACE_INSN_NAME);
    char value[INSN_NAME_BYTE_NUM] = {'\0'};
    std::memcpy(value, insn_name_.data(), insn_name_.size());
    for (int i = 0; i < INSN_NAME_BYTE_NUM; i++) {
      res.push_back(value[i]);
    }
  }
  std::vector<char> tmp;
  // dump calculation amount data
  if (at_cal_data_.have_cal_data_) {
    tmp = at_cal_data_.Dump(AI_TRACE_FUSED_MUL_ADD_NUM);
    res.insert(res.end(), tmp.begin(), tmp.end());
    tmp = at_cal_data_.Dump(AI_TRACE_MUL_NUM);
    res.insert(res.end(), tmp.begin(), tmp.end());
    tmp = at_cal_data_.Dump(AI_TRACE_DIV_NUM);
    res.insert(res.end(), tmp.begin(), tmp.end());
    tmp = at_cal_data_.Dump(AI_TRACE_ADD_NUM);
    res.insert(res.end(), tmp.begin(), tmp.end());
    tmp = at_cal_data_.Dump(AI_TRACE_EXP_NUM);
    res.insert(res.end(), tmp.begin(), tmp.end());
    tmp = at_cal_data_.Dump(AI_TRACE_COMP_NUM);
    res.insert(res.end(), tmp.begin(), tmp.end());
    tmp = at_cal_data_.Dump(AI_TRACE_SUB_NUM);
    res.insert(res.end(), tmp.begin(), tmp.end());
  }
  // dump memory data
  if (at_mem_data_.have_mem_data_) {
    tmp = at_mem_data_.Dump(AI_TRACE_PARAMS_NUM);
    res.insert(res.end(), tmp.begin(), tmp.end());
    tmp = at_mem_data_.Dump(AI_TRACE_OUTPUT_NUM);
    res.insert(res.end(), tmp.begin(), tmp.end());
  }

  return res;
}

void AiTraceData::Parse(const std::vector<char>& data) {
  if (data.empty()) {
    std::cout << "ai trace data is empty." << std::endl;
    return;
  }
  std::vector<char> version_data;
  version_data.insert(version_data.begin(), data.begin(), data.begin() + VERSION_BYTE_NUM + 1);
  at_version_.Parse(version_data);

  size_t start_index = VERSION_BYTE_NUM + 1;
  size_t index = start_index;
  do {
    index++;
    if (data[index] == AI_TRACE_INSN_TYPE || index == data.size()) {
      std::vector<char> block_data;
      block_data.insert(block_data.begin(), data.begin() + start_index, data.begin() + index);

      AiTraceBlock tmp_at_block;
      tmp_at_block.Parse(block_data);
      at_block_.push_back(tmp_at_block);

      start_index = index;
    }
  } while (index < data.size());
}

std::vector<char> AiTraceData::Dump() {
  std::vector<char> res;

  std::vector<char> version_data = at_version_.Dump();
  res.insert(res.end(), version_data.begin(), version_data.end());

  std::vector<char> block_data;
  for (auto block : at_block_) {
    block_data = block.Dump();
    res.insert(res.end(), block_data.begin(), block_data.end());
  }
  return res;
}

void AiTraceData::ToFile(std::string path) {
  std::vector<char> data = Dump();

  std::ofstream fs;
  fs.open(path, std::ios::out | std::ios::binary);
  fs.write(data.data(), data.size());
  fs.close();
}
