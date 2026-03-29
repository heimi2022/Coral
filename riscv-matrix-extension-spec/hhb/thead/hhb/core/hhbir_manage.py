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
"""Manage HHB IR"""
import os
import sys
import logging
from abc import ABC
from abc import abstractmethod
import yaml
import shutil

import tvm
from tvm import relay
from tvm import runtime
from tvm.relay import quantize as qtz
from tvm.relay.backend import executor_factory
from tvm.contrib import graph_runtime
from tvm.ir.tensor_type import TensorType
from tvm.ir.type import TupleType
from tvm.relay.op.contrib import csinn

from .common import (
    HHBException,
    get_target,
    hhb_ir_helper,
    HHB_IR,
    AttributeDict,
)


# pylint: disable=invalid-name
logger = logging.getLogger("HHB")


def match_mod_params(mod, params):
    """The params of module's main function match the params dict."""
    if not params:
        return mod, params
    var_name_list = []
    for arg in mod["main"].params:
        if arg.name_hint not in var_name_list:
            var_name_list.append(arg.name_hint)
    params_new = {}
    flag = False
    for k in params.keys():
        if k not in var_name_list and ("v" + k) in var_name_list:
            flag = True
            break

    if flag:
        logger.debug("mod does not match params, and try to update the params dict...")
        for k, v in params.items():
            if k not in var_name_list and ("v" + k) in var_name_list:
                params_new["v" + k] = v
            else:
                params_new[k] = v
        params = params_new

    return mod, params


def get_input_info_from_relay(mod, params):
    input_name_list = []
    input_shape_list = []
    input_dtype_list = []

    for arg in mod["main"].params:
        if (not params) or arg.name_hint not in params.keys():
            input_name_list.append(str(arg.name_hint))
            input_shape_list.append(list(map(int, arg.type_annotation.shape)))
            input_dtype_list.append(str(arg.type_annotation.dtype))

    return input_name_list, input_shape_list, input_dtype_list


def get_output_info_from_relay(mod, params):
    output_shape_list = []
    output_dtype_list = []

    # convert dynamic node into static node.
    mod_main_old = mod["main"]
    from tvm.relay.quantize.quantize_hhb import _bind_params

    if params:
        mod["main"] = _bind_params(mod["main"], params)
    with tvm.transform.PassContext(opt_level=2):
        mod = relay.transform.DynamicToStatic()(mod)

    if isinstance(mod["main"].ret_type, TupleType):
        for item in mod["main"].ret_type.fields:
            output_shape_list.append(list(map(int, item.shape)))
            output_dtype_list.append(str(item.dtype))
    elif isinstance(mod["main"].ret_type, TensorType):
        output_shape_list.append(list(map(int, mod["main"].ret_type.shape)))
        output_dtype_list.append(str(mod["main"].ret_type.dtype))
    else:
        raise HHBException("unsupport for {}".format(type(mod["main"].ret_type)))

    mod["main"] = mod_main_old
    return output_shape_list, output_dtype_list


def check_included_filename(model_path, hhbir):
    """Check whether included all files exists."""
    for k in hhbir.all_included_filenames:
        if not os.path.exists(os.path.join(model_path, k)):
            raise HHBException("There is no {} in {}".format(k, model_path))


def reorder_pixel_format(mod, params):
    """If original model's input data pixel format is rgb, then covert it to bgr,
    otherwise, then convert it to rgb.

    Parameters
    ----------
    mod : tvm.IRModule
        The relay module for compilation
    params : dict of str to tvm.nd.NDArray
        The parameter dict to be used by relay

    Returns
    -------
    mod : tvm.IRModule
        The modified relay module
    params : dict of str to tvm.nd.NDArray
        The modified parameter dict to be used by relay
    """

    class InnerVisitor(relay.ExprVisitor):
        """Counting the number of call"""

        def __init__(self):
            super(InnerVisitor, self).__init__()
            self.weight_name = []

        def visit_call(self, call):
            _ = [self.visit(arg) for arg in call.args]

            pre_call = call.args[0]
            if call.op.name == "nn.conv2d" and isinstance(pre_call, relay.expr.Var):

                weight = call.args[1]
                self.weight_name.append(weight.name_hint)

    iv = InnerVisitor()
    iv.visit(mod["main"])
    to_change = iv.weight_name

    for name in to_change:
        data = params[name].asnumpy()
        if data.shape[1] != 3:
            continue
        data = data[:, ::-1, :, :]
        params[name].copyfrom(data)
    return mod, params


