"""Check literal ANSI port widths in the emitted Chisel/SystemVerilog RTL."""

import re
import sys
from pathlib import Path


def main():
    source = Path(sys.argv[1]).read_text()
    source = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
    modules = dict(re.findall(r"\bmodule\s+(\w+)\b(.*?)\bendmodule\b", source, re.S))
    errors = []

    def check(module, port, direction, width):
        body = modules.get(module, "")
        # CIRCT may share a direction and packed width across several names.
        declarations = re.finditer(
            r"\b(input|output|inout)\b(.*?)(?=\b(?:input|output|inout)\b|\);)",
            body.split(");", 1)[0] + ");", re.S,
        )
        for decl in declarations:
            if not re.search(rf"\b{re.escape(port)}\b", decl[2]):
                continue
            packed = re.search(r"\[\s*(\d+)\s*:\s*(\d+)\s*\]", decl[2])
            actual = abs(int(packed[1]) - int(packed[2])) + 1 if packed else 1
            if (decl[1], actual) != (direction, width):
                errors.append(f"{module}.{port}: got {decl[1]} {actual}, expected {direction} {width}")
            else:
                print(f"PASS {module}.{port}: {direction} {width} bit")
            return
        errors.append(f"Missing module/port: {module}.{port}")

    for module, prefix in (
        ("CoralNPUChiselSubsystem", "io_matrix_axi_master"),
        ("rvv_coreTlul", "io_matrix_axi_master"),
        ("rvv_coreAxi", "io_matrix_axi_master"),
        ("rvv_core", "io_matrixAxi"),
        ("MatrixCoreWrapper", "io_axi"),
    ):
        for suffix, direction, width in (
            ("read_data_bits_data", "input", 512),
            ("write_data_bits_data", "output", 512),
            ("write_data_bits_strb", "output", 64),
            ("read_addr_bits_addr", "output", 32),
            ("write_addr_bits_addr", "output", 32),
        ):
            check(module, f"{prefix}_{suffix}", direction, width)
    for port, direction, width in (
        ("m_axi_rdata_i", "input", 512),
        ("m_axi_wdata_o", "output", 512),
        ("m_axi_wstrb_o", "output", 64),
    ):
        check("MatrixCore", port, direction, width)
    check("CoralNPUChiselSubsystem", "io_ddr_mem_axi_read_data_bits_data", "input", 256)
    check("CoralNPUChiselSubsystem", "io_ddr_mem_axi_write_data_bits_data", "output", 256)
    for module in ("MatrixDma", "MatrixDmaLoad", "MatrixDmaStore", "MatrixReadDataProcess",
                   "ABMatrixReg", "ABScaleReg", "CMatrixReg", "pe_ctrl", "pe_array"):
        if module not in modules:
            errors.append(f"Missing RTL module: {module}")
    if errors:
        raise SystemExit("FAIL:\n" + "\n".join(errors))
    print("PASS: matrix AXI widths and required RTL definitions")


if __name__ == "__main__":
    main()
