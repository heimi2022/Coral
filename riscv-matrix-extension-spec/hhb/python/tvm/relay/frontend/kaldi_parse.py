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
"""Kaldi frontend."""
import numpy as np


class KaldiLoader:
    """kaldi model parser"""

    def __init__(self, path):
        self.path = path
        self.infos = None
        self.model = dict()

        self.layers = []
        self.token_map = [
            "Nnet",
            "AffineTransform",
            "ParametricRelu",
            "LinearTransform",
            "Fsmn",
            "DeepFsmn",
            "Softmax",
            "ReLu",
            "RectifiedLinear",
            "LearnRateCoef",
            "AlphaLearnRateCoef",
            "!EndOfComponent",
            "/Nnet",
        ]

    def parse_token(self, txt):
        """get token name"""
        has_token = len(txt) != 0 and "<" in txt

        if not has_token:
            return None
        token_name = txt[txt.find("<") + 1 : txt.find(">")]

        if token_name not in self.token_map:
            raise Exception(f"Seems you have a new layer {token_name} which is not supported.")

        return token_name

    def parse(self, path):
        """parse kaldi model"""
        layer_info = []
        with open(path, "r") as f:
            while True:
                txt = f.readline()
                token = self.parse_token(txt)

                if token == "Nnet":
                    continue
                if token == "/Nnet":
                    break

                current_layer = {}
                current_layer["token"] = token
                current_layer["size_settings"] = txt[txt.find(">") + 1 : -1]
                current_layer["other_settings"] = f.readline().strip()
                check_token = self.parse_token(current_layer["other_settings"])

                if check_token == "!EndOfComponent":
                    if token in ["Softmax", "ReLu"]:
                        current_layer["data"] = []
                        layer_info.append(current_layer)
                    continue

                if check_token not in ["LearnRateCoef", "AlphaLearnRateCoef"]:
                    raise Exception(f"Expect token of LearnRateCoef, but get {check_token}")

                current_layer["data"] = []
                matrix_start = token == "Fsmn"

                while True:
                    line = f.readline().strip()
                    if self.parse_token(line) == "!EndOfComponent":
                        break

                    if "[" in line or matrix_start:
                        matrix_start = False
                        data = []
                        single_line = line.find("[") == len(line) - 1
                        if single_line:
                            continue
                        line = line.replace("[", "").strip()
                    row = []
                    for i in line.split(" "):
                        if i != "]":
                            row.append(float(i))
                        else:
                            current_layer["data"].append(data)
                    data.append(row)

                layer_info.append(current_layer)
        self.infos = layer_info

    def size_to_int(self, size_settings):
        """get size list"""
        str_size = size_settings.strip().split(" ")
        size = [int(i) if i != "" else 0 for i in str_size]
        return size

    def attrs_process(self, settings):
        """convert attrs"""
        settings = settings.strip().replace("[", "")
        str_setting = settings.strip().split(" ")
        out = {}
        len_str = len(str_setting)
        if len_str == 1:
            return out
        for i in range(0, len(str_setting), 2):
            kind = str_setting[i].replace("<", "").replace(">", "")
            value = str_setting[i + 1]
            out[kind] = int(value)

        return out

    def reshape_data(self, token, data, size, other_settings):
        """reshape data to right shape"""
        if token in ["AffineTransform", "LinearTransform"]:
            data[0] = data[0].reshape(size[0], size[1])
        if token == "Fsmn":
            data[0] = data[0].reshape(other_settings["LOrder"], size[0])
            data[1] = data[1].reshape(other_settings["ROrder"], size[1])
        return data

    def to_dict(self):
        """convert infos to layer"""
        for layer in self.infos:
            token = layer["token"]
            size_settings = layer["size_settings"]
            other_settings = layer["other_settings"]
            float_datas = [np.array(data, dtype="float32") for data in layer["data"]]
            size_settings = self.size_to_int(size_settings)
            other_settings = self.attrs_process(other_settings)
            reshaped_data = self.reshape_data(token, float_datas, size_settings, other_settings)
            self.layers.append(
                {
                    "token": token,
                    "size_settings": size_settings,
                    "data": reshaped_data,
                    "other_settings": other_settings,
                }
            )

    def load(self):
        self.parse(self.path)
        self.to_dict()
        return self.layers