class HHBIRType(object):
    """Denote the HHB IR type"""

    UNKNOWN = -1
    RELAY = 0
    QNN = 1
    FLOAT_CODEGEN = 2
    X86_QNN_CODEGEN = 3
    BOARD_QNN_CODEGEN = 4

    TYPE2NAME = {
        UNKNOWN: "unknown",
        RELAY: "relay",
        QNN: "qnn",
        FLOAT_CODEGEN: "float_codegen",
        X86_QNN_CODEGEN: "x86_qnn_codegen",
        BOARD_QNN_CODEGEN: "board_qnn_codegen",
    }
    NAME2TYPE = {v: k for k, v in TYPE2NAME.items()}


class HHBIRBase(ABC):
    """Abstract class for HHB command line interface.

    Provide a unified way to convert and save HHB model.

    """

    def __init__(self):
        self.all_included_filenames = []

    @staticmethod
    @abstractmethod
    def name():
        """IR name"""

    @staticmethod
    @abstractmethod
    def model_type():
        """IR type"""

    @abstractmethod
    def load_model(self, model_path):
        """Load a model from a given path.

        Parameters
        ----------
        model_path : str
            Path to a tar file
        """

    @abstractmethod
    def convert(self):
        """Convert input module into current stage."""

    @abstractmethod
    def save_model(self, model_path):
        """Save current module into files."""

    def check_ir_type(self, model_path):
        files = os.listdir(model_path)
        res = True
        for f in self.all_included_filenames:
            if f not in files:
                res = False
                break
        return res


@hhb_ir_helper
class HHBRelayIR(HHBIRBase):
    def __init__(self):
        super().__init__()
        self.mod_name = "relay.txt"
        self.params_name = "relay.params"

        self.all_included_filenames.extend([self.mod_name, self.params_name])

        self._mod = None
        self._params = None

    @staticmethod
    def name():
        return HHBIRType.TYPE2NAME[HHBIRType.RELAY]

    @staticmethod
    def model_type():
        return HHBIRType.RELAY

    def set_model(self, mod, params):
        self._mod = mod
        self._params = params

    def get_model(self):
        return self._mod, self._params

    def load_model(self, model_path):
        mod_path = os.path.join(model_path, self.mod_name)
        params_path = os.path.join(model_path, self.params_name)
        check_included_filename(model_path, self)
        with open(mod_path, "r") as f:
            mod = tvm.parser.fromtext(f.read())
        with open(params_path, "rb") as f:
            params = tvm.relay.load_param_dict(f.read())
        self._mod, self._params = match_mod_params(mod, params)

    def convert(self):
        pass

    def save_model(self, model_path):
        """Save current module into files."""
        assert self._mod, "Error: empty module."
        if not os.path.exists(model_path):
            raise HHBException("Directory {} is not exists".format(model_path))
        mod_path = os.path.join(model_path, self.mod_name)
        params_path = os.path.join(model_path, self.params_name)

        with open(mod_path, "w") as f:
            logger.info("exporting relay ir to {}".format(f.name))
            f.write(self._mod.astext())

        with open(params_path, "wb") as f:
            logger.info("exporting relay params to {}".format(f.name))
            f.write(tvm.relay.save_param_dict(self._params))


