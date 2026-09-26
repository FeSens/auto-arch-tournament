# HWE Bench — STYLE.md

The consolidated, opinionated style guide for the HWE Bench site. Every page must follow this. The tokens here are the source of truth for `site/css/tokens.css`.

## Composition rules

1. **Single column for prose.** No multi-column layouts. Body text sets to `--w-prose` (64ch). The single exception is the leaderboard table, which uses `--w-wide` (1080px).
2. **Headlines sit alone.** A heading never shares a line with anything else. Always preceded by `--s-12` of space above, followed by `--s-4` below.
3. **No CTAs.** Buttons exist only for actions that change UI state (sort a column, expand a row). No "Get Started" / "Read More" / "Learn More" buttons. Internal navigation is links.
4. **No icons** (see IDENTITY.md). Where weight is needed, use the typeface itself.
5. **Numbers in mono.** Any number that contributes to the argument (fitness, LUT4, Fmax, %) sets in `--font-mono`. Prose-counts stay in body sans.
6. **One accent.** `--accent` (`#1F4380`) appears at most once per visual unit: a link, a chart highlight, the manifesto rule. Never decoratively.
7. **Rule, not box.** Section dividers are horizontal `1px` rules in `--rule`. Not borders, not cards. The page is a scroll of prose with rules between sections.
8. **Print works.** Every page must print to a clean PDF that a reviewer could read offline. `@media print` overrides remove nav, footer, hovers, dark accents that print poorly.

## Layout

- Page width: `--w-page` (1200px) max; content goes to `--w-wide` (1080px) max; prose to `--w-prose` (64ch).
- Vertical rhythm: `--s-6` between body paragraphs, `--s-12` before h2, `--s-8` before h3.
- Sidebar / nav: top-bar only, set in body sans, all caps tracked +1px, `--text-sm`.

## Header / nav

```
HWE Bench    methodology   models   data           v1 · 2026-05
```

- Wordmark left, navigation right, version stamp far right.
- All inline. No hamburger menu (the navigation is small enough to fit; mobile collapses to a single wrap).
- Underline on hover only.

## Footer

```
─── ─── ─── ─── ─── ─── ─── ─── ─── ─── ─── ─── ─── ─── ─── ───
HWE Bench · methodology v1 · auto-arch-tournament on GitHub
"A benchmark that respects how far a frontier model still has to go."
```

- Top rule + 3 lines, set in `--text-sm`, `--ink-soft`.
- The manifesto line sets in `--font-mono`, italicized, `--ink-muted`.

## Tables

Tables are the centerpiece. They must read at a glance.

- Header row: `--bg-sunk` background, `--text-sm`, `--font-body` 500 weight, all caps tracked +1px.
- Body rows: alternating `--bg` / `--bg-sunk`. No row borders except top/bottom of table.
- Numeric cells: right-aligned, `--font-mono`.
- Improvement rows: subtle left-edge `2px` accent in `--success`.
- Broken rows: subtle left-edge `2px` accent in `--warning`.
- Hover: row background tints to `--accent-soft`.
- No vertical grid lines. Horizontal lines only between header and body.

## Code blocks

- `--bg-sunk` background, no border.
- `--font-mono`, `--text-base`, line-height 1.5.
- Generous padding: `--s-4` `--s-6`.
- No syntax highlighting in v1 (would require a build step; consider in iteration 2).

## Links

- Color: `--accent`.
- Default: no underline.
- Hover: `1px` underline, offset `2px` below baseline.
- External links: open in same tab. Trailing `↗` glyph in `--ink-muted` after the link text.

## Accessibility

- Contrast: `--ink` on `--bg` = 13.5:1, well above AAA (7:1) for body text.
- Focus state: `2px` outline in `--accent`, offset `2px`. Never `outline: none`.
- Body text size: `--text-lg` (18px) — comfortable for long reads.
- Min target size: 44×44px for any interactive element.
- All charts (when added) include a text-table fallback for screen readers.

## File layout (site/)

```
site/
├── index.html              # Home / leaderboard
├── methodology.html        # Methodology page
├── models.html             # Per-model + per-rep deep dive
├── data.html               # Downloads + transcript index
├── css/
│   ├── tokens.css          # All --tokens, no rules
│   ├── reset.css           # Modern CSS reset
│   ├── style.css           # Global styles, layout, components
│   └── print.css           # @media print overrides
├── assets/
│   └── fonts/              # Self-hosted variable fonts (Source Serif 4, Inter, Plex Mono)
└── _build/                 # Build cache; gitignored
```

The site has NO JavaScript framework. One small vanilla-JS file may be added for sortable tables (progressive enhancement only). The site loads and reads usefully with JS disabled.

## Build

A Python script (`tools/site/build.py`) reads bench data and writes the HTML files. The script runs at commit time (manually, or via a GitHub Action). The generated HTML is committed; GitHub Pages serves it directly. No CI build step required.
