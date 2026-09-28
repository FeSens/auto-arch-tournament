from tools.bench.runner import JobSpec, ModelEntry, enumerate_jobs, interleaved_batches


def test_batches_pair_each_rep_and_alternate_launch_order():
    a = ModelEntry(name="a", model="x/a", provider="claude", oauth=True)
    b = ModelEntry(name="b", model="x/b", provider="codex", oauth=True)
    jobs = enumerate_jobs([a, b], 3, done={("a", 3)})
    batches = interleaved_batches(jobs)
    assert [[(j.model.name, j.rep) for j in bt] for bt in batches] == [
        [("a", 1), ("b", 1)], [("b", 2), ("a", 2)], [("b", 3)]]


def test_three_systems_rotate_launch_order():
    ms = [ModelEntry(name=n, model=f"x/{n}", provider="codex", oauth=True) for n in "abc"]
    batches = interleaved_batches(enumerate_jobs(ms, 4, done=set()))
    assert [[j.model.name for j in b] for b in batches] == [
        list("abc"), list("bca"), list("cab"), list("abc")]
