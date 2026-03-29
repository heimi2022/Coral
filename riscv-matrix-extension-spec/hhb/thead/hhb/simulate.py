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
# pylint: disable=unnecessary-comprehension
"""
Simulate the imported model in x86.
"""
import logging
import tarfile
import tempfile
import os
import yaml

import numpy as np

import tvm
from tvm import runtime
from tvm.contrib import graph_executor

from .core.arguments_manage import (
    add_simulate_argument,
    add_common_argument,
    add_postprocess_argument,
    add_preprocess_argument,
    ArgumentFilter,
)
from .core.common import (
    hhb_register_parse,
    HHBException,
    ensure_dir,
    AttributeDict,
    print_top5,
    generate_config_file,
    ALL_ARGUMENTS_DESC,
    collect_arguments_info,
)
from .core.hhbir_manage import (
    guess_ir_type,
    HHBIRType,
    HHBRelayIR,
    HHBQNNIR,
    HHBFloatCodegenIR,
    HHBX86QnnCodegenIR,
)
from .core.preprocess_manage import collect_preprocess_config, set_preprocess_params, DatasetLoader
from .core.simulate_manage import inference_model

# pylint: disable=invalid-name
logger = logging.getLogger("HHB")


def hhb_runner(codgen_ir, hhb_config, quantized=False):
    """Wrapper for hhb runner.

    Parameters
    ----------
    codegen_ir : HHBFloatCodegenIR or HHBX86QnnCodegenIR
        The codegened model.
    hhb_config : dict
        The config data for hhb.You can get this config by `set_hhb_config`
    quantized : bool
        The flag that implies whether the model is quantized.

    Returns
    -------
    ret : GraphModule
        The object that can be executed for x86_ref

    """
    ctx = tvm.cpu(0)
    if not quantized:
        m = graph_executor.GraphModule(codgen_ir.get_model()["default"](ctx))
    else:
        factory = codgen_ir.get_factory()
        lib = codgen_ir.get_lib(hhb_config.output)
        m = tvm.contrib.graph_executor.create(factory.get_graph_json(), lib, tvm.cpu(0))
        m.load_params(tvm.runtime.save_param_dict(factory.get_params()))

    return m


def hhb_inference(graph_module, dataset):
    """Inference for hhb model.

    Parameters
    ----------
    graph_module : GraphModule
        The object that can be executed for x86_ref
    dataset : Dict[str, numpy.ndarray]
        The input data

    Returns
    -------
    output : List[numpy.ndarray]
        The output data.
    """
    graph_module.run(**dataset)
    output = []
    for i in range(graph_module.get_num_outputs()):
        out = graph_module.get_output(i).asnumpy()
        output.append(out)
    return output


@hhb_register_parse
def add_simulate_parser(subparsers):
    """Include parser for 'simulate' subcommand"""

    parser = subparsers.add_parser("simulate", help="Simulate the imported model")
    parser.set_defaults(func=driver_simulate)

    add_simulate_argument(parser)
    add_preprocess_argument(parser)
    add_postprocess_argument(parser)
    add_common_argument(parser)

    parser.add_argument("-v", "--verbose", action="count", default=0, help="Increase verbosity")
    parser.add_argument("FILE", help="Directory to the model file")

    ALL_ARGUMENTS_DESC["simulate"] = collect_arguments_info(parser._actions)


def driver_simulate(args_filter: ArgumentFilter):
    """Driver simulate command"""
    args = args_filter.filtered_args
    if not os.path.exists(args.FILE) or not os.path.isdir(args.FILE):
        raise HHBException("The directory is not exists: {}\n".format(args.FILE))
    model_type = guess_ir_type(args.FILE)
    logger.debug("Infer the ir type: %s in %s" % (HHBIRType.TYPE2NAME[model_type], args.FILE))

    # filter arguments and prepare all needed args
    all_filters = [
        collect_preprocess_config,
        set_preprocess_params,
    ]
    extra_args = AttributeDict()

    codegen_ir = None
    curr_module = None
    if model_type == HHBIRType.FLOAT_CODEGEN:
        codegen_ir = HHBFloatCodegenIR()
    elif model_type == HHBIRType.X86_QNN_CODEGEN:
        codegen_ir = HHBX86QnnCodegenIR()
    else:
        raise HHBException(
            "{} IR don't support for simulation.".format(HHBIRType.TYPE2NAME[model_type])
        )

    codegen_ir.load_model(args.FILE)
    curr_module = codegen_ir.get_model()
    info_dict = codegen_ir.info_dict

    extra_args.input_shape = info_dict["input_shape_list"]
    args_filter.filter_argument(all_filters, extra=extra_args)
    args = args_filter.filtered_args

    if not args.simulate_data:
        raise HHBException("Please set simulate data by --simulate-data")

    logger.info("get simulate data from %s", args.simulate_data)
    dl = DatasetLoader(
        args.simulate_data,
        args.preprocess_config,
        info_dict["input_shape_list"],
        info_dict["input_name_list"],
    )

    inference_model(curr_module, dl, args.postprocess, args.output)

    if args.generate_config:
        args.output = ensure_dir(args.output)
        generate_config_file(os.path.join(args.output, "cmd_simulate_params.yml"))