@hhb_ir_helper
class HHBQNNIR(HHBIRBase):
    def __init__(self):
        super().__init__()
        self.mod_name = "qnn.txt"
        self.params_name = "qnn.params"

        self.info_file = "qnn_info.yaml"
        self.info_dict = {}

        self.all_included_filenames.extend([self.mod_name])

        self._curr_mod = None
        self._curr_params = None

    @staticmethod
    def name():
        return HHBIRType.TYPE2NAME[HHBIRType.QNN]

    @staticmethod
    def model_type():
        return HHBIRType.QNN

    def get_model(self):
        return self._curr_mod, self._curr_params

    def load_model(self, model_path):
        mod_path = os.path.join(model_path, self.mod_name)
        params_path = os.path.join(model_path, self.params_name)
        # ensure all needed files existing
        check_included_filename(model_path, self)
        with open(mod_path, "r") as f:
            self._curr_mod = tvm.parser.fromtext(f.read())
            logger.info("restore qnn ir from %s" % mod_path)
        if os.path.exists(params_path):
            with open(params_path, "rb") as f:
                self._curr_params = tvm.relay.load_param_dict(f.read())
                logger.info("restore relay params from %s" % params_path)
        self._curr_mod, self._curr_params = match_mod_params(self._curr_mod, self._curr_params)

        if os.path.exists(os.path.join(model_path, self.info_file)):
            with open(os.path.join(model_path, self.info_file), "r") as f:
                info_dict = yaml.safe_load(f.read())
                self.info_dict["preprocess"] = AttributeDict(**info_dict["preprocess"])
                self.info_dict["qnn_config"] = AttributeDict(**info_dict["qnn_config"])

    def convert(self, input_module, qconfig, dataset=None, target="x86_ref"):
        if (
            not isinstance(input_module, (list, tuple))
            and not isinstance(input_module[0], tvm.ir.module.IRModule)
            and not isinstance(input_module[1], dict)
        ):
            raise HHBException("input_module should be [IRModule, dict]")

        from .quantization_manage import quantize_model

        qconfig["target"] = target
        qconfig["params_path"] = os.path.join(qconfig["params_path"], self.params_name)
        self._curr_mod = quantize_model(input_module[0], input_module[1], qconfig, dataset, target)

    def save_model(self, model_path, preprocess_params=None, config_dict=None):
        """Save current module into files."""
        assert self._curr_mod, "Error: empty module."
        if not os.path.exists(model_path):
            raise HHBException("Directory {} is not exists".format(model_path))
        mod_path = os.path.join(model_path, self.mod_name)
        params_path = os.path.join(model_path, self.params_name)

        with open(mod_path, "w") as f:
            logger.info("exporting qnn ir to {}".format(f.name))
            f.write(self._curr_mod.astext())

        if self._curr_params:
            with open(params_path, "wb") as f:
                logger.info("exporting qnn params to {}".format(f.name))
                f.write(tvm.relay.save_param_dict(self._curr_params))
        # if need, save extra info, which will be used in codegen stage
        info_path = os.path.join(model_path, self.info_file)
        if preprocess_params:
            logger.info("write preprocess info into %s" % info_path)
            with open(info_path, "w") as f:
                yaml.safe_dump({"preprocess": dict(preprocess_params)}, f, default_flow_style=False)

        if config_dict:
            logger.info("write quantization info into %s" % info_path)
            with open(info_path, "a") as f:
                yaml.safe_dump({"qnn_config": config_dict}, f, default_flow_style=False)


