#!/usr/bin/env python3
"""Isolated privacy-policy regressions; never inspect the caller's Git history."""
import contextlib
import io
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest import mock

SCANNER = Path(__file__).with_name('check-history-privacy.py')
ACCEPTED = (
    b'73befe3f05f4803c538df8bf4cb6d88ff94d4020',
    b'cd79b9d19f10b43b811304d6e128a7b306e59165',
)
# Synthetic fixture only; assemble the suffix so the test source is itself clean.
PRIVATE_EMAIL = b'fixture@synthetic.' + b'lan'


class HistoryPrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='history-privacy-test-')
        self.addCleanup(self.temp.cleanup)
        self.old_cwd = Path.cwd()
        self.addCleanup(os.chdir, self.old_cwd)
        os.chdir(self.temp.name)
        # Ignore inherited Git routing and identity/configuration, including hooks.
        env = {key: value for key, value in os.environ.items()
               if not key.startswith('GIT_')}
        env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_AUTHOR_NAME='Fixture', GIT_COMMITTER_NAME='Fixture',
                   GIT_AUTHOR_EMAIL='fixture@example.com',
                   GIT_COMMITTER_EMAIL='fixture@example.com')
        self.environment = mock.patch.dict(os.environ, env, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.git('init', '--quiet')
        Path('fixture.txt').write_text('Safe fixture content.\n')
        self.git('add', 'fixture.txt')
        self.git('commit', '--quiet', '-m', 'Synthetic fixture')

    def git(self, *args, env=None):
        return subprocess.check_output(['git', *args], stderr=subprocess.PIPE,
                                       env=env)

    def scan(self, metadata=None):
        real_check_output = subprocess.check_output

        def check_output(args, *positional, **kwargs):
            if metadata is not None and args == [
                    'git', 'log', '--all', '--format=%H%x00%ae%x00%ce']:
                # Only immutable accepted object IDs require simulation. Tags,
                # blobs, object traversal and other Git calls remain real.
                return metadata
            return real_check_output(args, *positional, **kwargs)

        output = io.StringIO()
        real_popen = subprocess.Popen
        processes = []

        def popen(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            processes.append(process)
            return process

        try:
            with mock.patch.object(subprocess, 'check_output', side_effect=check_output):
                with mock.patch.object(subprocess, 'Popen', side_effect=popen):
                    with contextlib.redirect_stdout(output):
                        with self.assertRaises(SystemExit) as result:
                            runpy.run_path(str(SCANNER), run_name='__main__')
        finally:
            # The existing scanner waits for cat-file but leaves its read pipe
            # open. Close fixture-owned streams without changing scanner policy.
            for process in processes:
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream is not None and not stream.closed:
                        stream.close()
                process.wait()
        return result.exception.code, output.getvalue()

    def metadata(self, sha, author=PRIVATE_EMAIL, committer=PRIVATE_EMAIL):
        return b'\0'.join((sha, author, committer)) + b'\n'

    def test_exact_accepted_commit_metadata_passes(self):
        for sha in ACCEPTED:
            with self.subTest(commit=sha.decode()):
                code, output = self.scan(self.metadata(sha))
                self.assertEqual(code, 0)
                self.assertIn('0 privacy findings.', output)

    def test_short_accepted_hash_is_not_an_exception(self):
        for sha in ACCEPTED:
            with self.subTest(commit=sha.decode()):
                code, output = self.scan(self.metadata(sha[:12]))
                self.assertEqual(code, 1)
                self.assertIn('private commit email', output)

    def test_same_prefix_different_full_hash_is_rejected(self):
        for sha in ACCEPTED:
            changed = sha[:-1] + (b'1' if sha[-1:] != b'1' else b'2')
            with self.subTest(commit=sha.decode()):
                code, output = self.scan(self.metadata(changed))
                self.assertEqual(code, 1)
                self.assertIn('private commit email', output)

    def test_other_real_commit_private_author_is_rejected(self):
        env = dict(os.environ, GIT_AUTHOR_EMAIL=PRIVATE_EMAIL.decode())
        self.git('commit', '--quiet', '--allow-empty', '-m', 'Private author', env=env)
        code, output = self.scan()
        self.assertEqual(code, 1)
        self.assertIn('private commit email', output)

    def test_other_real_commit_private_committer_is_rejected(self):
        env = dict(os.environ, GIT_COMMITTER_EMAIL=PRIVATE_EMAIL.decode())
        self.git('commit', '--quiet', '--allow-empty', '-m', 'Private committer', env=env)
        code, output = self.scan()
        self.assertEqual(code, 1)
        self.assertIn('private commit email', output)

    def test_accepted_commit_does_not_hide_other_commit(self):
        metadata = self.metadata(ACCEPTED[0]) + self.metadata(b'1' * 40)
        code, output = self.scan(metadata)
        self.assertEqual(code, 1)
        self.assertIn('111111111111: private commit email', output)

    def test_private_annotated_tag_is_rejected_even_with_accepted_commit(self):
        env = dict(os.environ, GIT_COMMITTER_EMAIL=PRIVATE_EMAIL.decode())
        self.git('tag', '-a', 'fixture-tag', '-m', 'Synthetic tag', env=env)
        code, output = self.scan(self.metadata(ACCEPTED[0]))
        self.assertEqual(code, 1)
        self.assertIn('private tagger email', output)

    def test_private_blob_is_rejected_even_with_accepted_commit(self):
        Path('fixture.txt').write_bytes(b'Synthetic host: synthetic.' + b'lan\n')
        self.git('add', 'fixture.txt')
        self.git('commit', '--quiet', '-m', 'Synthetic private blob')
        code, output = self.scan(self.metadata(ACCEPTED[1]))
        self.assertEqual(code, 1)
        self.assertIn('private network hostname', output)

    def test_safe_clean_commit_passes(self):
        code, output = self.scan()
        self.assertEqual(code, 0)
        self.assertIn('0 privacy findings.', output)


if __name__ == '__main__':
    unittest.main(verbosity=2)
