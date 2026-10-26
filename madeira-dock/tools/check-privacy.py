#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Secret and personal-data scan for the Madeira Dock repository.

Fails on personal user paths (C:\\Users\\<name>, /home/<name>, /Users/<name>),
email addresses, JWT-like tokens (Steam refresh/access tokens are JWTs),
private keys and common API tokens, real-looking SteamID64 values other than
the documented synthetic test IDs, and Steam login cache content
(loginusers.vdf / config.vdf keys, ssfn files).

  python3 tools/check-privacy.py              # tracked files (working tree)
  python3 tools/check-privacy.py --history    # every blob and commit message
                                              # reachable from any ref
  python3 tools/check-privacy.py FILE...      # explicit files
  python3 tools/check-privacy.py --self-test  # rule fixtures

Public Madeira's .githooks/pre-commit and pre-push apply the same rules to
added lines. Keep the patterns in sync when changing either copy.
"""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

# Placeholder and system account names that identify nobody.
ALLOWED_USERS = {
    'public', 'default', 'default user', 'all users', 'shared', 'guest',
    'user', 'username', 'name', 'you', 'me', 'someone', 'example', 'runner',
    'steamuser', 'wineuser', 'madeira', 'mobile', 'build_user', 'crossover',
}
# Synthetic SteamID64 values used by tests: account 0 (invalid) and 1.
ALLOWED_STEAMIDS = {'76561197960265728', '76561197960265729'}
ALLOWED_EMAIL = re.compile(
    r'(^noreply@(anthropic|github)\.com$|@users\.noreply\.github\.com$|'
    r'^git@github\.com$|@example\.(com|org|net)$|\.(invalid|test|example|localhost)$|'
    r'@[0-9]+x\.[a-z]+$)', re.I)
# Third-party licence texts legitimately carry their authors' addresses.
LICENCE_PATH = re.compile(
    r'(^|/)(LICENSES|notices)/|(^|/)(COPYING|LICENSE[^/]*|NOTICE[^/]*|THIRD[-_]PARTY[^/]*)$', re.I)
SENSITIVE_NAME = re.compile(r'(^|/)((loginusers|config|localconfig)\.vdf|ssfn[^/]*)$', re.I)

RULES = [
    ('user-path', re.compile(
        r'(?<![A-Za-z0-9_])(?:[A-Za-z]:)?[\\/]+(?:[Uu]sers|home|Documents and Settings)[\\/]+'
        r'([A-Za-z0-9][A-Za-z0-9._-]*)')),
    ('email', re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}')),
    ('jwt', re.compile(r'\bey[A-Za-z0-9_-]{10,}\.ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}')),
    ('private-key', re.compile(r'-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----')),
    ('api-token', re.compile(
        r'\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|'
        r'sk-ant-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,})')),
    ('steamid', re.compile(r'(?<![0-9])7656119[0-9]{10}(?![0-9])')),
    ('steam-login-cache', re.compile(
        r'"(?:AccountName|PersonaName|RememberPassword|AllowAutoLogin|WantsOfflineMode|'
        r'SkipOfflineModeWarning|ConnectCache)"\s+"')),
]


def findings_in_text(path, text):
    """Yield (path, line number, rule, match) for every finding."""
    for number, line in enumerate(text.splitlines(), 1):
        for rule, pattern in RULES:
            for match in pattern.finditer(line):
                value = match.group(0)
                if rule == 'user-path' and match.group(1).lower() in ALLOWED_USERS:
                    continue
                if rule == 'email' and (ALLOWED_EMAIL.search(value) or LICENCE_PATH.search(path)):
                    continue
                if rule == 'steamid' and value in ALLOWED_STEAMIDS:
                    continue
                yield path, number, rule, value


def decode(data):
    if b'\0' in data[:8192]:
        return None  # binary
    return data.decode('utf-8', 'replace')


def git(*args, data=None):
    return subprocess.run(['git', *args], cwd=ROOT, input=data, check=True,
                          capture_output=True).stdout


def scan_worktree(paths):
    for path in paths:
        if SENSITIVE_NAME.search(path):
            yield path, 0, 'steam-login-cache-file', path
        file = ROOT / path
        if file.is_file():
            text = decode(file.read_bytes())
            if text is not None:
                yield from findings_in_text(path, text)


def scan_history():
    """Every blob and commit message reachable from any ref."""
    names = {}
    for entry in git('rev-list', '--all', '--objects').decode().splitlines():
        sha, _, path = entry.partition(' ')
        if path:
            names.setdefault(sha, path)
    request = ''.join(f'{sha}\n' for sha in names).encode()
    kinds = git('cat-file', '--batch-check', data=request).decode().splitlines()
    blobs = [line.split()[0] for line in kinds if line.split()[1] == 'blob']
    for sha in blobs:
        label = f'{names[sha]} ({sha[:10]})'
        if SENSITIVE_NAME.search(names[sha]):
            yield label, 0, 'steam-login-cache-file', names[sha]
        text = decode(git('cat-file', 'blob', sha))
        if text is not None:
            # Match on the real path (licence-file exemption), report with the blob id.
            for _, number, rule, value in findings_in_text(names[sha], text):
                yield label, number, rule, value
    log = git('log', '--all', '--format=%H%x00%B%x01').decode('utf-8', 'replace')
    for record in log.split('\x01'):
        sha, _, message = record.strip('\n').partition('\x00')
        if sha:
            yield from findings_in_text(f'commit message {sha[:10]}', message)


def self_test():
    at = '@'
    fixtures = {
        'C:' + '\\Users\\' + 'alice\\x': 'user-path',
        '/home' + '/bob/.cache': 'user-path',
        'carol' + at + 'mail.example-isp.net': 'email',
        'ey' + 'J' + 'a' * 12 + '.ey' + 'b' * 12 + '.' + 'c' * 12: 'jwt',
        '7656119' + '8012345678': 'steamid',
        '"Account' + 'Name"\t\t"someone"': 'steam-login-cache',
        '-----BEGIN ' + 'RSA PRIVATE KEY-----': 'private-key',
    }
    clean = ['C:' + '\\users\\steamuser\\x', '/home' + '/<name>', 'fixture' + at + 'example.invalid',
             'icon' + at + '2x.png', '76561197960265729', '"AccountName": value', '/Home/End keys']
    for text, rule in fixtures.items():
        found = [f[2] for f in findings_in_text('fixture', text)]
        assert found == [rule], (text, found)
    for text in clean:
        found = list(findings_in_text('fixture', text))
        assert not found, (text, found)
    assert list(findings_in_text('LICENSES/x.txt', 'author' + at + 'mail.example-isp.net')) == []
    assert SENSITIVE_NAME.search('backup/loginusers.vdf') and not SENSITIVE_NAME.search('app.vdf')
    print(f'PASS: {len(fixtures)} findings detected, {len(clean) + 1} allowed values ignored')


def main(argv):
    if argv[:1] == ['--self-test']:
        self_test()
        return 0
    if argv[:1] == ['--history']:
        findings = list(scan_history())
        scope = 'all history'
    else:
        paths = argv or git('ls-files').decode().splitlines()
        findings = list(scan_worktree(paths))
        scope = f'{len(paths)} files'
    for path, number, rule, value in findings:
        print(f'{path}:{number}: {rule}: {value}')
    if findings:
        print(f'FAIL: {len(findings)} secret/personal-data finding(s) in {scope}', file=sys.stderr)
        return 1
    print(f'PASS: no secrets or personal data in {scope}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
