#!/usr/bin/env python3
"""Summarize CATLIVE_PROFILE_LAYOUT=1 JSONL without touching the application."""
import argparse
import collections
import csv
import json
import sys


def summarize(rows):
    groups = collections.defaultdict(list)
    for row in rows:
        groups[(int(row["timeMS"] / 1000), row["host"], row["role"], row["event"])].append(row)
    for (second, host, role, event), values in sorted(groups.items()):
        values.sort(key=lambda row: row["timeMS"])
        durations = [row["durationMS"] for row in values if "durationMS" in row]
        frames = collections.Counter((row["window"], row["frameSource"], row["frame"]) for row in values)
        arrivals = [row["timeMS"] for row in values]
        sources = [row["inputTimestampMS"] for row in values if "inputTimestampMS" in row]

        def mean_gap(times):
            return "" if len(times) < 2 else round((times[-1] - times[0]) / (len(times) - 1), 3)

        yield [second, host, role, event, len(values),
               round(sum(durations), 3), round(max(durations, default=0), 3),
               max(frames.values()), mean_gap(arrivals), mean_gap(sources),
               values[-1]["frameSource"], values[-1]["width"], values[-1]["height"]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", help="/tmp/catlive-layout-PID.jsonl")
    args = parser.parse_args()
    rows = []
    with open(args.log, encoding="utf-8") as source:
        for line in source:
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                # A live writer may still be finishing the final buffered line.
                print("Ignored an incomplete JSONL record", file=sys.stderr)
    writer = csv.writer(sys.stdout)
    writer.writerow(["second", "host", "role", "event", "count", "inclusive_total_ms", "max_ms",
                     "max_per_frame", "mean_arrival_gap_ms", "mean_source_gap_ms", "frame_source",
                     "last_width", "last_height"])
    writer.writerows(summarize(rows))


if __name__ == "__main__":
    main()