@hhb_ir_helper
class HHBFloatCodegenIR(HHBIRBase):
    def __init__(self):
        super().__init__()
        self.graph_name = "codegen_x86_float.json"
        self.lib_name = "codegen_x86_float.so"
        self.params_name = "codegen_x86_float.params"
        self.info_file = "codegen_x86_float.yaml"

        self._curr_module = None
        self.info_dict = {}

        self.all_included_filenames.extend([self.graph_name, self.lib_name, self.params_name])

    @staticmethod
    def name():
        return HHBIRType.TYPE2NAME[HHBIRType.FLOAT_CODEGEN]

    @staticmethod
    def model_type():
        return HHBIRType.FLOAT_CODEGEN

    def get_model(self):
        return self._curr_module

    def load_model(self, model_path):
        graph_path = os.path.join(model_path, self.graph_name)
        lib_path = os.path.join(model_path, self.lib_name)
        params_path = os.path.join(model_path, self.params_name)
        # ensure all needed files existing
        check_included_filename(model_path, self)

        graph = open(graph_path).read()
        params = bytearray(open(params_path, "rb").read())
        lib = runtime.load_module(lib_path)

        ctx = tvm.cpu(0)
        module = graph_runtime.create(graph, lib, ctx)
        module.load_params(params)

        self._curr_module = module

        if os.path.exists(os.path.join(model_path, self.info_file)):
            with open(os.path.join(model_path, self.info_file), "r") as f:
                self.info_dict = yaml.safe_load(f.read())

    def convert(self, input_module, board, opt_level):
        if (
            not isinstance(input_module, (list, tuple))
            and not isinstance(input_module[0], tvm.ir.module.IRModule)
            and not isinstance(input_module[1], dict)
        ):
            raise HHBException("input_module should be [IRModule, dict]")

        target = "llvm"
        model = relay.transform.DynamicToStatic()(input_module[0])
        with tvm.transform.PassContext(opt_level=opt_level):
            logger.info("building relay graph without quantization")
            self._curr_module = relay.build(model, target=target, params=input_module[1])

        (
            input_name_list,
            input_shape_list,
            input_dtype_list,
        ) = get_input_info_from_relay(input_module[0], input_module[1])
        output_shape_list, output_dtype_list = get_output_info_from_relay(
            input_module[0], input_module[1]
        )
        self.info_dict = {
            "input_name_list": input_name_list,
            "input_shape_list": input_shape_list,
            "input_dtype_list": input_dtype_list,
            "output_shape_list": output_shape_list,
            "output_dtype_list": output_dtype_list,
        }

    def save_model(self, model_path):
        """Save current module into files."""
        if not isinstance(self._curr_module, executor_factory.GraphExecutorFactoryModule):
            raise HHBException("need GraphExecutorFactoryModule")
        if not os.path.exists(model_path):
            raise HHBException("Directory {} is not exists".format(model_path))

        graph_path = os.path.join(model_path, self.graph_name)
        lib_path = os.path.join(model_path, self.lib_name)
        params_path = os.path.join(model_path, self.params_name)

        logger.info("write lib to %s", lib_path)
        self._curr_module.get_lib().export_library(lib_path)

        with open(graph_path, "w") as f:
            logger.info("write graph to %s", f.name)
            f.write(self._curr_module.get_graph_json())
        with open(params_path, "wb") as f:
            logger.info("write params to %s", f.name)
            f.write(relay.save_param_dict(self._curr_module.get_params()))

        if self.info_dict:
            info_path = os.path.join(model_path, self.info_file)
            logger.info("write extra info in %s" % info_path)
            with open(info_path, "w") as f:
                yaml.safe_dump(self.info_dict, f, default_flow_style=False)


