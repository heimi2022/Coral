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
"""Manage main command."""
import logging
import os
import numpy as np
import tvm
from tvm.contrib import graph_executor

from .arguments_manage import ArgumentFilter
from .frontend_manage import import_model, insert_preprocess_node
from .common import ensure_dir, AttributeDict, HHBException, generate_config_file
from .hhbir_manage import (
    HHBRelayIR,
    HHBQNNIR,
    HHBFloatCodegenIR,
    HHBX86QnnCodegenIR,
    HHBBoardQnnCodegenIR,
    get_input_info_from_relay,
    get_output_info_from_relay,
    reorder_pixel_format,
)
from .quantization_manage import (
    collect_quantization_config,
    set_quantize_params_by_board,
    get_config_dict,
    update_hybrid_layer,
    ignore_layers_from_auto_quant,
)
from .preprocess_manage import (
    collect_preprocess_config,
    set_preprocess_params,
    DatasetLoader,
)
from .codegen_manage import collect_codegen_config, set_codegen_config
from .simulate_manage import inference_model


LOG = 25
logger = logging.getLogger("HHB")


def generate_dataset(args_filter: ArgumentFilter):
    """Generate preprocessed dataset"""
    input_shape = args_filter.filtered_args.input_shape
    assert len(input_shape) == 1, "Unsupport for multi-inputs"

    # filter arguments and prepare all needed args
    all_filters = [
        collect_preprocess_config,
        set_preprocess_params,
    ]
    extra_args = AttributeDict()
    extra_args.input_shape = input_shape
    args_filter.filter_argument(all_filters, extra=extra_args)
    args = args_filter.filtered_args

    if not args.simulate_data:
        raise HHBException("Please set simulate data by --simulate-data\n")

    logger.info("get simulate data from %s", args.simulate_data)
    dl = DatasetLoader(
        args.simulate_data,
        args.preprocess_config,
        input_shape,
        [""],
    )

    index = 0
    dataset = dl.get_data()
    for d in dataset:
        data = list(d.values())[0]
        filename = os.path.basename(dl.all_file_path[index])
        filename, _ = os.path.splitext(filename)
        data = data.astype("float32")
        data.tofile(os.path.join(args.output, filename + ".tensor"), "\n")
        data.tofile(os.path.join(args.output, filename + ".bin"))

        index += 1


