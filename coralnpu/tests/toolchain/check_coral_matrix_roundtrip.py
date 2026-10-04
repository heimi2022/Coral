#!/usr/bin/env python3
"""Check Coral matrix assembler/disassembler round-trip behavior."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from coral_matrix_as import assemble_source
from coral_matrix_dis import disassemble_word
from matrix_encode_reference import decode


def main() -> None:
    source = (ROOT / "coral_matrix_asm.s").read_text(encoding="ascii")
    records = assemble_source(source)
    if len(records) != 25:
        raise AssertionError(f"expected 25 instructions, got {len(records)}")

    for original, word in records:
        decoded = decode(word)
        if decoded.kind == "other":
            raise AssertionError(f"reference decoder rejected {original}: {word:#x}")
        text = disassemble_word(word)
        reparsed = assemble_source(text + "\n")
        if len(reparsed) != 1 or reparsed[0][1] != word:
            raise AssertionError(
                f"round-trip mismatch for {original}: {word:#010x} -> {text!r}"
            )

    print(f"coral_matrix_roundtrip: verified {len(records)} instructions")


if __name__ == "__main__":
    main()
