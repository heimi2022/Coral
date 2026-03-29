#!/bin/bash
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


set -euo pipefail

mkdir -p llvm_build
mkdir -p llvm_install

SRC_BASE=$PWD

cd llvm_build

# LLVM_INSTALL_UTILS install utilities to install directory
cmake ../../llvm-project/llvm/ -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="$SRC_BASE/llvm_install" -DCMAKE_BUILD_TYPE=Release -DLLVM_INSTALL_UTILS=ON -DLLVM_TARGETS_TO_BUILD="X86;ARM;AArch64" -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD="RISCV"
#cmake --build. --target install
make -j32
make install
echo "Build LLVM " "$SRC_BASE/llvm_install"
