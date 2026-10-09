#!/usr/bin/env python3
"""Scan reachable history for private paths/hosts without printing their values."""
import re
import subprocess
import sys

patterns = {
    'personal home path': re.compile(rb'/Users/' + rb'(?!runner(?:/|\b)|example(?:/|\b)|user(?:/|\b))[^/\s\'\"]+/'),
    'private network hostname': re.compile(rb'\b[\w.-]+\.(?:localdomain|ts\.net|lan)\b', re.I),
    'embedded cloud account': re.compile(rb'GoogleDrive-' + rb'(?!developer@example\.com|example@)[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', re.I),
}
private_email = re.compile(rb'@[^\s]+\.(?:localdomain|local|lan|ts\.net)$', re.I)
findings = set()
for line in subprocess.check_output(['git', 'log', '--all', '--format=%H%x00%ae%x00%ce']).splitlines():
    commit, author, committer = line.split(b'\0')
    if private_email.search(author) or private_email.search(committer):
        findings.add((commit.decode()[:12], 'private commit email'))
for line in subprocess.check_output(['git', 'for-each-ref', 'refs/tags', '--format=%(refname)%00%(taggeremail:trim)']).splitlines():
    ref, email = line.split(b'\0')
    if private_email.search(email):
        findings.add((ref.decode(), 'private tagger email'))
objects = subprocess.check_output(['git', 'rev-list', '--objects', '--all']).splitlines()
process = subprocess.Popen(['git', 'cat-file', '--batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
text_count = 0
for row in objects:
    sha, _, name = row.partition(b' ')
    process.stdin.write(sha + b'\n')
    process.stdin.flush()
    header = process.stdout.readline().split()
    data = process.stdout.read(int(header[2]))
    process.stdout.read(1)
    if header[1] != b'blob' or b'\0' in data:
        continue
    try:
        data.decode('utf8')
    except UnicodeDecodeError:
        continue
    text_count += 1
    for reason, pattern in patterns.items():
        if pattern.search(data):
            findings.add((name.decode(errors='replace'), reason))
process.stdin.close()
process.wait()
for path, reason in sorted(findings):
    print(f'{path}: {reason}')
print(f'Checked {text_count} historical text objects; {len(findings)} privacy findings.')
sys.exit(bool(findings))
