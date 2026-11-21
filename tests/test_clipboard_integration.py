"""Real X11 selection requests with a simulated Windows metadata/data backend."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from urllib.parse import unquote, urlparse

BINARY = os.environ.get('QT_BRIDGE_BINARY')


@unittest.skipUnless(BINARY and os.environ.get('DISPLAY'), 'requires compiled bridge and X11')
class ClipboardIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.state = self.base / 'state.json'
        self.log = self.base / 'requests.log'
        self.seq = 0
        self.source = self.base / '黑龙江分院-明细.xlsx'
        self.source.write_bytes(b'original Windows desktop workbook')
        self.update('FILES', [str(self.source)])
        installer = (Path(__file__).resolve().parents[1] / 'install.sh').read_text()
        helper = self.base / '.local/lib/wsl-clipboard-session/stage-files'
        helper.parent.mkdir(parents=True)
        helper.write_text(installer.split("<<'STAGE_FILES'\n", 1)[1].split('\nSTAGE_FILES\n', 1)[0])
        helper.chmod(0o700)
        wslpath = self.base / 'wslpath'
        wslpath.write_text('#!/usr/bin/env python3\nimport sys\nprint(sys.argv[-1])\n')
        wslpath.chmod(0o700)
        self.host = self.base / 'fake-powershell'
        self.host.write_text('''#!/usr/bin/env python3
import base64, json, os, sys
from pathlib import Path
for line in sys.stdin:
    with open(os.environ['TEST_REQUESTS'], 'a') as log: log.write(line)
    parts = line.strip().split(' ')
    state = json.loads(Path(os.environ['TEST_STATE']).read_text())
    seq = state['sequence']
    action = parts[0]
    if action == 'POLL':
        reply = 'SAME ' + seq if parts[1] == seq else state['kind'] + ' ' + seq
    elif action == 'CHECK':
        reply = 'CURRENT' if parts[1] == seq else 'CHANGED'
    elif action == 'PULL':
        reply = ('FILES ' + seq + ' ' + ' '.join(base64.b64encode(p.encode()).decode() for p in state['paths'])
                 if parts[1] == seq and state['kind'] == 'FILES' else 'CHANGED')
    elif action == 'EXPORT':
        if parts[1] != seq: reply = 'CHANGED'
        else:
            seq = str(int(seq) + 1)
            state.update(sequence=seq, kind='OTHER', paths=[])
            Path(os.environ['TEST_STATE']).write_text(json.dumps(state))
            reply = 'OK ' + seq
    else: reply = 'ERROR'
    print(reply, flush=True)
''')
        self.host.chmod(0o700)
        self.script = self.base / 'backend.ps1'
        self.script.write_text('')
        self.cache = self.base / '.cache/wsl-clipboard/files'

    def update(self, kind, paths=None):
        self.seq += 1
        pending = self.base / 'state.new'
        pending.write_text(json.dumps({'sequence': str(self.seq), 'kind': kind, 'paths': paths or []}))
        pending.replace(self.state)

    def start(self):
        self.process = subprocess.Popen([BINARY, str(self.host), str(self.script)],
                                        env={**os.environ, 'HOME': str(self.base),
                                             'PATH': str(self.base) + os.pathsep + os.environ['PATH'],
                                             'TEST_STATE': str(self.state), 'TEST_REQUESTS': str(self.log)},
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        def stop():
            self.process.terminate()
            try: self.process.communicate(timeout=4)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.communicate()
        self.addCleanup(stop)
        self.wait_for(lambda: any(r.startswith('POLL ') for r in self.requests()))

    def requests(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def wait_for(self, predicate, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate(): return
            self.assertIsNone(self.process.poll(), 'bridge exited unexpectedly')
            time.sleep(0.05)
        self.fail('condition timed out')

    def read(self, target='text/uri-list', timeout=8):
        result = subprocess.run(['xclip', '-selection', 'clipboard', '-target', target, '-o'],
                                capture_output=True, timeout=timeout)
        return result.stdout.decode() if result.returncode == 0 else None

    def wait_targets(self):
        self.wait_for(lambda: 'text/uri-list' in (self.read('TARGETS') or ''))

    def test_windows_copy_and_format_probes_do_not_transfer(self):
        self.start()
        self.wait_targets()
        for _ in range(3):
            targets = self.read('TARGETS').splitlines()
            self.assertNotIn('text/plain', targets)
            self.assertNotIn('UTF8_STRING', targets)
        time.sleep(0.7)  # Polling and any focus change have no data-fetch branch.
        self.assertFalse(self.cache.exists())
        self.assertFalse(any(r.startswith(('PULL ', 'EXPORT ')) for r in self.requests()))

    def test_actual_uri_paste_fetches_once_and_reuses_same_copy(self):
        self.start(); self.wait_targets()
        data = self.read()
        self.assertTrue(data)
        path = Path(unquote(urlparse(data.strip()).path))
        self.assertEqual(path.read_bytes(), self.source.read_bytes())
        self.assertEqual(self.read(), data)
        self.assertEqual(sum(r.startswith('PULL ') for r in self.requests()), 1)
        self.assertFalse(any(r.startswith('EXPORT ') for r in self.requests()))

    def test_gnome_paste_requests_file_data(self):
        self.start(); self.wait_targets()
        data = self.read('x-special/gnome-copied-files')
        self.assertTrue(data.startswith('copy\nfile://'))
        self.assertEqual(sum(r.startswith('PULL ') for r in self.requests()), 1)

    def test_new_copy_before_paste_uses_new_file(self):
        self.start(); self.wait_targets()
        next_file = self.base / '第二份.xlsx'; next_file.write_bytes(b'new copy')
        self.update('FILES', [str(next_file)])
        time.sleep(0.6)
        data = self.read()
        self.assertEqual(Path(unquote(urlparse(data.strip()).path)).read_bytes(), b'new copy')
        self.assertEqual(sum(r.startswith('PULL ') for r in self.requests()), 1)

    def test_large_file_selection_uses_incr(self):
        self.update('FILES', [str(self.source)] * 700)
        self.start(); self.wait_targets()
        data = self.read(timeout=20)
        self.assertTrue(data and len(data) > 32768)
        self.assertEqual(len(data.splitlines()), 700)
        self.assertEqual(sum(r.startswith('PULL ') for r in self.requests()), 1)

    def own(self, target, content):
        owner = subprocess.Popen(['xclip', '-selection', 'clipboard', '-target', target, '-in', '-quiet'],
                                 stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        owner.stdin.write(content.encode()); owner.stdin.close()
        def stop():
            if owner.poll() is None: owner.terminate()
            try: owner.wait(timeout=3)
            except subprocess.TimeoutExpired: owner.kill(); owner.wait()
        self.addCleanup(stop)
        self.wait_for(lambda: self.read(target) == content)

    def test_linux_file_copy_exports_without_windows_import(self):
        self.update('OTHER')
        self.start()
        self.own('text/uri-list', self.source.as_uri() + '\r\n')
        self.wait_for(lambda: any(r.startswith('EXPORT ') for r in self.requests()))
        self.assertFalse(any(r.startswith('PULL ') for r in self.requests()))
        self.assertFalse(self.cache.exists())

    def test_cache_alias_is_never_exported(self):
        cache = self.cache / 'copy-existing/1'; cache.mkdir(parents=True)
        original = cache / 'cached.xlsx'; original.write_bytes(b'cache')
        alias = self.base / 'alias.xlsx'; alias.symlink_to(original)
        self.update('OTHER'); self.start()
        self.own('text/uri-list', alias.as_uri() + '\r\n')
        time.sleep(0.8)
        self.assertFalse(any(r.startswith('EXPORT ') for r in self.requests()))

    def test_native_html_is_preserved(self):
        self.update('OTHER'); self.start()
        html = '<b>中文格式 😀</b>'
        self.own('text/html', html)
        time.sleep(0.5)
        self.update('OTHER'); time.sleep(0.5)
        self.assertEqual(self.read('text/html'), html)
        self.assertFalse(any(r.startswith(('PULL ', 'EXPORT ')) for r in self.requests()))


if __name__ == '__main__': unittest.main()
