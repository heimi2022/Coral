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
""" HHB Command Line Tools """
import argparse
import logging
import sys
import os
import json

from .core.arguments_manage import ArgumentManage, CommandType, HHBException, ArgumentFilter
from .core.arguments_manage import update_arguments_by_file, get_default_config, AttributeDict
from .core.common import ALL_ARGUMENTS_INFO, import_module_for_register, collect_arguments_info
from .core.common import ArgInfo, ALL_ARGUMENTS_DESC
from .core.main_command_manage import driver_main_command


LOG = 25
logging.addLevelName(LOG, "LOG")


def hhb_set_debug_level(level="LOG"):
    """Set debug level.

    Parameters
    ----------
    level : str
        The debug level string, select from: LOG, DEBUG, INFO, WARNING and ERROR.

    """
    if level == "LOG":
        level_num = 25
    elif level == "INFO":
        level_num = 20
    elif level == "DEBUG":
        level_num = 10
    elif level == "WARNING":
        level_num = 30
    else:
        level_num = 40
    logging.basicConfig(
        format="[%(asctime)s] (%(name)s %(levelname)s): %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
    )
    logger = logging.getLogger("HHB")
    logger.setLevel(level_num)


def hhb_compile(hhb_config_file, **kwargs):
    """It includes all procedures that compile model with hhb: import->quantize->codegen->run.

    Parameters
    ----------
    hhb_config_file : str
        The path of config file.

    kwargs : dict
        Other values which will overwirte values in hhb_config_file.
    """
    base_config, _ = get_default_config()

    with open(hhb_config_file, "r") as f:
        usr_config = json.load(f)

    for sec, value in usr_config.items():
        base_config[sec].update(value)

    # unroll arguments
    unroll_config = AttributeDict()
    for sec, value in base_config.items():
        unroll_config.update(value)

    if kwargs:
        unroll_config.update(kwargs)

    args_filter = ArgumentFilter(unroll_config)
    driver_main_command(args_filter)


def _main(argv):
    """HHB commmand line interface."""
    arg_manage = ArgumentManage(argv)
    arg_manage.check_cmd_arguments()

    parser = argparse.ArgumentParser(
        prog="HHB",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="HHB command line tools",
        epilog=__doc__,
        allow_abbrev=False,
        add_help=False,
    )

    # add command line parameters
    curr_command_type = arg_manage.get_command_type()
    if curr_command_type == CommandType.SUBCOMMAND:
        arg_manage.set_subcommand(parser)
    else:
        arg_manage.set_main_command(parser)
        ALL_ARGUMENTS_DESC["main_command"] = collect_arguments_info(parser._actions)

    # print help info
    if arg_manage.have_help:
        arg_manage.print_help_info(parser)
        return 0

    # generate readme file
    if arg_manage.have_generate_readme:
        arg_manage.generate_readme(parser)
        return 0

    # parse command line parameters
    args = parser.parse_args(arg_manage.origin_argv[1:])
    if args.config_file:
        update_arguments_by_file(args, arg_manage.origin_argv[1:])
    args_filter = ArgumentFilter(args)

    # config logger
    logging.basicConfig(
        format="[%(asctime)s] (%(name)s %(levelname)s): %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
    )
    logger = logging.getLogger("HHB")
    logger.setLevel(25 - args.verbose * 10)

    # run command
    arg_manage.run_command(args_filter, curr_command_type)


def main():
    try:
        argv = sys.argv
        sys.exit(_main(argv))
    except KeyboardInterrupt:
        print("\nCtrl-C detected.")


if __name__ == "__main__":
    main()
