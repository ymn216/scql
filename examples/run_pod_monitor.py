#!/usr/bin/env python3
"""Run SystemMonitor inside a pod until SIGTERM/SIGINT, then write JSON to --output."""

import argparse
import os
import signal
import sys
import time

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from system_monitor import SystemMonitor  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description="Pod-side CPU/memory/network sampler for system_monitor.py")
    parser.add_argument("--interface", default="eth0", help="NIC name (K8s pods usually eth0)")
    parser.add_argument("--interval", type=float, default=0.5, help="Sample interval in seconds")
    parser.add_argument("--output", default="/tmp/monitor.json", help="JSON output path")
    args = parser.parse_args()

    import psutil

    pernic = psutil.net_io_counters(pernic=True) or {}
    if args.interface not in pernic:
        names = ", ".join(sorted(pernic.keys())) or "(none)"
        print(
            f"WARNING: interface {args.interface!r} not in psutil counters; "
            f"network samples will be zero. Available: {names}",
            file=sys.stderr,
            flush=True,
        )

    pid = os.getpid()
    with open("/tmp/monitor.pid", "w", encoding="utf-8") as pid_file:
        pid_file.write(str(pid))

    print(
        f"run_pod_monitor: iface={args.interface} interval={args.interval} pid={pid}",
        flush=True,
    )

    monitor = SystemMonitor(args.interval)
    monitor.start_all(args.interface)

    def stop_and_exit(*_):
        monitor.stop_and_output(args.output)
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop_and_exit)
    signal.signal(signal.SIGINT, stop_and_exit)

    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
