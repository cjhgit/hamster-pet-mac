#!/usr/bin/env python3
"""Measure the already-running app, without starting a replacement test window."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import time


def process_times(pid):
    row = subprocess.check_output(
        ["ps", "-p", str(pid), "-o", "time=,pcpu=,rss=,etime="], text=True
    ).split()
    cpu = sum(float(value) * 60**i for i, value in enumerate(reversed(row[0].split(":"))))
    return cpu, int(row[2]), row[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--interval", type=float, default=5)
    parser.add_argument("--count", type=int, default=3)
    parser.add_argument("--sample", action="store_true", help="Also save a five-second macOS stack sample")
    parser.add_argument("--output", type=Path, default=Path("/private/tmp/hamster-app-profile"))
    args = parser.parse_args()
    if not 1 <= args.interval <= 60 or not 1 <= args.count <= 120:
        parser.error("interval must be 1–60 seconds; count must be 1–120")
    if args.pid is None:
        result = subprocess.run(["pgrep", "-x", "Hamster Pet"], capture_output=True, text=True)
        pids = result.stdout.split()
        if len(pids) != 1:
            parser.error("Please start Hamster Pet; if multiple apps are running, specify --pid")
        args.pid = int(pids[0])
    args.output.mkdir(parents=True, exist_ok=True)
    records = []
    print(f"PID {args.pid}; keep the real app visible. 100% CPU = one core.", flush=True)
    for _ in range(args.count):
        start_cpu, _, _ = process_times(args.pid)
        start = time.monotonic()
        time.sleep(args.interval)
        end_cpu, rss, uptime = process_times(args.pid)
        elapsed = time.monotonic() - start
        record = {"pid": args.pid, "timestamp": datetime.datetime.now().astimezone().isoformat(),
                  "seconds": elapsed, "cpuPercent": (end_cpu - start_cpu) / elapsed * 100,
                  "residentKiB": rss, "processUptime": uptime}
        records.append(record)
        print(json.dumps(record), flush=True)
    (args.output / "cpu.json").write_text(json.dumps(records, indent=2) + "\n")
    if args.sample:
        subprocess.run(["sample", str(args.pid), "5", "-file", str(args.output / "stacks.txt")], check=True)
    print(f"Saved to {args.output}")


if __name__ == "__main__":
    main()
