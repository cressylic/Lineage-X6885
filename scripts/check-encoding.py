#!/usr/bin/env python3
import os
import sys

CRITICAL_EXTS = {".mk", ".bp", ".sh", ".py", ".xml", ".txt", ".json", ".prop", ".rc"}
SKIP_DIR_PARTS = {".git", ".repo", "out", "proprietary"}

def check_file(path, data):
    issues = []
    if data.startswith(b"\xef\xbb\xbf"):
        issues.append("UTF-8 BOM")
    if b"\r" in data:
        issues.append("CRLF line endings")
    for b in data:
        if b in (0x09, 0x0A, 0x0D):
            continue
        if 0x00 <= b < 0x20 or b == 0x7F:
            issues.append(f"control char 0x{b:02x}")
            break
    return issues

def iter_files(roots):
    for root in roots:
        if not os.path.exists(root):
            continue
        if os.path.isfile(root):
            yield root
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_PARTS]
            for name in filenames:
                if os.path.splitext(name)[1].lower() in CRITICAL_EXTS:
                    yield os.path.join(dirpath, name)

def main():
    roots = sys.argv[1:] or ["device", "vendor"]
    problems = []
    checked = 0
    for path in iter_files(roots):
        checked += 1
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError as exc:
            problems.append((path, [f"read error: {exc}"]))
            continue
        issues = check_file(path, data)
        if issues:
            problems.append((path, issues))

    if problems:
        for p, issues in problems:
            print(f"  ERR: {p} ({', '.join(issues)})")
        sys.exit(1)

if __name__ == "__main__":
    main()
