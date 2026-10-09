#!/usr/bin/env python3
"""Reject accidentally tracked local data/keys; print paths, never contents."""
from pathlib import PurePosixPath, Path
import re
import subprocess
import sys

paths = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
failures = []
for name in filter(None, paths):
    path = PurePosixPath(name)
    parts = path.parts
    if (parts[0] in {"tmp", "local-test", "private-fixtures", "verified-download"}
            or parts[0].startswith("verified-v")
            or path.suffix.lower() in {".p12", ".pfx", ".pem", ".key", ".p8", ".keychain-db"}
            or (path.name.startswith(".env") and path.name != ".env.example")
            or name.startswith(("Backend/data/", "Backend/storage/", "Backend/minio-data/"))):
        failures.append((name, "local data or credentials"))
        continue
    if path.suffix.lower() not in {".md", ".swift", ".sh", ".py", ".js", ".yml", ".yaml", ".html"}:
        continue
    text = Path(name).read_text(encoding="utf-8")
    if re.search(r"/Users/" + r"(?!runner(?:/|\b)|example(?:/|\b)|user(?:/|\b))[^/\s'\"]+/", text):
        failures.append((name, "personal home path"))
for name, reason in failures:
    print(f"{name}: {reason}")
print(f"Checked {len(list(filter(None, paths)))} tracked files; {len(failures)} findings.")
sys.exit(bool(failures))
