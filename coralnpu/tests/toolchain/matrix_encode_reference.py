#!/usr/bin/env python3
"""Spec-first encoder/decoder for the CoralNPU-supported matrix ISA subset.

This is a software reference for checking bit fields.  It deliberately does
not import or reproduce the Chisel decoder implementation.  The source of
truth for the supported encodings is the matrix-extension specification.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional


OPCODE = 0x2B


def _check(name: str, value: int, maximum: int) -> int:
    if not isinstance(value, int) or value < 0 or value > maximum:
        raise ValueError(f"{name} must be in [0, {maximum}], got {value!r}")
    return value


def _put(word: int, value: int, high: int, low: int) -> int:
    width = high - low + 1
    mask = (1 << width) - 1
    return word | ((value & mask) << low)


def _get(word: int, high: int, low: int) -> int:
    return (word >> low) & ((1 << (high - low + 1)) - 1)


def _base(func: int, uop: int) -> int:
    word = OPCODE
    word = _put(word, _check("func", func, 0xF), 31, 28)
    word = _put(word, _check("uop", uop, 0x3), 27, 26)
    return word


CONFIG_FUNCS = {1: "k", 2: "m", 3: "n"}
MATMUL_SIZE_SUP = {
    "mmacc.w.b": 0b011,
    "mmaccu.w.b": 0b000,
    "mmaccus.w.b": 0b001,
    "mmaccsu.w.b": 0b010,
}
MEMORY_FAMILIES = {
    0: "a",
    1: "b",
    2: "c",
    3: "whole",
    4: "a_transposed",
    5: "b_transposed",
    6: "c_transposed",
}
MZERO_COUNTS = {0b000: 1, 0b001: 2, 0b011: 4, 0b111: 8}


@dataclass(frozen=True)
class Decoded:
    kind: str
    fields: Dict[str, int | str | bool]


def encode_config(func: int, *, immediate: Optional[int] = None,
                  rs1: Optional[int] = None) -> int:
    """Encode msettile{ki,mi,ni} or msettile{k,m,n}.

    The immediate form uses uimm10 in bits 24:15.  The register form sets
    ctrl=1, rs2=0, and places rs1 in bits 19:15.
    """
    if func not in CONFIG_FUNCS:
        raise ValueError(f"config func must be 1, 2, or 3, got {func}")
    if (immediate is None) == (rs1 is None):
        raise ValueError("provide exactly one of immediate or rs1")

    word = _base(func, 0)
    if immediate is not None:
        word = _put(word, _check("immediate", immediate, 0x3FF), 24, 15)
        source = "immediate"
    else:
        word = _put(word, 1, 25, 25)
        word = _put(word, 0, 24, 20)
        word = _put(word, _check("rs1", rs1, 0x1F), 19, 15)
        source = "register"
    return word


def encode_mzero(md: int, count_code: int) -> int:
    """Encode mzero; count_code is the spec's uimm3 field.

    Reserved count codes are rejected.  Register alignment is checked here
    because it is part of the mzero instruction's architectural constraint:
    1/2/4/8-register clears start at an aligned matrix register.
    """
    _check("md", md, 7)
    _check("count_code", count_code, 7)
    if count_code not in MZERO_COUNTS:
        raise ValueError(f"reserved mzero count code: {count_code:03b}")
    count = MZERO_COUNTS[count_code]
    if md % count != 0:
        raise ValueError(f"mzero md={md} is not aligned for {count} registers")

    word = _base(0, 0b11)
    word = _put(word, count_code, 25, 23)
    word = _put(word, md, 9, 7)
    return word


def encode_matmul(op: str, ms2: int, ms1: int, md: int) -> int:
    """Encode one of the four supported signedness variants of mmacc.w.b."""
    if op not in MATMUL_SIZE_SUP:
        raise ValueError(f"unsupported integer matrix multiply: {op}")
    word = _base(1, 0b10)
    word = _put(word, MATMUL_SIZE_SUP[op], 25, 23)
    word = _put(word, _check("ms2", ms2, 7), 22, 20)
    word = _put(word, _check("ms1", ms1, 7), 17, 15)
    word = _put(word, 0, 14, 12)
    word = _put(word, 0b10, 11, 10)
    word = _put(word, _check("md", md, 7), 9, 7)
    return word


def encode_memory(family: int, *, store: bool, elem_width: int,
                  rs1: int, rs2: int, reg: int) -> int:
    """Encode the spec's matrix load/store families supported by CoralNPU."""
    if family not in MEMORY_FAMILIES:
        raise ValueError(f"memory func must be in [0, 6], got {family}")
    if family == 3 and rs2 != 0:
        raise ValueError("whole-matrix memory operations require rs2=0")

    word = _base(family, 0b01)
    word = _put(word, int(store), 25, 25)
    word = _put(word, _check("rs2", rs2, 0x1F), 24, 20)
    word = _put(word, _check("rs1", rs1, 0x1F), 19, 15)
    word = _put(word, 0, 14, 12)
    word = _put(word, _check("elem_width", elem_width, 3), 11, 10)
    word = _put(word, _check("reg", reg, 7), 9, 7)
    return word