@hhb_ir_helper
class HHBX86QnnCodegenIR(HHBIRBase):
    def __init__(self):
        super().__init__()
        self.lib_name = "codegen_x86_quant.so"
        self.lib_source_name = "lib0.c"
        self.params_name = "codegen_x86_quant.params"
        self.info_file = "codegen_x86_quant.yaml"

        self._curr_factory = None
        self._curr_module = None
        self.info_dict = {}

        self.all_included_filenames.extend([self.lib_name, self.lib_source_name, self.params_name])

    @staticmethod
    def name():
        return HHBIRType.TYPE2NAME[HHBIRType.X86_QNN_CODEGEN]

    @staticmethod
    def model_type():
        return HHBIRType.X86_QNN_CODEGEN

    def get_model(self):
        return self._curr_module

    def get_factory(self):
        return self._curr_factory

    def get_lib(self, output_dir):
        def _find_install_libs():
            tvm_package_dir = os.path.dirname(os.path.realpath(tvm.__file__))
            install_dir = []
            # TVM is run inplace
            install_dir.append(os.path.join(tvm_package_dir, "..", "..", "install_nn2"))
            # TVM is installed
            install_dir.append(os.path.join(tvm_package_dir, "install_nn2"))

            install_dir = [d for d in install_dir if os.path.isdir(d)]
            if len(install_dir) == 0:
                raise HHBException("Can not fild install_nn2 libs.")
            return install_dir[0]

        if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
            exec_dir = os.path.dirname(os.path.realpath(sys.executable))

            include_path = os.path.join(exec_dir, "install_nn2", "include")
            ref_x86_dir = os.path.join(exec_dir, "install_nn2", "lib")
        else:
            install_dir = _find_install_libs()

            include_path = os.path.join(install_dir, "include")
            ref_x86_dir = os.path.join(install_dir, "lib")
        lib_path = os.path.join(output_dir, "quant.so")
        kwargs = {}
        kwargs["options"] = [
            "-O2",
            "-g",
            "-I" + include_path,
            "-L" + ref_x86_dir,
            "-lshl_ref_x86",
        ]
        kwargs["cc"] = "gcc"
        lib = self.get_factory().get_lib()
        lib.export_library(lib_path, fcompile=False, workspace_dir=output_dir, **kwargs)
        lib = tvm.runtime.load_module(lib_path)
        return lib

    def load_model(self, model_path, module=None):
        raise HHBException("Unsupport x86 QNN model load")

    def set_quant_env(self, info_file):
        if not info_file:
            return
        with open(info_file, "r") as f:
            info_dict = yaml.safe_load(f.read())
            qconfig = qtz.qconfig(**info_dict["qnn_config"])
            with qconfig:
                logger.debug("restore quantization config from %s" % info_file)

    def get_quant_env(self, info_file):
        if not info_file:
            return
        with open(info_file, "r") as f:
            info_dict = yaml.safe_load(f.read())
        return info_dict["qnn_config"]

    def convert(self, input_module, board, opt_level, output_path, device_config):
        if (
            not isinstance(input_module, (list, tuple))
            and not isinstance(input_module[0], tvm.ir.module.IRModule)
            and not isinstance(input_module[1], dict)
            and input_module[1] is not None
        ):
            raise HHBException("input_module should be [IRModule, dict or None]")

        target = get_target(board)

        params_file = os.path.join(output_path, self.params_name)
        device_config["params_path"] = params_file

        mod = input_module[0]
        params = input_module[1]

        func = mod["main"]
        func = func.with_attr("global_symbol", tvm.runtime.container.String("csinn"))
        func = func.with_attr("Compiler", "csinn")
        mod["csinn_0"] = func

        logger.info("write params to %s", params_file)

        with tvm.transform.PassContext(
            opt_level=opt_level, config={"relay.ext.csinn.options": device_config}
        ):
            mod = csinn.partition_for_csinn(mod, params)
            factory = relay.build(mod, target=target, params=params)

        lib = factory.get_lib()
        self._curr_factory = factory
        self._curr_module = lib

        (
            input_name_list,
            input_shape_list,
            input_dtype_list,
        ) = get_input_info_from_relay(input_module[0], input_module[1])
        output_shape_list, output_dtype_list = get_output_info_from_relay(
            input_module[0], input_module[1]
        )
        self.info_dict = {
            "input_name_list": input_name_list,
            "input_shape_list": input_shape_list,
            "input_dtype_list": input_dtype_list,
            "output_shape_list": output_shape_list,
            "output_dtype_list": output_dtype_list,
        }

    def save_model(self, model_path):
        """Save current module into files."""
        contrib_dir = os.path.dirname(os.path.realpath(os.path.expanduser(__file__)))
        source_dir = os.path.join(contrib_dir, "..", "..", "..")
        include_path = os.path.join(source_dir, "install_nn2", "include")

        lib_path = os.path.join(model_path, self.lib_name)
        kwargs = {}
        kwargs["options"] = ["-O0", "-g3", "-I" + include_path]
        logger.info("write lib to %s" % lib_path)
        self._curr_module.export_hhb_library(
            lib_path, fcompile=False, output_dir=model_path, **kwargs
        )

        info_path = os.path.join(model_path, self.info_file)
        logger.info("write extra info to %s" % info_path)
        with open(info_path, "w") as f:
            yaml.safe_dump(self.info_dict, f, default_flow_style=False)


def fcompile(filename, files, options=None):
    shutil.copy(files[0], filename)


