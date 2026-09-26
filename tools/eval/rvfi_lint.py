"""Fast pattern checks for the RVFI channel-0 retirement contract.

Runs between build and the slow formal phase. The same broken
implementations would otherwise burn ~30 minutes in riscv-formal only
to surface as `formal_failed: no_checks_generated` or `*_ch0` PREUNSAT;
catching the most common shape here saves the round and gives the
implementer a precise pointer instead of an SMT counterexample.

CLAUDE.md invariant #1: single-retire cycles MUST place the retirement
on channel 0 (`io_rvfi_valid_0`). Tying channel 0 off with `'0` is the
exact mirror image of the legitimate single-issue tie of channel 1
(~21 lines of `assign io_rvfi_*_1 = '0;`); it's an easy index swap and
it shows up across pilot reps as the dominant `*_ch0 PREUNSAT` cause.
"""
import re
from pathlib import Path


# Captures the three SystemVerilog ways to bind io_rvfi_valid_0 to
# constant zero in a continuous assignment:
#   assign io_rvfi_valid_0 = '0;
#   assign io_rvfi_valid_0 = 1'b0;
#   assign io_rvfi_valid_0 = 0;
# Whitespace and a trailing line comment are tolerated; non-comment
# trailing tokens (e.g. `assign io_rvfi_valid_0 = 0 | foo;`) are not
# matched — those would not actually be unconditional ties.
_BAD_ASSIGN_RE = re.compile(
    r"^\s*assign\s+io_rvfi_valid_0\s*=\s*"
    r"(?:'0|1'b0|1'd0|0)\s*;",
)


def check_ch0_contract(rtl_dir: Path) -> dict:
    """Scan RTL for unconditional ties of `io_rvfi_valid_0` to zero.

    Returns:
      {'passed': True}
      {'passed': False, 'detail': '<file>:<line>: <message>'}
    """
    rtl_dir = Path(rtl_dir)
    if not rtl_dir.is_dir():
        return {'passed': False, 'detail': f'rtl_dir not a directory: {rtl_dir}'}

    sv_files = sorted(rtl_dir.glob("*.sv"))
    if not sv_files:
        return {'passed': False, 'detail': f'no .sv files in {rtl_dir}'}

    for sv in sv_files:
        try:
            text = sv.read_text()
        except OSError as e:
            return {'passed': False, 'detail': f'{sv.name}: {e}'}
        for line_no, line in enumerate(text.splitlines(), 1):
            # Strip line-end comments before matching so `// debug` tails
            # don't change behavior.
            code = line.split("//", 1)[0]
            if _BAD_ASSIGN_RE.match(code):
                return {
                    'passed': False,
                    'detail': (
                        f'{sv.name}:{line_no}: io_rvfi_valid_0 unconditionally '
                        f"tied to 0. Channel 0 carries single-retire "
                        f"retirements (CLAUDE.md invariant #1). "
                        f"Did you mean io_rvfi_valid_1?"
                    ),
                }
    return {'passed': True}
