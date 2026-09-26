# Brand Brief

## Brand
- **Name:** hwe-bench
- **Date:** 2026-05-15

## Company
- **Company name:** HWE Bench (project)
- **Industry:** ML capability research / hardware benchmarking
- **Founded:** 2026
- **Size:** solo / small research effort
- **Stage:** mvp (results in hand, site to publish)
- **Existing brand?** no

## Brand Mode
- **Mode:** new
- **Reason:** N/A — new brand

### Existing Brand State (evolve only)
N/A — new brand

### Evolution Scope (evolve only)
N/A — new brand

## Business
- **Problem:** Most LLM benchmarks saturate. SWE-bench has a 100% ceiling. Multiple-choice evals approach 99%. Capability researchers can't watch model curves climb on tasks where there's no ceiling and the work is real engineering — RTL design, microarchitecture, formal verification, FPGA-fitness.
- **Solution:** HWE Bench measures LLM-generated RISC-V CPU designs by their CoreMark fitness (Fmax × IPC) on a real Tang Nano 20K FPGA, gated by riscv-formal correctness and a Python-ISS cosim diff. Score is open-ended: a faster, smaller, smarter microarchitecture always scores higher. Baseline is a known V0 core; models propose hypotheses and iterate.
- **Business model:** non-commercial research artifact. Open methodology, open data, open results.
- **Defensibility:** hard methodology — the formal/cosim/FPGA correctness gates can't be gamed by surface metrics. Reproducible from a fresh clone of the repo.

## Personas

### Primary: Maya — ML capability researcher
- **Role:** capability researcher at a frontier lab; runs evals to track scaling
- **Age range:** 28–40
- **Day-in-the-life:** Spends days reading new model release notes, designing evals, and scripting reproductions. Tools: Python notebooks, internal eval frameworks, papers-with-code. Pressures: every six months a new model lands and she has to say something credible about whether it's actually more capable.
- **Frustration:** most benchmarks are 1-shot multiple-choice or saturable text tasks — they don't tell her whether models can do real engineering work with long horizons, hard correctness gates, and a fitness number that can keep climbing.
- **Aspiration:** a benchmark she can cite in a paper and revisit every six months with a new model and see meaningful movement.
- **Discovery:** Twitter / X, arXiv, lab Slack channels, blog posts from other labs. Trusts: METR, EpochAI, Anthropic's transparency posts, Stanford CRFM.
- **Trust signals:** unimpeachable methodology page, raw data downloadable as JSONL, reproducibility from a fresh clone. Distrusts: hype, leaderboard-only sites without published methodology, marketing language.

### Secondary: hardware-engineering researcher
- **Role:** PhD student or industry researcher in computer architecture
- **Age range:** 26–45
- **Day-in-the-life:** Reads ISCA / MICRO / HPCA, runs gem5 / Verilator simulations, occasionally curious about how AI is changing their field.
- **Frustration:** "Can a model find a microarch trick I haven't seen?" — no good way to check.
- **Aspiration:** see hypothesis text from real model attempts at improving a CPU. Read what an LLM wrote about ALU bypass paths. Borrow tricks back.
- **Discovery:** ACM Digital Library, GitHub trending, Hacker News.
- **Trust signals:** real RTL, real formal coverage, real FPGA numbers. Distrusts: simulator-only benchmarks, fake-data demos.

## Brand Essence

### Emotional Compass
- **brand_heartbeat:** The kind of benchmark that lets a frontier model still have somewhere to go.

### Promise
- **Core promise:** When someone interacts with HWE Bench, they feel they're reading research, not a product pitch.
- **Functional promise:** A reproducible, formally-gated, FPGA-grounded fitness score for LLM-generated CPU designs — with full per-rep transcripts available.
- **Emotional promise:** Quiet confidence. The reader doesn't need to be sold; they need to be respected.

### Point of View
- **Category disagreement:** Most benchmarks plateau. The interesting benchmarks don't — they reward open-ended capability rather than saturable surface skills.
- **Underestimated truth:** Hardware design is one of the few engineering domains where "better" is unambiguous (Fmax × IPC under correctness gates) AND the design space is genuinely unbounded.
- **Manifesto line:** SWE-bench tops out at 100%. HWE Bench tops out wherever the best microarchitecture happens to be — which is always moving.

