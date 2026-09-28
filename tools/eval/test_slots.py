"""Host eval slots: at most N evals hold a slot at once; unset = no limit."""
import threading
import time

from tools.eval._slots import eval_slot


def test_no_env_is_no_limit(monkeypatch):
    monkeypatch.delenv("HARNESS_EVAL_SLOTS", raising=False)
    with eval_slot(), eval_slot():
        pass


def test_at_most_n_hold_a_slot(tmp_path, monkeypatch):
    monkeypatch.setenv("HARNESS_EVAL_SLOTS", "2")
    monkeypatch.setenv("HARNESS_EVAL_LOCK_DIR", str(tmp_path))
    live, peak, lock = [0], [0], threading.Lock()

    def job():
        with eval_slot("t"):
            with lock:
                live[0] += 1
                peak[0] = max(peak[0], live[0])
            time.sleep(0.3)
            with lock:
                live[0] -= 1

    ts = [threading.Thread(target=job) for _ in range(5)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert peak[0] == 2
