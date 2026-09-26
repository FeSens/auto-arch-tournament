# HWE Bench — Strategy

## Positioning Statement

For ML capability researchers and hardware-engineering practitioners who need a benchmark that doesn't saturate, **HWE Bench** is an empirically-grounded LLM hardware-development benchmark on RISC-V CPUs. Unlike SWE-bench's bounded 100% ceiling, HWE Bench measures fitness via Fmax × IPC on a real FPGA under formal-verification correctness gates — and the score keeps climbing as models improve.

## Archetype

**The Sage** (with a touch of the Outlaw)

The Sage owns the brand's core posture: knowledge-pursuit, rigor, restraint, methodology-front. Every page is structured like a results section in a paper.

The Outlaw flavor is one defended thesis: *"most benchmarks saturate; ours doesn't, and that matters."* It's a quiet rebellion against the conventional eval format. Not loud, but unmistakable.

## Voice Pillars

1. **Precise.** Numbers carry weight; words carry weight. No filler. No hedging where claims are defensible. Specific over general always (5,453 LUT4 over "small footprint").
2. **Restrained.** Never advocates, only reports. The reader is trusted to draw conclusions from data presented honestly. No exclamation marks. No CTAs that beg.
3. **Defended.** Where the brand has a thesis, it states it plainly and shows evidence. The unbounded-scoreboard claim is not a slogan — it's a methodological fact backed by per-rep trajectories.

## Tone Calibrations

| Surface | Tone |
|---|---|
| Methodology page | Lab-notebook prose. Past tense. Active voice. |
| Leaderboard | Tabular. No marketing copy. |
| Headline copy | Declarative sentences. One idea per. |
| Per-rep transcripts | Verbatim model output, presented without comment. The transcript IS the artifact. |
| Footer / colophon | Citation-style. Authorship attributed, methodology versioned. |

## Messaging Hierarchy

**Primary thesis (above the fold on home):**
> SWE-bench tops out at 100%. HWE Bench doesn't have a top.

**Supporting claim:**
> Models compete to design better RISC-V CPUs, measured by CoreMark fitness on a real FPGA, gated by formal verification. The current best is +85.6% over the baseline core. The curve hasn't plateaued.

**Methodology line:**
> Each iteration is one hypothesis → one RTL implementation → 45+ riscv-formal checks → Python-ISS cosim diff → 3-seed nextpnr placement → Verilator CoreMark. If any gate fails, the iteration is "broken" and counted as such on the leaderboard. No surface-metric gaming.

## Anti-messaging

Things HWE Bench will never say:
- "Revolutionary"
- "The future of AI evaluation"
- "Unlock"
- "Transform"
- Any phrase with "AI" used as an adjective for marketing effect
- Any superlative not backed by a number on the page

## Manifesto Line (defended)

> A benchmark that respects how far a frontier model still has to go.

This appears once on the home page, deliberately. Not as a slogan. As a single line at the bottom of the hero, in the same body type, italicized.