def decode(word: int) -> Decoded:
    """Decode the supported spec subset, or return kind='other'."""
    _check("word", word, 0xFFFFFFFF)
    if _get(word, 6, 0) != OPCODE:
        return Decoded("other", {})

    func = _get(word, 31, 28)
    uop = _get(word, 27, 26)

    if uop == 0 and func in CONFIG_FUNCS:
        ctrl = _get(word, 25, 25)
        if ctrl == 0:
            return Decoded("config", {
                "target": CONFIG_FUNCS[func],
                "source": "immediate",
                "value": _get(word, 24, 15),
            })
        if ctrl == 1 and _get(word, 24, 20) == 0:
            return Decoded("config", {
                "target": CONFIG_FUNCS[func],
                "source": "register",
                "rs1": _get(word, 19, 15),
            })

    if uop == 0b11 and func == 0:
        fixed = (_get(word, 22, 20) == 0 and _get(word, 19, 18) == 0 and
                 _get(word, 17, 15) == 0 and _get(word, 14, 12) == 0 and
                 _get(word, 11, 10) == 0)
        count_code = _get(word, 25, 23)
        if fixed and count_code in MZERO_COUNTS:
            return Decoded("mzero", {
                "md": _get(word, 9, 7),
                "count_code": count_code,
                "count": MZERO_COUNTS[count_code],
            })

    if uop == 0b10 and func == 1:
        size_sup = _get(word, 25, 23)
        op = next((name for name, value in MATMUL_SIZE_SUP.items()
                   if value == size_sup), None)
        if (op is not None and _get(word, 19, 18) == 0 and
                _get(word, 14, 12) == 0 and _get(word, 11, 10) == 0b10):
            return Decoded("matmul", {
                "op": op,
                "ms2": _get(word, 22, 20),
                "ms1": _get(word, 17, 15),
                "md": _get(word, 9, 7),
            })

    if uop == 0b01 and func in MEMORY_FAMILIES:
        if _get(word, 14, 12) == 0:
            return Decoded("memory", {
                "family": MEMORY_FAMILIES[func],
                "store": bool(_get(word, 25, 25)),
                "elem_width": _get(word, 11, 10),
                "rs1": _get(word, 19, 15),
                "rs2": _get(word, 24, 20),
                "reg": _get(word, 9, 7),
            })

    return Decoded("other", {})


def _assert_round_trip(word: int, kind: str) -> None:
    decoded = decode(word)
    assert decoded.kind == kind, (f"{word:#010x}: expected {kind}, "
                                  f"got {decoded.kind}")
    assert word & 0x7F == OPCODE


def self_test() -> None:
    for func in (1, 2, 3):
        _assert_round_trip(encode_config(func, immediate=0x155), "config")
        _assert_round_trip(encode_config(func, rs1=17), "config")

    for count_code, count in MZERO_COUNTS.items():
        for md in range(0, 8, count):
            decoded = decode(encode_mzero(md, count_code))
            assert decoded.fields["count"] == count
            assert decoded.fields["md"] == md

    for op in MATMUL_SIZE_SUP:
        word = encode_matmul(op, ms2=2, ms1=5, md=7)
        assert _get(word, 27, 26) == 0b10
        _assert_round_trip(word, "matmul")

    for family in MEMORY_FAMILIES:
        for store in (False, True):
            _assert_round_trip(encode_memory(
                family, store=store, elem_width=2, rs1=10,
                rs2=0 if family == 3 else 11,
                reg=6 if family in (2, 6) else 2), "memory")

    assert decode(0).kind == "other"
    print("matrix_encode_reference: all self-tests passed")


def main() -> None:
    self_test()
    examples = [
        ("msettileki", encode_config(1, immediate=33)),
        ("msettilem", encode_config(2, rs1=5)),
        ("mzero C0", encode_mzero(4, 0)),
        ("mmacc.w.b", encode_matmul("mmacc.w.b", 1, 2, 4)),
        ("mlce32", encode_memory(2, store=False, elem_width=2,
                                 rs1=10, rs2=11, reg=4)),
        ("msce32", encode_memory(2, store=True, elem_width=2,
                                 rs1=10, rs2=11, reg=4)),
    ]
    for name, word in examples:
        print(f"{name:12s} {word:#010x}  {decode(word)}")


if __name__ == "__main__":
    main()