@hhb_ir_helper
class HHBBoardQnnCodegenIR(HHBIRBase):
    def __init__(self, without_preprocess=False):
        super().__init__()
        self.mod = None
        self.params_name = "model.params"
        self.graph_info_name = "graph_info.bin"
        self.lib_source_name = "model.c"
        self.main_source_name = "main.c"
        self.preprocess_source_name = "process.c"
        self.preprocess_header_name = "process.h"
        self.preio_source_name = "io.c"
        self.preio_header_name = "io.h"

        self.all_included_filenames.extend(
            [
                self.params_name,
                self.graph_info_name,
                self.lib_source_name,
                self.main_source_name,
                self.preprocess_source_name,
                self.preprocess_header_name,
            ]
        )

        if not without_preprocess:
            self.all_included_filenames.extend([self.preio_source_name, self.preio_header_name])

    @staticmethod
    def name():
        return HHBIRType.TYPE2NAME[HHBIRType.BOARD_QNN_CODEGEN]

    @staticmethod
    def model_type():
        return HHBIRType.BOARD_QNN_CODEGEN

    def get_model(self):
        return self._curr_module

    def load_model(self, model_path):
        pass

    def set_quant_env(self, info_file):
        if not info_file:
            return
        with open(info_file, "r") as f:
            info_dict = yaml.safe_load(f.read())
            qconfig = qtz.qconfig(**info_dict["qnn_config"])
            with qconfig:
                logger.debug("restore quantization config from %s" % info_file)

    def get_quant_env(self, info_file):
        if not info_file:
            return
        with open(info_file, "r") as f:
            info_dict = yaml.safe_load(f.read())
        return info_dict["qnn_config"]

    def convert(
        self,
        input_module,
        board,
        opt_level,
        output_path,
        device_config,
    ):
        mod, params = input_module
        self.mod = mod
        target = get_target(board)

        params_file = os.path.join(output_path, self.params_name)
        graph_info_file = os.path.join(output_path, self.graph_info_name)
        device_config["params_path"] = params_file
        device_config["graph_info_path"] = graph_info_file

        func = mod["main"]
        func = func.with_attr("global_symbol", tvm.runtime.container.String("csinn"))
        func = func.with_attr("Compiler", "csinn")
        mod["csinn_0"] = func

        logger.info("write params to %s", params_file)
        logger.debug("Generate trace data by {} strategy".format(device_config["trace_strategy"]))
        logger.debug(
            "Set the memory type of input tenosr as: {}".format(device_config["input_memory_type"])
        )
        logger.debug(
            "Set the memory type of output tenosr as: {}".format(
                device_config["output_memory_type"]
            )
        )

        with tvm.transform.PassContext(
            opt_level=opt_level, config={"relay.ext.csinn.options": device_config}
        ):
            mod = csinn.partition_for_csinn(mod, params)
            factory = relay.build(mod, target=target, params=params)

        lib = factory.get_lib()
        self._curr_module = lib
        lib_path = os.path.join(output_path, self.lib_source_name)
        logger.info("write lib source code to %s", lib_path)
        factory.export_library(lib_path, fcompile=fcompile)

    def save_model(
        self,
        input_shape,
        output_shape,
        board,
        output_path,
        postprocess="top5",
        model_save="run_only",
        without_preprocess=False,
        preprocess_params=None,
        multithread=False,
        input_memory_type=None,
        q_scheme=None,
        codegen_config=None,
    ):
        from .codegen_manage import (
            main_c_codegen,
            generate_func_map,
            generate_c906_cb_reg,
            generate_rvv_cb_reg,
        )

        if board == "i805":
            dump_file_path = os.path.join(output_path, "cb_map.c")
            logger.info("write bc map code to %s", dump_file_path)
            generate_func_map(self.mod, board, dump_file_path)
            return
        elif board == "c906" and codegen_config.dynamic_cb_reg:
            dump_file_path = os.path.join(output_path, "cb_reg.c")
            logger.info("write bc reg to %s", dump_file_path)
            opks = generate_c906_cb_reg(self.mod, board, dump_file_path, q_scheme)
            dump_file_path = os.path.join(output_path, "cb_rvv.c")
            logger.info("write bc rvv to %s", dump_file_path)
            opks = generate_rvv_cb_reg(False, dump_file_path, q_scheme, opks)

        main_c_codegen(
            self,
            input_shape,
            output_shape,
            board,
            output_path,
            postprocess,
            model_save,
            without_preprocess,
            preprocess_params,
            multithread,
            input_memory_type,
            q_scheme,
        )

        from .codegen_manage import package_sections

        package_sections(board, output_path, model_save)


def guess_ir_type(file_path):
    """
    Get IR type according to the files in file_path

    Parameters
    ----------
    file_path : str
        The directroy that hold module files

    Returns
    -------
    res : HHBIRType
        Inferred IR type
    """
    hhb_ir_type = []
    for h in HHB_IR:
        hhb_ir_obj = h()
        hhb_ir_type.append(int(hhb_ir_obj.check_ir_type(file_path)))

    if sum(hhb_ir_type) == 0:
        return HHBIRType.UNKNOWN
    elif sum(hhb_ir_type) == 1:
        idx = hhb_ir_type.index(1)
        return HHB_IR[idx].model_type()
    else:
        raise HHBException("There are more than one hhb ir detected...")
