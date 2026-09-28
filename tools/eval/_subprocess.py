"""subprocess.run replacement that kills the full descendant tree on timeout.

The gpt-5.5 effort sweep produced visible orphan trees: formal/run_all.sh
times out after 30 minutes, subprocess.TimeoutExpired fires, Python kills
the bash, and `make -j10 → sby → yosys-smtbmc → bitwuzla` reparent to
launchd and keep running with nobody waiting on them. Across a multi-hour
bench, the orphans pile up and starve the live evaluators of CPU.

A killpg-only fix is insufficient here: `sby_core.py` calls `os.setpgrp()`
per task, so each leaf bash/yosys-smtbmc/bitwuzla becomes its own
process-group leader and escapes the outer killpg. The PPID chain stays
intact though, so we walk descendants via psutil and SIGKILL each.
"""
import os
import signal
import subprocess
import threading

import psutil


def _kill_descendant_tree(root_pid: int) -> None:
    """SIGKILL the descendant tree of root_pid (root itself NOT included).

    Snapshots descendants BEFORE killing — once we start sending signals,
    children die and get reaped, which would shrink the tree mid-walk."""
    try:
        root = psutil.Process(root_pid)
    except psutil.NoSuchProcess:
        return
    descendants = root.children(recursive=True)
    denied = []
    for child in descendants:
        try:
            child.kill()
        except psutil.NoSuchProcess:
            pass
        except psutil.AccessDenied:
            denied.append(child.pid)
    _kill_as_agent_user(denied)
    psutil.wait_procs(descendants, timeout=2)


def _kill_as_agent_user(pids: list[int]) -> None:
    """Agents launched as HWE_AGENT_USER (tools/agents/_runtime.py) cannot
    be signalled by the operator directly; the sudoers rule that starts
    them also lets the operator kill them."""
    user = os.environ.get("HWE_AGENT_USER", "").strip()
    if not user or not pids:
        return
    try:
        subprocess.run(["sudo", "-n", "-u", user, "/bin/kill", "-KILL", *map(str, pids)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        pass


def run_pgroup(args, *, timeout=None, capture_output=False, text=False,
               cwd=None, env=None, check=False) -> subprocess.CompletedProcess:
    stdout = subprocess.PIPE if capture_output else None
    stderr = subprocess.PIPE if capture_output else None
    proc = subprocess.Popen(
        args, stdout=stdout, stderr=stderr, text=text,
        cwd=cwd, env=env, start_new_session=True,
    )
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_descendant_tree(proc.pid)
        proc.kill()
        try:
            out, err = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            out, err = (b"", b"") if not text else ("", "")
        raise subprocess.TimeoutExpired(
            cmd=args, timeout=timeout, output=out, stderr=err,
        ) from None
    rc = proc.returncode
    if check and rc != 0:
        raise subprocess.CalledProcessError(rc, args, output=out, stderr=err)
    return subprocess.CompletedProcess(args, rc, out, err)


def kill_process_tree(pid: int) -> None:
    """SIGKILL pid and every descendant.

    Descendants are snapshotted first: once pid dies they reparent to
    launchd/init and the PPID chain back to pid is gone, which is exactly
    how `proc.kill()` on the orchestrator used to orphan its SBY / nextpnr
    / agent trees."""
    _kill_descendant_tree(pid)
    try:
        psutil.Process(pid).kill()
    except psutil.NoSuchProcess:
        pass
    except psutil.AccessDenied:
        # A root-owned `sudo -u <agent user>` exits once its child dies.
        pass


_REAPER_SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)


def install_tree_reaper(signals=_REAPER_SIGNALS) -> None:
    """On SIGTERM / SIGHUP / SIGINT, SIGKILL every descendant, then exit.

    run_pgroup starts each child in its own session (and sby re-setpgrp()s
    every task), so a signal aimed at this process's group never reaches
    them. Without this, stopping a run by hand leaves formal/PnR/agent
    trees burning CPU (and skewing the next run's timeouts) until someone
    pkills them.

    Exits via os._exit rather than raising: unwinding would let in-flight
    slots observe their killed subprocesses as gate failures and journal
    bogus `broken` outcomes. Must be called from the main thread.
    """
    if threading.current_thread() is not threading.main_thread():
        raise RuntimeError("install_tree_reaper must run on the main thread")

    def _reap(signum, _frame):
        _kill_descendant_tree(os.getpid())
        os._exit(128 + signum)

    for sig in signals:
        signal.signal(sig, _reap)


def remove_path(path, *, must: bool = True) -> None:
    """Delete a file or tree the agent may have written.

    Agents run as HWE_AGENT_USER; a directory they chmod (Gowin makes its
    XDG runtime dir 0700) zeroes the POSIX ACL mask that gives the operator
    access, and shutil.rmtree then silently leaves it behind. Retry as the
    agent account, which owns those entries. must=True raises if anything
    survives: callers rely on the path being gone (a fresh build dir, the
    purge of agent-built artifacts before the eval)."""
    import shutil
    from pathlib import Path
    p = Path(path)

    def gone() -> bool:
        return not (p.exists() or p.is_symlink())

    if p.is_symlink() or p.is_file():
        p.unlink(missing_ok=True)
    elif p.is_dir():
        shutil.rmtree(p, ignore_errors=True)
    user = os.environ.get("HWE_AGENT_USER", "").strip()
    if not gone() and user:
        subprocess.run(["sudo", "-n", "-u", user, "/bin/rm", "-rf", "--", str(p)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
    if must and not gone():
        raise RuntimeError(f"cannot remove {p} (not owned by the operator or {user or 'no agent account'})")
