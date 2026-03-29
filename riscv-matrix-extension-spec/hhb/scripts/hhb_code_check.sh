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

set -e
set -u
set -o pipefail

cleanup()
{
  rm -rf /tmp/$$.*
}
trap cleanup 0

py_file=""
cpp_file=""
IFSBAK=$IFS
for i in $@
do
    origin=$i
    IFS="."
    arr=($i)
    if [ ${arr[1]} == "py" ];then
        py_file=${py_file}" ${origin}"
    elif [[ ${arr[1]} == "cc" || ${arr[1]} == "c" || ${arr[1]} == "h" || ${arr[1]} == "hpp" ]];then
        cpp_file=${cpp_file}" ${origin}"
    else
        echo "Unsupport for .${arr[1]}"
    fi
done
IFS=$IFSBAK

if [ "${cpp_file}" != "" ];then
    echo "Check codestyle of c++ code..."
    last_ret=0
    python3 3rdparty/dmlc-core/scripts/lint.py tvm cpp ${cpp_file} || last_ret=$? || true
    if [ ${last_ret} -ne 0 ];then
        echo "Please run 'docker/bash.sh tvmai/ci-lint:v0.61 clang-format-10 -i <file-path>' to format the code firstly."
        exit 1
    fi
fi

if [ "${py_file}" != "" ];then
    echo "Check codestyle of python code..."
    last_ret=0
    python3 -m pylint ${py_file} --rcfile=tests/lint/pylintrc || last_ret=$? || true
    if [ ${last_ret} -ne 0 ];then
        echo "Please run 'yapf --style scripts/yapf_style.cfg -i <file-path>' to format the code firstly."
        exit 1
    fi
fi
