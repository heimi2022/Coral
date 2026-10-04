#!/usr/bin/env python3
"""Assemble the frozen CoralNPU matrix mnemonics into 32-bit words.

This is intentionally a small, target-specific assembler front end.  It
does not claim to be a replacement for RISC-V gas: it translates Coral
matrix instructions into ``.word`` directives or little-endian raw words so
that the existing RISC-V toolchain can assemble/link the surrounding code.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable

from matrix_encode_reference import (
    MEMORY_FAMILIES,
    MZERO_COUNTS,
    encode_config,
    encode_matmul,
    encode_memory,
    encode_mzero,
)


WIDTH_TO_CODE = {8: 0, 16: 1, 32: 2, 64: 3}
COUNT_TO_CODE = {count: code for code, count in MZERO_COUNTS.items()}
MEMORY_PREFIXES = {
    "a": ("mlae", "msae", 0),
    "b": ("mlbe", "msbe", 1),
    "c": ("mlce", "msce", 2),
    "whole": ("mlme", "msme", 3),
    "at": ("mlate", "msate", 4),
    "bt": ("mlbte", "msbte", 5),
    "ct": ("mlcte", "mscte", 6),
}

SCALAR_ALIASES = {
    "zero": 0,
    "ra": 1,
    "sp": 2,
    "gp": 3,
    "tp": 4,
    "t0": 5,
    "t1": 6,
    "t2": 7,
    "s0": 8,
    "fp": 8,
    "s1": 9,
    "a0": 10,
    "a1": 11,
    "a2": 12,
    "a3": 13,
    "a4": 14,
    "a5": 15,
    "a6": 16,
    "a7": 17,
    "s2": 18,
    "s3": 19,
    "s4": 20,
    "s5": 21,
    "s6": 22,
    "s7": 23,
    "s8": 24,
    "s9": 25,
    "s10": 26,
    "s11": 27,
    "t3": 28,
    "t4": 29,
    "t5": 30,
    "t6": 31,
}


def parse_int(token: str) -> int:
    try:
        return int(token, 0)
    except ValueError as exc:
        raise ValueError(f"expected integer, got {token!r}") from exc


def parse_scalar(token: str) -> int:
    name = token.strip().lower()
    if name.startswith("x") and name[1:].isdigit():
        value = int(name[1:])
    elif name in SCALAR_ALIASES:
        value = SCALAR_ALIASES[name]
    else:
        raise ValueError(f"invalid scalar register {token!r}")
    if not 0 <= value <= 31:
        raise ValueError(f"scalar register out of range: {token!r}")
    return value


def parse_matrix(token: str, expected: str | None = None) -> int:
    """Parse a logical matrix name or an explicit raw matrix register.

    ``a0``/``b0`` use fields 0..3, while ``c0``/``c3`` use fields 4..7.
    ``m0``..``m7`` bypass the logical bank naming and select the raw field.
    """
    name = token.strip().lower()
    match = re.fullmatch(r"([abcm])(\d+)", name)
    if match is None:
        raise ValueError(f"invalid matrix register {token!r}")
    bank, index_text = match.groups()
    index = int(index_text)
    if bank == "c":
        if index > 3:
            raise ValueError(f"C register out of range: {token!r}")
        value = index + 4
    else:
        if index > 7:
            raise ValueError(f"matrix register out of range: {token!r}")
        value = index
    if expected is not None and bank != expected and bank != "m":
        raise ValueError(f"{token!r} is not an {expected.upper()} register")
    return value


def split_operands(text: str) -> list[str]:
    return [part.strip() for part in text.split(",") if part.strip()]


def parse_memory_operand(token: str) -> int:
    match = re.fullmatch(r"\(([^()]+)\)", token.strip())
    if match is None:
        raise ValueError(f"expected base register in parentheses, got {token!r}")
    return parse_scalar(match.group(1))


def encode_line(mnemonic: str, operands: list[str]) -> int:
    name = mnemonic.lower()

    config = re.fullmatch(r"msettile([kmn])i?", name)
    if config is not None:
        target = {"k": 1, "m": 2, "n": 3}[config.group(1)]
        if len(operands) != 1:
            raise ValueError(f"{name} expects one operand")
        if name.endswith("i"):
            return encode_config(target, immediate=parse_int(operands[0]))
        return encode_config(target, rs1=parse_scalar(operands[0]))

    zero = re.fullmatch(r"mzero(?:(2|4|8)r)?", name)
    if zero is not None:
        if len(operands) != 1:
            raise ValueError(f"{name} expects one matrix register")
        count = int(zero.group(1) or 1)
        return encode_mzero(parse_matrix(operands[0]), COUNT_TO_CODE[count])

    if name in {
        "mmacc.w.b", "mmaccu.w.b", "mmaccus.w.b", "mmaccsu.w.b"
    }:
        if len(operands) != 3:
            raise ValueError(f"{name} expects md, ms2, ms1")
        md = parse_matrix(operands[0], "c")
        ms2 = parse_matrix(operands[1], "b")
        ms1 = parse_matrix(operands[2], "a")
        return encode_matmul(name, ms2=ms2, ms1=ms1, md=md)

    for family, (load_prefix, store_prefix, family_code) in MEMORY_PREFIXES.items():
        for store, prefix in ((False, load_prefix), (True, store_prefix)):
            match = re.fullmatch(prefix + r"(8|16|32|64)", name)
            if match is None:
                continue
            if len(operands) != 3:
                raise ValueError(f"{name} expects reg, (rs1), rs2")
            width = int(match.group(1))
            if family == "whole":
                reg = parse_matrix(operands[0])
                rs1 = parse_memory_operand(operands[1])
                rs2 = parse_scalar(operands[2])
                if rs2 != 0:
                    raise ValueError(f"{name} requires rs2=x0")
            else:
                expected = family[0]
                reg = parse_matrix(operands[0], expected)
                rs1 = parse_memory_operand(operands[1])
                rs2 = parse_scalar(operands[2])
            return encode_memory(
                family_code,
                store=store,
                elem_width=WIDTH_TO_CODE[width],
                rs1=rs1,
                rs2=rs2,
                reg=reg,
            )

    raise ValueError(f"unknown Coral matrix mnemonic {mnemonic!r}")


def strip_comment(line: str) -> str:
    line = line.split("#", 1)[0]
    return line.split("//", 1)[0].strip()


def assemble_source(source: str) -> list[tuple[str, int]]:
    result: list[tuple[str, int]] = []
    for line_number, raw_line in enumerate(source.splitlines(), 1):
        line = strip_comment(raw_line).strip()
        if not line or line.startswith(".") or line.endswith(":"):
            continue
        fields = line.split(None, 1)
        mnemonic = fields[0]
        operands = split_operands(fields[1]) if len(fields) == 2 else []
        try:
            word = encode_line(mnemonic, operands)
        except ValueError as exc:
            raise ValueError(f"line {line_number}: {exc}") from exc
        result.append((line, word))
    return result


def write_output(records: Iterable[tuple[str, int]], output: str, fmt: str) -> None:
    records = list(records)
    if fmt == "binary":
        data = b"".join(word.to_bytes(4, "little") for _, word in records)
        if output == "-":
            sys.stdout.buffer.write(data)
        else:
            Path(output).write_bytes(data)
        return

    lines: list[str] = []
    if fmt == "asm":
        lines.append(".text")
    for source, word in records:
        if fmt == "hex":
            lines.append(f"0x{word:08x}")
        else:
            lines.append(f".word 0x{word:08x} # {source}")
    text = "\n".join(lines) + ("\n" if lines else "")
    if output == "-":
        sys.stdout.write(text)
    else:
        Path(output).write_text(text, encoding="ascii")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", help="Coral matrix assembly source")
    parser.add_argument("-o", "--output", default="-",
                        help="output path, or - for stdout")
    parser.add_argument("--format", choices=("asm", "hex", "binary"),
                        default="asm", help="output representation")
    args = parser.parse_args()
    source = sys.stdin.read() if args.source == "-" else Path(args.source).read_text()
    try:
        records = assemble_source(source)
        write_output(records, args.output, args.format)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    main()
