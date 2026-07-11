from tools.site.watch_publish import field_complete, pending_rows


def _row(model, rep, status="done", lut=10000):
    return {
        "model": model,
        "rep": rep,
        "status": status,
        "best_lut4": lut,
    }


def test_pending_rows_detects_new_and_changed_final_rows():
    luna1 = _row("gpt-5_6-luna", 1)
    luna2 = _row("gpt-5_6-luna", 2)
    committed = {("gpt-5_6-luna", 1): luna1}
    current = {
        ("gpt-5_6-luna", 1): luna1,
        ("gpt-5_6-luna", 2): luna2,
    }
    assert pending_rows(current, committed) == [("gpt-5_6-luna", 2)]

    changed = dict(luna1, best_lut4=10155)
    current[("gpt-5_6-luna", 1)] = changed
    assert pending_rows(current, committed) == [
        ("gpt-5_6-luna", 1),
        ("gpt-5_6-luna", 2),
    ]


def test_field_complete_requires_all_three_reps_for_all_models():
    rows = {
        (model, rep): _row(model, rep)
        for model in ("gpt-5_6-luna", "gpt-5_6-terra", "gpt-5_6-sol")
        for rep in range(1, 4)
    }
    assert field_complete(rows)
    rows.pop(("gpt-5_6-sol", 3))
    assert not field_complete(rows)
