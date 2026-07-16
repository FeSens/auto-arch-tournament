
## 2026-07-16: duplicated prompt parsers fail one at a time
The random agent and static agent each had a private hypothesis-id parser
with the same leftmost-match bug; burn-in caught the random one (N=2) and
missed the static one (N=1), which then burned a production E1a rep.
Rules adopted: (1) mechanical agents share one hardened parser helper,
(2) every prompt-parsing agent gets burned in at N >= 2 rounds, (3) an
integration test builds a real round-2 prompt via hypothesis.py and asserts
id extraction, so the bug class cannot ship again.
