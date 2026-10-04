#!/usr/bin/env python3
"""Re-run every V2 descriptive analysis (light CPU: Python over JSON and logs).

    python3 research/v2/analyses/run_all.py [--rebuild-transcripts]

--rebuild-transcripts re-parses the 36 agent.full.log.gz files (about 20 s)
into results/transcript_sessions.jsonl; otherwise the cached file is reused.
"""
import sys

import a1_effort
import a2_failures
import a3_selfchecks
import a4_lessons
import a5_monitor
import a6_transfer
import common
import transcripts

if __name__ == "__main__":
    rows = common.load_scored_rows()
    problems = common.cross_check_final(rows)
    print("cross-check vs analysis_final:", "ok" if not problems else problems)
    transcripts.build_cache(force="--rebuild-transcripts" in sys.argv)
    for mod in (a1_effort, a2_failures, a3_selfchecks, a4_lessons, a5_monitor, a6_transfer):
        mod.main()
