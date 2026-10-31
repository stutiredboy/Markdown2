#!/usr/bin/env python3
"""Fail a test run whose skipped XCTest cases are not all expected.

A GUI-gated test that skips passes green, so a lane that runs with
MD2_RUN_GUI_TESTS=1 proves nothing unless every skip is accounted for: a lost
environment variable, a window server that never came up, or a new skip path
would otherwise land silently. This reads the `swift test` output, collects
every skipped XCTest case with its reason, and checks each one against an
allowlist of expected skips, each pinned to its test and to the start of its
reason.

Allowlist format, one entry per line (blank lines and `#` comments ignored):

    MD2CoreTests.SomeTests/testName | reason prefix

Usage:
    python3 Scripts/check_test_skips.py test.log .github/gui-expected-skips.txt
"""
import re
import sys

# XCTest prints this line for every skipped case, so it decides what skipped.
SKIPPED_CASE = re.compile(r"Test Case '-\[(?P<suite>[\w.]+) (?P<test>\w+)\]' skipped")
# The reason line has no " - reason" for a bare `XCTSkip()`; such a skip has
# an empty reason, which no allowlist entry matches.
SKIP_REASON = re.compile(r": -\[(?P<suite>[\w.]+) (?P<test>\w+)\] : Test skipped(?: - (?P<reason>.*))?$")
EXECUTED_LINE = re.compile(r"Executed \d+ tests?, with ")


def load_allowlist(path):
    entries = {}
    with open(path, encoding="utf-8") as handle:
        for number, raw in enumerate(handle, start=1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            test_id, separator, reason = (part.strip() for part in line.partition("|"))
            if not separator or "/" not in test_id or not reason:
                sys.exit(f"{path}:{number}: expected 'Suite/test | reason prefix', got: {line}")
            if test_id in entries:
                sys.exit(f"{path}:{number}: duplicate entry for {test_id}")
            entries[test_id] = reason
    return entries


def main(log_path, allowlist_path):
    allowed = load_allowlist(allowlist_path)
    skipped = set()
    reasons = {}
    ran = False
    with open(log_path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\n")
            ran = ran or bool(EXECUTED_LINE.search(line))
            if match := SKIPPED_CASE.search(line):
                skipped.add(f"{match['suite']}/{match['test']}")
            elif match := SKIP_REASON.search(line):
                reasons[f"{match['suite']}/{match['test']}"] = match["reason"] or ""

    if not ran:
        sys.exit(f"{log_path}: no XCTest summary found; the test run did not happen or was not captured")

    unexpected = []
    for test_id in sorted(skipped):
        reason = reasons.get(test_id, "")
        shown = reason or "(no reason given)"
        prefix = allowed.get(test_id)
        if prefix is None:
            unexpected.append(f"  {test_id}: {shown}")
        elif not reason.startswith(prefix):
            unexpected.append(f"  {test_id}: {shown}\n    (allowed only with reason starting: {prefix})")

    for test_id in sorted(set(allowed) - set(skipped)):
        print(f"note: expected skip did not occur (the test ran, or no longer exists): {test_id}")

    print(f"{len(skipped)} skipped, {len(skipped) - len(unexpected)} expected")
    if unexpected:
        print("Unexpected skips (each one is a guard that did not run):")
        print("\n".join(unexpected))
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
