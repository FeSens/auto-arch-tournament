import json

from tools.bench.transcript import FIELD_CAP, compact_line, publish_transcript


def _line(obj):
    return json.dumps(obj) + "\n"


def test_caps_codex_tool_output_keeps_command():
    cmd = "cat <<'EOF' > rtl/core.sv\n" + "x" * 10_000 + "\nEOF"
    out = "y" * 50_000
    line = _line({"type": "item.completed", "item": {
        "type": "command_execution", "command": cmd, "aggregated_output": out}})
    got = json.loads(compact_line(line))
    assert got["item"]["command"] == cmd          # model-authored: verbatim
    agg = got["item"]["aggregated_output"]
    assert len(agg) < 4000 and "of 50000 chars elided" in agg and "sha256:" in agg
    assert agg.startswith("y" * 100) and agg.endswith("y" * 100)


def test_caps_opencode_output_and_encrypted_reasoning_keeps_text():
    obj = {"type": "tool_use", "part": {
        "state": {"output": "o" * 9000, "input": {"patchText": "p" * 9000},
                  "metadata": {"output": "m" * 9000, "preview": "v" * 9000}},
        "metadata": {"openrouter": {"reasoning_details": [
            {"data": "d" * 9000, "text": "t" * 9000}]}}}}
    got = json.loads(compact_line(_line(obj)))
    part = got["part"]
    for s in (part["state"]["output"], part["state"]["metadata"]["output"],
              part["state"]["metadata"]["preview"],
              part["metadata"]["openrouter"]["reasoning_details"][0]["data"]):
        assert "elided" in s
    assert part["state"]["input"]["patchText"] == "p" * 9000
    assert part["metadata"]["openrouter"]["reasoning_details"][0]["text"] == "t" * 9000


def test_small_usage_and_non_json_lines_pass_through():
    usage = _line({"type": "turn.completed", "usage": {"input_tokens": 5}})
    assert compact_line(usage) == usage
    header = "=== /x/.agent.hyp-1.log ===\n"
    assert compact_line(header) == header
    raw = "z" * (FIELD_CAP * 3) + "\n"
    assert compact_line(raw) == raw


def test_publish_transcript_writes_compact_and_full(tmp_path):
    import gzip
    src = tmp_path / "concat.log"
    big = _line({"type": "item.completed", "item": {"aggregated_output": "q" * 20_000}})
    src.write_text("=== a ===\n" + big)
    publish_transcript(src, tmp_path)
    assert (tmp_path / "agent.log").stat().st_size < 5000
    assert gzip.decompress((tmp_path / "agent.full.log.gz").read_bytes()).decode() \
        == src.read_text()
