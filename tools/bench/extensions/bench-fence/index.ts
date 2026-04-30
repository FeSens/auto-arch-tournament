// bench-fence — pi-coding-agent extension that enforces path allowlists
// for the LLM hardware-development benchmark.
//
// Auto-loaded by pi from `<cwd>/.pi/extensions/bench-fence/index.ts`.
// Rejects tool calls (read/write/edit/grep/find/ls/bash) that touch
// paths outside `bench-fence.config.json`'s allowlist.
//
// Validation logic is mirrored in tools/bench/fence_validator.py so
// Python unit tests can exercise the same rules without a Node runtime.
// If you change either file, mirror the change in the other.

import * as fs from "node:fs";
import * as path from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

interface FenceConfig {
  clone_root: string;
  read_allow: string[];
  write_allow: string[];
  bash_blocklist: string[];
}

const READ_TOOLS = new Set(["read", "grep", "find", "ls"]);
const WRITE_TOOLS = new Set(["write", "edit"]);
const BASH_TOOLS = new Set(["bash", "shell"]);

const _OUTSIDE = "__OUTSIDE__:";

let _cachedConfig: { cwd: string; cfg: FenceConfig | null } | null = null;

function loadConfig(cwd: string): FenceConfig | null {
  if (_cachedConfig && _cachedConfig.cwd === cwd) return _cachedConfig.cfg;
  const candidates = [
    path.join(cwd, ".pi", "extensions", "bench-fence", "bench-fence.config.json"),
    path.join(cwd, ".pi-bench-fence.config.json"),
  ];
  let cfg: FenceConfig | null = null;
  for (const p of candidates) {
    if (fs.existsSync(p)) {
      try {
        cfg = JSON.parse(fs.readFileSync(p, "utf8")) as FenceConfig;
        break;
      } catch (e) {
        console.error(`[bench-fence] failed to parse ${p}: ${e}`);
      }
    }
  }
  _cachedConfig = { cwd, cfg };
  return cfg;
}

export function relToClone(target: string, cloneRoot: string, cwd?: string): string {
  const root = path.normalize(cloneRoot);
  // Relative paths must resolve against the agent's CWD, not the clone
  // root — the impl agent's cwd is a per-iteration sub-worktree, so
  // `rtl/foo.sv` means `<sub-worktree>/rtl/foo.sv`, not `<clone>/rtl/foo.sv`.
  // Falls back to clone root when cwd is unavailable (legacy callers).
  const base = cwd ? path.normalize(cwd) : root;
  const abs = path.isAbsolute(target)
    ? path.normalize(target)
    : path.normalize(path.resolve(base, target));
  if (abs === root) return "";
  if (abs.startsWith(root + path.sep)) return abs.slice(root.length + 1);
  return _OUTSIDE + abs;
}

function matchesPrefix(rel: string, prefix: string): boolean {
  if (rel === prefix) return true;
  const needle = prefix.endsWith("/") ? prefix : prefix + "/";
  return rel.startsWith(needle);
}

// Per-iteration worktrees live at cores/bench/worktrees/<hyp_id>/. The
// implementation agent's cwd is that worktree, so when it edits rtl/foo.sv
// pi resolves to <clone>/cores/bench/worktrees/<hyp_id>/rtl/foo.sv.
// Strip the worktree prefix so the inner path can be matched against the
// same allow lists as a top-level edit would.
const _WORKTREE_RE = /^cores\/bench\/worktrees\/[^/]+\/(.+)$/;

function _stripWorktree(rel: string): string {
  const m = rel.match(_WORKTREE_RE);
  return m ? m[1] : rel;
}

export function isReadAllowed(rel: string, cfg: FenceConfig): boolean {
  if (rel.startsWith(_OUTSIDE)) return false;
  // Allow the clone root itself (empty rel = `ls .`).
  if (rel === "") return true;
  const inner = _stripWorktree(rel);
  for (const p of cfg.read_allow) {
    if (matchesPrefix(rel, p) || matchesPrefix(inner, p)) return true;
    // Allow ANCESTORS of any allowed path — `ls cores` should work when
    // `cores/bench` is allowed, otherwise the agent can't navigate.
    if (p.startsWith(rel + "/") || p.startsWith(inner + "/")) return true;
  }
  return false;
}

export function isWriteAllowed(rel: string, cfg: FenceConfig): boolean {
  if (rel.startsWith(_OUTSIDE)) return false;
  const inner = _stripWorktree(rel);
  return cfg.write_allow.some((p) => matchesPrefix(rel, p) || matchesPrefix(inner, p));
}

export function bashContainsForbidden(cmd: string, cfg: FenceConfig): string | null {
  for (const blocked of cfg.bash_blocklist) {
    if (cmd.includes(blocked)) return blocked;
  }
  return null;
}

function pickPath(input: Record<string, unknown>): string | null {
  // Pi tool inputs use `path` for read/write/edit/ls/find, `pattern` for grep.
  // We accept both, plus a few common aliases just in case.
  for (const k of ["path", "file_path", "filepath", "filename", "file"]) {
    const v = input[k];
    if (typeof v === "string" && v.length > 0) return v;
  }
  return null;
}

function pickCommand(input: Record<string, unknown>): string | null {
  for (const k of ["command", "cmd", "bash", "shell"]) {
    const v = input[k];
    if (typeof v === "string" && v.length > 0) return v;
  }
  return null;
}

export default function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event, ctx) => {
    const cfg = loadConfig(ctx.cwd);
    if (!cfg) return undefined;
    const cloneRoot = path.normalize(cfg.clone_root);
    const tool = event.toolName;
    const input = (event.input ?? {}) as Record<string, unknown>;

    if (READ_TOOLS.has(tool)) {
      const fp = pickPath(input);
      if (fp === null) return undefined;
      const rel = relToClone(fp, cloneRoot, ctx.cwd);
      if (!isReadAllowed(rel, cfg)) {
        return {
          block: true,
          reason: `bench-fence: read of '${fp}' is outside the benchmark scope. ` +
            `You may only read under: ${cfg.read_allow.join(", ")}.`,
        };
      }
    } else if (WRITE_TOOLS.has(tool)) {
      const fp = pickPath(input);
      if (fp === null) {
        return { block: true, reason: `bench-fence: ${tool} called without a path argument` };
      }
      const rel = relToClone(fp, cloneRoot, ctx.cwd);
      if (!isWriteAllowed(rel, cfg)) {
        return {
          block: true,
          reason: `bench-fence: write to '${fp}' is outside the benchmark scope. ` +
            `You may only write to: ${cfg.write_allow.join(", ")}.`,
        };
      }
    } else if (BASH_TOOLS.has(tool)) {
      const cmd = pickCommand(input);
      if (cmd === null) return undefined;
      const hit = bashContainsForbidden(cmd, cfg);
      if (hit !== null) {
        return {
          block: true,
          reason: `bench-fence: bash command contains forbidden token '${hit}'. ` +
            `The benchmark fences off other cores and history-rewriting git operations; ` +
            `restructure your command to operate only on cores/bench/.`,
        };
      }
    }
    return undefined;
  });
}
