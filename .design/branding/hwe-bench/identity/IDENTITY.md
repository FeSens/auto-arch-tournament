# HWE Bench — Visual Identity

## Color

Restrained 3-tone palette: warm off-white ground, near-black ink, one accent. No gradients. No dark mode in v1.

| Token | Hex | Use |
|---|---|---|
| `--bg` | `#FAF7F2` | Page background. Warm off-white, eggshell tone. |
| `--bg-sunk` | `#F2EEE5` | Subtle surface (table headers, code blocks, sidebar). |
| `--ink` | `#1A1A1A` | Primary text and headlines. Near-black, never pure #000. |
| `--ink-soft` | `#4A4A4A` | Secondary text (captions, metadata). |
| `--ink-muted` | `#8A8480` | Tertiary text (labels, timestamps). |
| `--rule` | `#D9D3C8` | Borders, dividers, table grid. |
| `--accent` | `#1F4380` | One accent. Deep verified blue. Used for links, the manifesto rule, the chart accent line. |
| `--accent-soft` | `#E5EBF4` | Accent tint for highlighted rows, hovers. |
| `--success` | `#2A6F4E` | Improvement rows in tables. Muted green. |
| `--warning` | `#8A5A2B` | Broken / regression rows. Muted ochre. |

## Typography

Two faces. Both available on Google Fonts (free, GitHub Pages compatible). No paid licenses.

- **Display (serif):** [Source Serif 4](https://fonts.google.com/specimen/Source+Serif+4) — a Tiempos-adjacent serif with strong editorial credibility. Used for h1, h2, h3 and any pull-quote.
- **Body (sans):** [Inter](https://fonts.google.com/specimen/Inter) — modernist sans for body prose, UI labels, navigation. Variable axis.
- **Mono (data):** [IBM Plex Mono](https://fonts.google.com/specimen/IBM+Plex+Mono) — for code, fitness numbers, command-line snippets, and the manifesto line (rendered in mono for typographic contrast).

| Token | Family | Weight | Use |
|---|---|---|---|
| `--font-display` | Source Serif 4 | 400, 600 | Headlines, pull-quotes |
| `--font-body` | Inter | 400, 500 | Body prose, UI, nav |
| `--font-mono` | IBM Plex Mono | 400, 500 | Code, numbers, manifesto |

## Type Scale

Modular, 1.25 ratio (perfect fourth — restrained, doesn't shout).

| Token | Size | Line height | Use |
|---|---|---|---|
| `--text-xs` | 0.75rem (12px) | 1.4 | Captions, metadata |
| `--text-sm` | 0.875rem (14px) | 1.5 | UI labels, table cells |
| `--text-base` | 1rem (16px) | 1.6 | Default UI |
| `--text-lg` | 1.125rem (18px) | 1.7 | Body prose (default) |
| `--text-xl` | 1.5rem (24px) | 1.4 | h3 |
| `--text-2xl` | 2rem (32px) | 1.3 | h2 |
| `--text-3xl` | 2.75rem (44px) | 1.15 | h1 |
| `--text-hero` | 4rem (64px) | 1.05 | Hero on home page only |

Long-form prose is set in `--text-lg` with `--line-height: 1.7`. METR-style readability.

## Spacing

4px base unit. Used consistently across margin, padding, gap.

| Token | Size |
|---|---|
| `--s-1` | 4px |
| `--s-2` | 8px |
| `--s-3` | 12px |
| `--s-4` | 16px |
| `--s-5` | 20px |
| `--s-6` | 24px |
| `--s-8` | 32px |
| `--s-10` | 40px |
| `--s-12` | 48px |
| `--s-16` | 64px |
| `--s-20` | 80px |
| `--s-24` | 96px |
| `--s-32` | 128px |

## Layout

- **Content max-width:** `--w-prose: 64ch` (about 720px) — optimal reading line length
- **Wide max-width:** `--w-wide: 1080px` — for leaderboard tables and wider content
- **Page max-width:** `--w-page: 1200px` — extreme bound, used only for footer / nav

## Iconography

None in v1. The brand uses **typography and rules** instead of icons. If a UI element needs visual emphasis, use whitespace, a horizontal rule, or a numeric label.

Exception: the leaderboard rank uses a single character — a number — set in mono.

## Imagery

No photos. No illustrations. No 3D. No gradients.

Charts ARE the imagery:
- Fitness-over-time curves per rep (line chart in `--ink` with `--accent` highlight)
- Cost-vs-fitness scatter (model comparison)
- LUT4-vs-Fmax scatter (microarch tradeoff visualization)

Block diagrams (RTL pipeline stages) are line-drawings in `--ink` on `--bg`, no fills.

## Logo

A wordmark only. No symbol.

> **HWE Bench**

- Set in Source Serif 4, 600 weight
- "HWE" in `--ink`, "Bench" in `--ink-soft`
- Inline at 1.25rem in nav; at 4rem in the home hero
- Below the hero wordmark, in mono, in `--ink-muted`: `RV32IM · v1`

This is the entire visual identity. No favicon variant other than a 32×32 raster of the wordmark "HWE" in `--ink` on `--bg`.

## Voice in the visual

The visual identity reinforces the personality from STRATEGY.md:

- **Restraint** → 3-color palette, no gradients, no decoration
- **Precision** → modular type scale, 4px grid, mono for numbers
- **Defended** → one accent color, used only for links and the manifesto rule
- **Quiet provocation** → the manifesto line sits in mono on the home page, in `--ink-muted`, italicized — small enough to ignore, weighty enough to land if you read it
