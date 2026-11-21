"""Exercise the compiled bridge on real X11 with a simulated Windows protocol.

CI supplies QT_BRIDGE_BINARY and runs this suite under Xvfb. Windows clipboard
APIs are simulated; X11 selection delivery is real.
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

BINARY = os.environ.get('QT_BRIDGE_BINARY')


@unittest.skipUnless(BINARY and os.environ.get('DISPLAY'), 'requires compiled bridge and X11')
class ClipboardIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.state = self.base / 'state.json'
        self.log = self.base / 'requests.log'
        self.sequence = 0
        self.update('TEXT', 'initial')
        self.host = self.base / 'fake-powershell'
        self.host.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
for line in sys.stdin:
    with open(os.environ['TEST_REQUESTS'], 'a') as log:
        log.write(line)
    parts = line.strip().split(' ')
    state = json.loads(Path(os.environ['TEST_STATE']).read_text())
    sequence = state['sequence']
    if parts[0] == 'CHECK':
        reply = 'CURRENT' if parts[1] == sequence else 'CHANGED'
    elif parts[0] == 'READ':
        reply = ('SAME ' + sequence if parts[1] == sequence else
                 state['type'] + ' ' + sequence + ' ' + state['data'])
    else:
        reply = 'ERROR'
    print(reply, flush=True)
''')
        self.host.chmod(0o700)
        self.script = self.base / 'backend.ps1'
        self.script.write_text('')

    def update(self, kind, text):
        self.sequence += 1
        pending = self.base / 'pending.json'
        pending.write_text(json.dumps({'sequence': str(self.sequence), 'type': kind,
                                       'data': base64.b64encode(text.encode()).decode()}))
        pending.replace(self.state)

    def start(self, mode='--text-files'):
        self.process = subprocess.Popen([BINARY, str(self.host), str(self.script), mode],
                                        env={**os.environ, 'QT_QPA_PLATFORM': 'xcb',
                                             'TEST_STATE': str(self.state),
                                             'TEST_REQUESTS': str(self.log)},
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        def stop():
            self.process.terminate()
            try:
                self.process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.communicate()
        self.addCleanup(stop)

    def read(self):
        result = subprocess.run(['xclip', '-selection', 'clipboard', '-target', 'UTF8_STRING', '-o'],
                                capture_output=True, timeout=2)
        return result.stdout.decode('utf-8') if result.returncode == 0 else None

    def await_text(self, expected):
        deadline = time.monotonic() + 8
        actual = None
        while time.monotonic() < deadline:
            self.assertIsNone(self.process.poll(), 'clipboard bridge exited unexpectedly')
            actual = self.read()
            if actual == expected:
                return
            time.sleep(0.1)
        self.fail(f'clipboard mismatch: expected {expected[:100]!r}, got {str(actual)[:100]!r}')

    def test_windows_unicode_multiline_long_and_empty_text(self):
        self.start()
        self.await_text('initial')
        for text in ('  中文测试😀\r\n第二行\r末行\n', '中文😀ABC\n' * 4000, ''):
            self.update('TEXT', text)
            self.await_text(text.replace('\r\n', '\n').replace('\r', '\n'))
        requests = self.log.read_text().splitlines()
        self.assertFalse(any(line.startswith('TEXT ') for line in requests),
                         'native reverse text must not be republished by the file exporter')

    def test_image_and_empty_frames_do_not_clear_text(self):
        self.start()
        self.await_text('initial')
        for kind in ('IMAGE', 'EMPTY'):
            self.update(kind, 'ignored image payload')
            time.sleep(0.7)
            self.assertEqual(self.read(), 'initial')

    def test_legacy_files_only_does_not_import_text(self):
        self.start('--files-only')
        deadline = time.monotonic() + 5
        while not self.log.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertTrue(self.log.exists())
        self.assertNotEqual(self.read(), 'initial')


if __name__ == '__main__':
    unittest.main()