### Personality
- **Personality:** rigorous, restrained, defended
- **Personality reference:** like METR meets a well-written ACM paper
- **Not us:** salesy, mascot-y
- **Never be:** hype-driven, playful, crypto/AI-bro aesthetic, marketing-fluff
- **Tone:** scientific, understated, with quiet provocation — willing to defend one thesis (unbounded scoreboard) without sloganizing

## Competitive Landscape
- **Direct competitors:** SWE-bench (software engineering eval), EEMBC CoreMark (CPU bench), METR Atlas (long-horizon capability eval)
- **What sets you apart?** Unbounded score (no ceiling), real-hardware grounding (FPGA Fmax + LUT count), formal-verification gating, full per-iteration transcripts published
- **Brands admired:** metr.org, Stripe Press (restraint), Anthropic research blog

## Visual Direction
- **Mood / aesthetic:** peer-reviewed paper, but readable on a phone. METR-aligned. Restrained typography. Data viz as the centerpiece.
- **Reference links:** https://metr.org/
- **Texture / atmosphere:** warm off-white background, near-black ink, one subdued accent for emphasis (muted academic red or verified blue). Generous line-height (1.6–1.7). Wide left-aligned text columns. Charts > illustrations. Occasional monochrome block diagrams (RTL stages) if illustrative.
- **Anti-patterns:** no neon gradients, no glass-morphism, no hexagon patterns, no mascots, no hero illustrations, no "Get Started" CTAs, no stock photography, no Vercel-OS dark-mode-with-glow aesthetic, no LaTeX-document sterility.

## Inspiration
- **Styles liked:** metr.org (single reference, tight alignment)
- **Styles to avoid:** hype-driven marketing pages, crypto-bro tech aesthetics, playful illustrated landing pages
- **Existing assets:** none — fresh slate visually. Substantive content available: bench/LEADERBOARD.md, bench/results.jsonl, per-rep log.jsonl + agent.log files, BENCH_METHODOLOGY.md, ARCHITECTURE.md, README.md

## Constraints
- **Timeline:** publish within days of brief completion
- **Budget:** zero (open-source / self-hosted on GitHub Pages)
- **Must-haves:**
  - Hosted on GitHub Pages from this repo's main branch
  - Print-friendly stylesheet (the site prints to a clean PDF research note)
  - Title mentions RISC-V
- **Non-negotiables:**
  - Tight metr.org-aligned visual aesthetic
  - No marketing fluff, no playful tone, no crypto/AI-bro aesthetic

## Goals
- **Business goal:** publish a credible, citable benchmark site that ML capability researchers will actually link to
- **Brand goal:** establish HWE Bench as the canonical "unbounded benchmark for LLM hardware design" — the SWE-bench of microarchitecture
- **Success metrics:**
  - Links from at least one external research site / mailing list within 90 days
  - Citation in at least one paper within 12 months
  - Site loads under 2 seconds, prints cleanly to PDF, scores 100/100 on Lighthouse accessibility

## Deliverables
- [ ] Discovery & research
- [ ] Brand strategy & voice
- [ ] Visual identity
- [ ] Design system

## Notes
The site populates from live bench artifacts:
- bench/LEADERBOARD.md → main leaderboard
- bench/results.jsonl → 15 rep-rows; structured data for tables / charts
- bench/<model>/rep<N>/log.jsonl → per-iteration journals (lut4, ff, fmax_mhz, ipc_coremark, cycles)
- bench/<model>/rep<N>/agent.log → full model transcripts (can be linked as evidence)
- BENCH_METHODOLOGY.md, ARCHITECTURE.md → methodology pages
- README.md → project intro

The unbounded-scoreboard thesis is the brand's defended argument. Headline copy must make this concrete by referencing the empirical curve (currently +85.6% peak, not yet plateaued). Never sloganize it — make the reader infer it from the data.
