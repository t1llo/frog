#!/usr/bin/env python3
"""Read existing release/tag names from stdin and choose the next patch version."""
import re
import sys


def next_version(tags):
    versions = []
    for tag in tags:
        match = re.fullmatch(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag.strip())
        if match:
            versions.append(tuple(map(int, match.groups())))
    latest = max(versions, default=(0, 0, 0))
    if latest < (1, 0, 0):
        return "1.0.0"
    major, minor, patch = latest
    return f"{major}.{minor}.{patch + 1}"


if __name__ == "__main__":
    print(next_version(sys.stdin))
