"""Bench Codex agents run with an isolated CODEX_HOME."""
import json
import os

from tools.bench.runner import isolated_codex_home, sync_codex_auth_back


def _user_home(tmp_path, last_refresh="2026-09-15T00:00:00Z"):
    home = tmp_path / "user-codex"
    (home / "memories").mkdir(parents=True)
    (home / "memories" / "MEMORY.md").write_text("personal notes")
    (home / "skills" / "x").mkdir(parents=True)
    (home / "config.toml").write_text("[features]\nmemories = true\n")
    (home / "auth.json").write_text(json.dumps({"last_refresh": last_refresh}))
    return home


def test_isolated_home_has_only_auth_symlink_and_minimal_config(tmp_path):
    user = _user_home(tmp_path)
    clone = tmp_path / "clone"
    clone.mkdir()
    home = isolated_codex_home(clone, user)
    assert home == clone / ".codex-home"
    assert sorted(p.name for p in home.iterdir()) == ["auth.json", "config.toml"]
    assert (home / "auth.json").is_symlink()
    assert (home / "auth.json").resolve() == (user / "auth.json").resolve()
    cfg = (home / "config.toml").read_text()
    assert "memories = false" in cfg and str(clone.resolve()) in cfg
    # Top-level key (before any table), so it is not scoped to [features].
    assert cfg.index("allow_login_shell = false") < cfg.index("[features]")
    # /tmp is shared across the accounts of concurrent runs: not writable,
    # or Codex's /tmp/.codex mount targets collide between accounts.
    import tomllib
    assert tomllib.loads(cfg)["sandbox_workspace_write"]["exclude_slash_tmp"] is True


def test_isolated_home_is_recreated_fresh(tmp_path):
    user = _user_home(tmp_path)
    clone = tmp_path / "clone"
    clone.mkdir()
    home = isolated_codex_home(clone, user)
    (home / "memories").mkdir()
    home = isolated_codex_home(clone, user)
    assert not (home / "memories").exists()


def test_sync_back_only_when_symlink_replaced_by_newer_token(tmp_path):
    user = _user_home(tmp_path)
    clone = tmp_path / "clone"
    clone.mkdir()
    home = isolated_codex_home(clone, user)
    assert sync_codex_auth_back(home, user) is False        # still a symlink
    (home / "auth.json").unlink()
    (home / "auth.json").write_text(json.dumps({"last_refresh": "2026-09-01T00:00:00Z"}))
    assert sync_codex_auth_back(home, user) is False        # older: keep user's
    (home / "auth.json").write_text(json.dumps({"last_refresh": "2026-09-24T00:00:00Z"}))
    assert sync_codex_auth_back(home, user) is True
    assert json.loads((user / "auth.json").read_text())["last_refresh"] == "2026-09-24T00:00:00Z"
    assert oct(os.stat(user / "auth.json").st_mode & 0o777) == "0o600"


def test_sync_back_writes_through_a_shared_login_link(tmp_path):
    """Pool accounts link ~/.codex/auth.json to one group file; a refresh is
    written into that file (link kept, group mode kept)."""
    shared = tmp_path / "auth" / "auth.json"
    shared.parent.mkdir()
    shared.write_text(json.dumps({"last_refresh": "2026-09-01T00:00:00Z"}))
    os.chmod(shared, 0o660)
    user = tmp_path / "home" / ".codex"
    user.mkdir(parents=True)
    (user / "auth.json").symlink_to(shared)
    clone = tmp_path / "clone"
    clone.mkdir()
    home = isolated_codex_home(clone, user)
    (home / "auth.json").unlink()
    (home / "auth.json").write_text(json.dumps({"last_refresh": "2026-09-24T00:00:00Z"}))
    assert sync_codex_auth_back(home, user) is True
    assert (user / "auth.json").is_symlink()
    assert json.loads(shared.read_text())["last_refresh"] == "2026-09-24T00:00:00Z"
    assert oct(os.stat(shared).st_mode & 0o777) == "0o660"
