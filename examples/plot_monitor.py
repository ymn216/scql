#!/usr/bin/env python3
"""Plot monitor JSON produced by run_pod_monitor.py (host-side)."""

import argparse
import os
import sys

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from system_monitor import draw_usage_graph, get_time_stamp, get_usage_dict  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("monitor_json", help="Path to monitor JSON from alice pod")
    parser.add_argument("-o", "--output", default="", help="PNG path (default: <json>.png)")
    parser.add_argument("--stamp", default="", help="Optional stamp file for phase markers")
    args = parser.parse_args()

    png = args.output or (os.path.splitext(args.monitor_json)[0] + ".png")
    usage = get_usage_dict(args.monitor_json)
    stamps = get_time_stamp(args.stamp) if args.stamp else None
    if stamps:
        draw_usage_graph(usage, png, stamps)
    else:
        draw_usage_graph(usage, png)
    print(png)


if __name__ == "__main__":
    main()