def driver_main_command(args_filter: ArgumentFilter):
    """Driver main command"""
    args = args_filter.filtered_args
    args.output = ensure_dir(args.output)

    if args.generate_config:
        generate_config_file(os.path.join(args.output, "cmd_params.yml"))
        if not (args.E or args.Q or args.C or args.simulate):
            return 0

    if args.generate_dataset:
        generate_dataset(args_filter)
        return 0

    if not (args.E or args.Q or args.C or args.simulate):
        raise HHBException("No subcommand select.\n")

    #######################################################################
    #
    # Execute '-E' command
    #
    logger.log(LOG, "Start import model.")
    mod, params = import_model(
        args.model_file, args.model_format, args.input_name, args.input_shape, args.output_name
    )

    if args.reorder_pixel_format:
        mod, params = reorder_pixel_format(mod, params)

        if args.pixel_format == "RGB":
            args.pixel_format = "BGR"
        else:
            args.pixel_format = "RGB"

        if args.data_mean:
            args.data_mean = args.data_mean[::-1]

    logger.debug("Relay model:")
    logger.debug(mod["main"])
    logger.log(LOG, "Model import completed! ")
    relay_ir = HHBRelayIR()
    relay_ir.set_model(mod, params)

    if args.E or args.save_temps:
        relay_ir.save_model(args.output)

    if args.E:
        return 0

    #######################################################################
    #
    # Execute '-Q' command
    #
    input_name_list, input_shape_list, _ = get_input_info_from_relay(mod, params)
    output_shape_list, _ = get_output_info_from_relay(mod, params)
    # filter arguments and prepare all needed args
    all_filters = [
        collect_preprocess_config,
        set_preprocess_params,
        collect_quantization_config,
        set_quantize_params_by_board,
        collect_codegen_config,
        set_codegen_config,
    ]
    extra_args = AttributeDict()
    extra_args.input_shape = input_shape_list
    extra_args.input_num = len(input_shape_list)
    extra_args.output_num = len(output_shape_list)
    extra_args.model_save = args.model_save
    args_filter.filter_argument(all_filters, extra=extra_args)
    args = args_filter.filtered_args

    # add preprocess node into mod
    if args.preprocess_config.add_preprocess_node:
        mod, params = insert_preprocess_node(
            mod, params, args.preprocess_config.data_mean, args.preprocess_config.data_scale
        )
        logger.debug("Insert preprocess node into model successfully!")

    config_dict = get_config_dict(args)

    if not args.no_quantize:
        logger.log(LOG, "Start quantization.")
        dataset_list = []
        if args.calibrate_dataset:
            logger.log(LOG, "get calibrate dataset from %s", args.calibrate_dataset)
            dl = DatasetLoader(
                args.calibrate_dataset, args.preprocess_config, input_shape_list, input_name_list
            )
            dataset = dl.get_data()
            for d in dataset:
                dataset_list.append(d)

        qnn_ir = HHBQNNIR()
        qnn_ir.convert((mod, params), config_dict, dataset_list, args.board)
        logger.log(LOG, "Quantization completed!")
        if args.Q or args.save_temps:
            qnn_ir.save_model(args.output, args.preprocess_config, config_dict)
        if args.Q:
            return 0
    else:
        if args.Q:
            raise HHBException("can not set '-Q' and '--no_quantize' at the same time.\n")

    #######################################################################
    #
    # Execute '-C' command
    #
    target_board_list = (
        "anole",
        "light",
        "hlight",
        "asp",
        "i805",
        "c860",
        "e907",
        "c906",
        "rvm",
        "c908",
    )
    config_dict = get_config_dict(args)
    if config_dict["auto_hybrid_quantization"]:
        update_hybrid_layer(config_dict, args.output)

        limited_layer = ignore_layers_from_auto_quant(qnn_ir.get_model()[0], config_dict["target"])
        logger.info(
            "These layers will be removed from hybrid quant list: {}".format(
                set(config_dict["hybrid_layer_name"]) & set(limited_layer)
            )
        )
        config_dict["hybrid_layer_name"] = list(
            set(config_dict["hybrid_layer_name"]) - set(limited_layer)
        )

        if args.quantize_config.ignore_hybrid_layer:
            config_dict["hybrid_layer_name"] = list(
                set(config_dict["hybrid_layer_name"])
                - set(args.quantize_config.ignore_hybrid_layer)
            )
    light_input_fix_size = args.codegen_config.light_input_fix_size
    is_x86 = True
    if args.board == "x86_ref":
        if args.no_quantize:
            x86_codegen_ir = HHBFloatCodegenIR()
            x86_codegen_ir.convert((mod, params), args.board, args.opt_level)
        else:
            x86_codegen_ir = HHBX86QnnCodegenIR()
            x86_codegen_ir.convert(
                qnn_ir.get_model(), args.board, args.opt_level, args.output, config_dict
            )
    elif args.board in target_board_list:
        is_x86 = False
        if args.no_quantize:
            raise HHBException(
                "can not set '--no-quantize' with '--board {}'.\n".format(args.board)
            )
        board_codegen_ir = HHBBoardQnnCodegenIR()

        board_codegen_ir.convert(
            qnn_ir.get_model(),
            args.board,
            args.opt_level,
            args.output,
            config_dict,
        )
    else:
        raise HHBException("unsupport for board: {}.\n".format(args.board))

    if args.C or args.save_temps:
        if args.board == "x86_ref":
            x86_codegen_ir.save_model(args.output)
        elif args.board in target_board_list:
            input_name_list, input_shape_list, _ = get_input_info_from_relay(
                qnn_ir.get_model()[0], None
            )
            board_codegen_ir.save_model(
                input_shape_list,
                output_shape_list,
                args.board,
                args.output,
                args.postprocess,
                args.codegen_config.model_save,
                args.codegen_config.without_preprocess,
                args.preprocess_config,
                args.codegen_config.multithread,
                args.codegen_config.input_memory_type,
                args.quantize_config.quantization_scheme,
                args.codegen_config,
            )

            # save part data in calibrate dataset into tensor file
            data_count = 0
            for k in input_name_list:
                if not dataset_list:
                    break
                safe_k = k.replace("/", "_")
                v = dataset_list[0][k]
                v = v.astype("float32")
                if args.target_layout == "NHWC":
                    v = v.transpose([0, 2, 3, 1])
                v.tofile(os.path.join(args.output, safe_k + ".{}.tensor".format(data_count)), "\n")
                v.tofile(os.path.join(args.output, safe_k + ".{}.bin".format(data_count)))
                if len(light_input_fix_size) == 2:
                    v = np.pad(
                        v,
                        (
                            (0, 0),
                            (0, 0),
                            (0, int(light_input_fix_size[0]) - v.shape[2]),
                            (0, int(light_input_fix_size[1]) - v.shape[3]),
                        ),
                        "constant",
                    )
                    v.tofile(
                        os.path.join(args.output, safe_k + ".{}.pad.tensor".format(data_count)),
                        "\n",
                    )
                    v.tofile(os.path.join(args.output, safe_k + ".{}.pad.bin".format(data_count)))
                data_count += 1
        elif args.board in ("i805"):
            # generate function map
            board_codegen_ir.save_model(
                input_shape_list,
                output_shape_list,
                args.board,
                args.output,
            )
            # save part data in calibrate dataset into tensor file
            data_count = 0
            input_name_list, _, _ = get_input_info_from_relay(qnn_ir.get_model()[0], None)
            for k in input_name_list:
                safe_k = k.replace("/", "_")
                v = dataset_list[0][k]
                v = v.astype("float32")
                scale = (v.max() - v.min()) / 255
                zp = int(0.0 - v.min() / scale)
                v = v / scale + zp
                v = v.astype("uint8")
                if args.target_layout == "NHWC":
                    v = v.transpose([0, 2, 3, 1])
                v.tofile(os.path.join(args.output, safe_k + ".{}.tensor".format(data_count)), "\n")
                v.tofile(os.path.join(args.output, safe_k + ".{}.bin".format(data_count)))
                data_count += 1

    if args.C:
        return 0

    #######################################################################
    #
    # Execute '--simulate' command
    #
    if not is_x86:
        raise HHBException("{} don't support for simulation.\n".format(args.board))
    if not args.simulate_data:
        raise HHBException("Please set simulate data by --simulate-data.\n")

    logger.info("get simulate data from %s", args.simulate_data)

    ctx = tvm.cpu(0)
    if args.no_quantize:
        m = graph_executor.GraphModule(x86_codegen_ir.get_model()["default"](ctx))
    else:
        factory = x86_codegen_ir.get_factory()
        lib = x86_codegen_ir.get_lib(args.output)
        m = tvm.contrib.graph_executor.create(factory.get_graph_json(), lib, tvm.cpu(0))
        m.load_params(tvm.runtime.save_param_dict(factory.get_params()))

    dl = DatasetLoader(
        args.simulate_data,
        args.preprocess_config,
        input_shape_list,
        input_name_list,
        target_layout=args.target_layout,
    )
    inference_model(m, dl, args.postprocess, args.output)
