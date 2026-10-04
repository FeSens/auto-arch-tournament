"""Extended benchmark suite: every Embench-IoT kernel at the commit
bench/holdout vendors from (09c2ed8c), ported the way bench/holdout ports
its four, plus the bench's own five held-out ELFs.

Port (same as bench/holdout/VENDOR.md): drop `static` from benchmark_body's
declaration and definition, and add a shim.c whose holdout_body() calls
benchmark_body(1, 1) once per rep. The shim is driven by
bench/holdout/support/main_wrapper.c (BENCH_START, HOLDOUT_REPS bodies,
BENCH_STOP, one "HOLDOUT <k> reps=<R> status=PASS|FAIL" line, verify_benchmark
on the last rep's result). Compiler, flags, crt0 and link script are
bench/holdout/Makefile's. Everything is read from the main checkout and
written under ~/extbench (nothing is written into bench/).

    python3 -B build_elfs.py [--reps-file reps.json]

Without --reps-file every new kernel is built with HOLDOUT_REPS=1 (for
calibration, see calibrate.py).
"""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path("/home/bench/auto-arch-tournament")
HO = REPO / "bench/holdout"
EMB = Path.home() / "extbench/embench-iot"     # embench-iot @ 09c2ed8c
WORK = Path.home() / "extbench/port"
OUT = Path.home() / "extbench/elfs"
HERE = Path(__file__).resolve().parent
GCC = "/opt/hwe-toolchain/bin/riscv32-unknown-elf-gcc"

VENDORED = ("aha-mont64", "crc32", "matmult-int", "edn")   # bench/holdout ELFs, used as built
HELD_OUT = ("dhrystone",) + VENDORED
NEW = ("depthconv", "huffbench", "md5sum", "nettle-aes", "nettle-sha256", "nsichneu",
       "picojpeg", "qrduino", "sglib-combined", "slre", "statemate", "tarfind", "ud",
       "wikisort", "xgboost")
CFLAGS = ["-march=rv32im", "-mabi=ilp32", "-O2", "-static", "-nostartfiles",
          "-specs=nano.specs", "-specs=nosys.specs", "-T", str(REPO / "bench/programs/link.ld"),
          f"-I{HO / 'support'}", f"-I{HO / 'embench'}", "-DGLOBAL_SCALE_FACTOR=1"]
SUPPORT = [HO / "support/holdout_port.c", HO / "support/main_wrapper.c", HO / "support/sbrk.c",
           REPO / "bench/programs/crt0.S"]

SHIM = """/* Extended-suite shim for Embench {k} (research/v2/extended_bench), same
   pattern as the bench/holdout embench shims: one benchmark_body(1, 1) per rep,
   verify_benchmark() on the last rep's result. */
extern void initialise_benchmark(void);
extern int  benchmark_body(unsigned int lsf, unsigned int gsf{extra_decl});
extern int  verify_benchmark(int r);
static int last_result;
int holdout_init(void) {{ initialise_benchmark(); return 0; }}
void holdout_body(void) {{ last_result = benchmark_body(1, 1{extra_arg}); }}
int holdout_verify(void) {{ return verify_benchmark(last_result); }}
"""
# wikisort typedefs `bool`, a keyword in GCC's default C23 (the held-out Makefile
# pins dhrystone to gnu89 the same way).
STD = {"wikisort": ["-std=gnu17"]}
# md5sum's benchmark_body takes the message length; benchmark() passes MSG_SIZE.
EXTRA = {"md5sum": (", int len", ", MSG_SIZE_FOR_SHIM")}


def port(k: str) -> list[Path]:
    d = WORK / k
    if d.exists():
        shutil.rmtree(d)
    shutil.copytree(EMB / "src" / k, d)
    srcs = sorted(d.glob("*.c"))
    for c in srcs:
        t = c.read_text()
        t2 = re.sub(r"\bstatic(\s+int\s+(?:__attribute__\s*\(\(\s*noinline\s*\)\)\s*)?benchmark_body\s*\()",
                    r"/* EXTENDED PORT: static dropped */\1", t)
        c.write_text(t2)
    extra_decl, extra_arg = EXTRA.get(k, ("", ""))
    if k == "md5sum":
        size = re.search(r"#define\s+MSG_SIZE\s+(\d+)", (d / "md5.c").read_text()).group(1)
        extra_arg = f", {size}"
    (d / "shim.c").write_text(SHIM.format(k=k, extra_decl=extra_decl, extra_arg=extra_arg))
    return srcs + [d / "shim.c"]


def build(k: str, reps: int) -> Path:
    srcs = port(k)
    out = OUT / f"{k}.elf"
    cmd = [GCC, *CFLAGS, *STD.get(k, []), f"-I{WORK / k}", f'-DKERNEL_NAME="{k}"', f"-DHOLDOUT_REPS={reps}",
           *map(str, srcs), str(HO / "embench/beebsc.c"), *map(str, SUPPORT), "-lm", "-o", str(out)]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"{k}: {p.stderr[-1500:]}")
    return out


def main(argv):
    reps = {}
    if "--reps-file" in argv:
        reps = {k: v for k, v in json.loads(Path(argv[argv.index("--reps-file") + 1]).read_text()).items()
                if not k.startswith("_")}
    OUT.mkdir(parents=True, exist_ok=True)
    for k in HELD_OUT:   # the scored held-out ELFs, byte-identical copies
        shutil.copy(HO / "build" / f"{k}.elf", OUT / f"{k}.elf")
    failed = {}
    for k in NEW:
        try:
            build(k, reps.get(k, 1))
            print(k, "ok", reps.get(k, 1))
        except RuntimeError as e:
            failed[k] = str(e)
            print(k, "FAILED\n", str(e)[-800:])
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
