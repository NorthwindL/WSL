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
        self.sequence = 0
        self.export_result = 'OK'
        helper = self.base / '.local/lib/wsl-clipboard-session/stage-files'
        helper.parent.mkdir(parents=True)
        installer = (Path(__file__).resolve().parents[1] / 'install.sh').read_text()
        helper.write_text(installer.split("<<'STAGE_FILES'\n", 1)[1].split('\nSTAGE_FILES\n', 1)[0])
        helper.chmod(0o700)
        wslpath = self.base / 'wslpath'
        wslpath.write_text('#!/usr/bin/env python3\nimport sys\nprint(sys.argv[-1])\n')
        wslpath.chmod(0o700)
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
    elif parts[0] == 'FILES':
        result = os.environ.get('TEST_EXPORT_RESULT', 'OK')
        if result == 'CHANGED':
            state.update(sequence=str(int(sequence) + 1), type='TEXT', data='bmV3IFdpbmRvd3MgdGV4dA==')
            Path(os.environ['TEST_STATE']).write_text(json.dumps(state))
            reply = 'CHANGED'
        elif result == 'ERROR':
            reply = 'ERROR'
        else:
            reply = 'OK ' + sequence
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

    def start(self, mode='--files-only'):
        self.process = subprocess.Popen([BINARY, str(self.host), str(self.script), mode],
                                        env={**os.environ, 'QT_QPA_PLATFORM': 'xcb',
                                             'TEST_STATE': str(self.state),
                                             'TEST_EXPORT_RESULT': self.export_result,
                                             'HOME': str(self.base),
                                             'PATH': str(self.base) + os.pathsep + os.environ['PATH'],
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

    def read(self, target='UTF8_STRING'):
        result = subprocess.run(['xclip', '-selection', 'clipboard', '-target', target, '-o'],
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
        self.start('--text-files')
        self.await_text('initial')
        for text in ('  中文测试😀\r\n第二行\r末行\n', '中文😀ABC\n' * 4000, ''):
            self.update('TEXT', text)
            self.await_text(text.replace('\r\n', '\n').replace('\r', '\n'))
        requests = self.log.read_text().splitlines()
        self.assertFalse(any(line.startswith('TEXT ') for line in requests),
                         'native reverse text must not be republished by the file exporter')

    def test_image_and_empty_frames_do_not_clear_text(self):
        self.start('--text-files')
        self.await_text('initial')
        for kind in ('IMAGE', 'EMPTY'):
            self.update(kind, 'ignored image payload')
            time.sleep(0.7)
            self.assertEqual(self.read(), 'initial')

    def test_default_files_only_does_not_import_text(self):
        self.start('--files-only')
        deadline = time.monotonic() + 5
        while not self.log.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertTrue(self.log.exists())
        self.assertNotEqual(self.read(), 'initial')

    def own_selection(self, target, value):
        owner = subprocess.Popen(['xclip', '-selection', 'clipboard', '-target', target, '-in', '-quiet'],
                                 stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        owner.stdin.write(value.encode())
        owner.stdin.close()
        def stop():
            if owner.poll() is None:
                owner.terminate()
            try:
                owner.wait(timeout=3)
            except subprocess.TimeoutExpired:
                owner.kill()
                owner.wait()
        self.addCleanup(stop)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.read(target) == value:
                return
            time.sleep(0.1)
        self.fail('test selection owner did not become available')

    def wait_for_requests(self, prefix):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if self.log.exists():
                lines = self.log.read_text().splitlines()
                if any(line.startswith(prefix) for line in lines):
                    return lines
            time.sleep(0.1)
        self.fail('missing protocol request ' + prefix)

    def test_native_rich_text_is_preserved_across_windows_copies(self):
        html = '<p><b>中文 bold 😀</b></p>'
        self.own_selection('text/html', html)
        self.start()
        self.wait_for_requests('READ ')
        for value in ('new Windows text', '第二次复制', ''):
            self.update('TEXT', value)
            time.sleep(0.7)
            self.assertEqual(self.read('text/html'), html)
        requests = self.log.read_text().splitlines()
        self.assertFalse(any(line.startswith(('TEXT ', 'FILES ', 'IMAGE ')) for line in requests))

    def test_imported_files_have_no_plain_text_fallback_or_export_echo(self):
        source = self.base / '源 中文.txt'
        source.write_bytes('文件内容'.encode())
        self.update('FILES', str(source))
        self.start()
        deadline = time.monotonic() + 8
        uris = None
        while time.monotonic() < deadline:
            uris = self.read('text/uri-list')
            if uris:
                break
            time.sleep(0.1)
        self.assertTrue(uris, 'Windows file must be offered to X11')
        copied = Path(unquote(urlparse(uris.strip()).path))
        self.assertEqual(copied.read_bytes(), source.read_bytes())
        targets = self.read('TARGETS').splitlines()
        for target in ('UTF8_STRING', 'STRING', 'text/plain', 'text/plain;charset=utf-8'):
            self.assertNotIn(target, targets, 'file paths must not trigger native text synchronization')
        self.update('TEXT', 'a newer Windows copy')
        time.sleep(0.8)
        self.assertFalse(any(line.startswith('FILES ') for line in self.log.read_text().splitlines()),
                         'imported files must not be exported back into Windows')

    def export_local_file(self):
        source = self.base / 'local.txt'
        source.write_text('local file')
        self.start()
        self.wait_for_requests('READ ')
        time.sleep(0.6)
        self.own_selection('text/uri-list', source.as_uri() + '\r\n')
        self.wait_for_requests('FILES ')
        time.sleep(1.2)
        return [line for line in self.log.read_text().splitlines() if line.startswith('FILES ')]

    def test_local_file_export_still_works_once(self):
        self.assertEqual(len(self.export_local_file()), 1)

    def test_failed_export_is_not_repeated(self):
        self.export_result = 'ERROR'
        self.assertEqual(len(self.export_local_file()), 1)

    def test_new_windows_copy_wins_over_stale_file_export(self):
        self.export_result = 'CHANGED'
        self.assertEqual(len(self.export_local_file()), 1)


    def test_windows_file_copy_stays_deferred_until_linux_focus(self):
        source = self.base / 'desktop.xlsx'
        source.write_bytes(b'original desktop file')
        self.update('DEFER', '')
        self.start()
        self.wait_for_requests('READ ')
        time.sleep(0.8)
        self.assertFalse((self.base / '.cache/wsl-clipboard/files').exists(),
                         'Windows-only copying must not create Linux cache copies')
        # Focus changes, but the Windows clipboard sequence does not.
        pending = self.base / 'pending.json'
        pending.write_text(json.dumps({'sequence': str(self.sequence), 'type': 'FILES',
                                       'data': base64.b64encode(str(source).encode()).decode()}))
        pending.replace(self.state)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            uris = self.read('text/uri-list')
            if uris:
                copied = Path(unquote(urlparse(uris.strip()).path))
                if copied.exists() and copied.read_bytes() == source.read_bytes():
                    return
            time.sleep(0.1)
        self.fail('Deferred copy was consumed before the Linux focus change')

    def test_symlink_to_windows_cache_is_not_exported(self):
        cache = self.base / '.cache/wsl-clipboard/files/copy-example/1'
        cache.mkdir(parents=True)
        source = cache / 'desktop.xlsx'
        source.write_bytes(b'Windows origin')
        alias = self.base / 'shortcut.xlsx'
        alias.symlink_to(source)
        self.start()
        self.wait_for_requests('READ ')
        time.sleep(0.6)
        self.own_selection('text/uri-list', alias.as_uri() + '\r\n')
        time.sleep(1.2)
        self.assertFalse(any(line.startswith('FILES ') for line in self.log.read_text().splitlines()),
                         'A symlink to a Windows import was exported back into Windows')



if __name__ == '__main__':
    unittest.main()
