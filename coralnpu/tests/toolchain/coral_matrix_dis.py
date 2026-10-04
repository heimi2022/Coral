#!/usr/bin/env python3
"""Disassemble frozen CoralNPU matrix words into canonical mnemonics."""

from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path

from matrix_encode_reference import decode


def scalar_name(reg: int) -> str:
    return f"x{reg}"


def matrix_name(reg: int, bank: str | None = None) -> str:
    if bank == "c":
        if 4 <= reg <= 7:
            return f"c{reg - 4}"
        return f"m{reg}"
    if bank in ("a", "b") and 0 <= reg <= 3:
        return f"{bank}{reg}"
    return f"m{reg}"


def disassemble_word(word: int) -> str:
    decoded = decode(word)
    if decoded.kind == "other":
        return f".word 0x{word:08x}"
    fields = decoded.fields
    if decoded.kind == "config":
        target = str(fields["target"])
        mnemonic = f"msettile{target}"
        if fields["source"] == "immediate":
            mnemonic += "i"
            return f"{mnemonic} {fields['value']}"
        return f"{mnemonic} {scalar_name(int(fields['rs1']))}"
    if decoded.kind == "mzero":
        count = int(fields["count"])
        suffix = "" if count == 1 else f"{count}r"
        return f"mzero{suffix} {matrix_name(int(fields['md']), 'c')}"
    if decoded.kind == "matmul":
        return (f"{fields['op']} {matrix_name(int(fields['md']), 'c')}, "
                f"{matrix_name(int(fields['ms2']), 'b')}, "
                f"{matrix_name(int(fields['ms1']), 'a')}")
    if decoded.kind == "memory":
        family = str(fields["family"])
        width = 8 << int(fields["elem_width"])
        store = bool(fields["store"])
        prefixes = {
            "a": ("mlae", "msae", "a"),
            "b": ("mlbe", "msbe", "b"),
            "c": ("mlce", "msce", "c"),
            "whole": ("mlme", "msme", None),
            "a_transposed": ("mlate", "msate", "a"),
            "b_transposed": ("mlbte", "msbte", "b"),
            "c_transposed": ("mlcte", "mscte", "c"),
        }
        load_prefix, store_prefix, bank = prefixes[family]
        mnemonic = (store_prefix if store else load_prefix) + str(width)
        reg = matrix_name(int(fields["reg"]), bank)
        return (f"{mnemonic} {reg}, ({scalar_name(int(fields['rs1']))}), "
                f"{scalar_name(int(fields['rs2']))}")
    raise AssertionError(f"unhandled decoded kind {decoded.kind!r}")


def parse_word(token: str) -> int:
    value = int(token, 0)
    if not 0 <= value <= 0xFFFFFFFF:
        raise ValueError(f"word out of 32-bit range: {token}")
    return value


def text_words(text: str) -> list[int]:
    words: list[int] = []
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].split("//", 1)[0]
        for token in line.replace(",", " ").split():
            if token.lower() == ".word":
                continue
            if token.startswith("0x") or re.fullmatch(r"[0-9a-fA-F]{1,8}", token):
                words.append(parse_word(token))
    return words


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="hex words, text file, or binary file")
    parser.add_argument("--binary", action="store_true",
                        help="read input as little-endian 32-bit words")
    parser.add_argument("-o", "--output", default="-", help="output path")
    args = parser.parse_args()
    try:
        if args.input == "-":
            raw = sys.stdin.buffer.read()
        else:
            raw = Path(args.input).read_bytes()
        if args.binary:
            if len(raw) % 4:
                raise ValueError("binary input length is not a multiple of 4")
            words = [value[0] for value in struct.iter_unpack("<I", raw)]
        else:
            words = text_words(raw.decode("ascii"))
        output = "".join(f"{disassemble_word(word)}\n" for word in words)
        if args.output == "-":
            sys.stdout.write(output)
        else:
            Path(args.output).write_text(output, encoding="ascii")
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    main()
