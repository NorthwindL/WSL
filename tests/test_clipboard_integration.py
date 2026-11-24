"""Real X11 selection requests with a simulated Windows metadata/data backend."""
import base64
import json
import os
from pathlib import Path
import subprocess
import struct
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
        self.png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')
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
# First line loads the real PowerShell backend; it is not a clipboard request.
sys.stdin.readline()
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
                 if parts[1] == seq and state['kind'] == 'FILES' else
                 'IMAGE ' + seq + ' ' + state['image'] if parts[1] == seq and state['kind'] == 'IMAGE' else
                 'TEXT ' + seq + ' ' + state['text'] if parts[1] == seq and state['kind'] == 'TEXT' else 'CHANGED')
    elif action in ('EXPORT', 'EXIMAGE', 'EXTEXT'):
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

    def update(self, kind, paths=None, text="中文第一行\n第二行 😀"):
        self.seq += 1
        pending = self.base / 'state.new'
        pending.write_text(json.dumps({'sequence': str(self.seq), 'kind': kind, 'paths': paths or [], 'image': base64.b64encode(self.png).decode(), 'text': base64.b64encode(text.encode()).decode()}))
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
        owner.stdin.write(content if isinstance(content, bytes) else content.encode()); owner.stdin.close()
        def stop():
            if owner.poll() is None: owner.terminate()
            try: owner.wait(timeout=3)
            except subprocess.TimeoutExpired: owner.kill(); owner.wait()
        self.addCleanup(stop)
        self.wait_for(lambda: (self.read_bytes(target) if isinstance(content, bytes) else self.read(target)) == content)

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

    def test_gnome_only_linux_copy_exports(self):
        self.update('OTHER'); self.start()
        self.own('x-special/gnome-copied-files', 'copy\n' + self.source.as_uri())
        self.wait_for(lambda: any(r.startswith('EXPORT ') for r in self.requests()))
        self.assertFalse(any(r.startswith('PULL ') for r in self.requests()))

    def test_new_windows_copy_cancels_an_inflight_paste(self):
        helper = self.base / '.local/lib/wsl-clipboard-session/stage-files'
        helper.write_text(helper.read_text().replace('def main():', 'def main():\n    time.sleep(1)'))
        self.start(); self.wait_targets()
        reader = subprocess.Popen(['xclip', '-selection', 'clipboard', '-target', 'text/uri-list', '-o'],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: reader.kill() if reader.poll() is None else None)
        self.wait_for(lambda: any(r.startswith('PULL ') for r in self.requests()))
        self.update('OTHER')
        stdout, _ = reader.communicate(timeout=8)
        self.assertEqual(stdout, b'')
        self.assertFalse(self.cache.exists())


    def read_bytes(self, target):
        result = subprocess.run(['xclip', '-selection', 'clipboard', '-target', target, '-o'],
                                capture_output=True, timeout=8)
        return result.stdout if result.returncode == 0 else None

    def test_windows_image_is_retrieved_only_on_paste(self):
        self.update('IMAGE'); self.start()
        self.wait_for(lambda: 'image/png' in (self.read('TARGETS') or ''))
        self.assertFalse(any(r.startswith('PULL ') for r in self.requests()))
        self.assertEqual(self.read_bytes('image/png'), self.png)
        self.assertEqual(self.read_bytes('image/png'), self.png)
        self.assertEqual(sum(r.startswith('PULL ') for r in self.requests()), 1)
        self.assertFalse(self.cache.exists())

    def test_linux_png_copy_is_published_to_windows(self):
        self.update('OTHER'); self.start()
        self.own('image/png', self.png)
        self.wait_for(lambda: any(r.startswith('EXIMAGE ') for r in self.requests()))
        request = next(r for r in self.requests() if r.startswith('EXIMAGE '))
        self.assertEqual(base64.b64decode(request.split(' ')[2]), self.png)
        self.assertFalse(any(r.startswith('PULL ') for r in self.requests()))

    def test_image_after_file_replaces_only_file_offer(self):
        self.start(); self.wait_targets()
        self.update('IMAGE')
        self.wait_for(lambda: 'image/png' in (self.read('TARGETS') or ''))
        self.assertNotIn('text/uri-list', self.read('TARGETS'))
        self.assertEqual(self.read_bytes('image/png'), self.png)
        self.assertFalse(self.cache.exists())

    def test_file_to_text_offer_and_lazy_unicode_paste(self):
        self.start(); self.wait_targets()
        text = '中文第一行\n第二行 😀'
        self.update('TEXT', text=text)
        self.wait_for(lambda: 'UTF8_STRING' in (self.read('TARGETS') or ''))
        self.assertNotIn('text/uri-list', self.read('TARGETS'))
        time.sleep(0.6)
        self.assertFalse(any(r.startswith(('PULL ', 'EXPORT ', 'EXTEXT ')) for r in self.requests()))
        self.assertEqual(self.read('UTF8_STRING'), text)
        self.assertEqual(self.read('text/plain;charset=utf-8'), text)
        self.assertEqual(self.read('TEXT'), text)
        self.assertEqual(sum(r.startswith('PULL ') for r in self.requests()), 1)
        self.assertFalse(self.cache.exists())

    def test_large_windows_text_uses_incr(self):
        text = '中文 😀 多行\n' * 15000
        self.update('TEXT', text=text); self.start()
        self.wait_for(lambda: 'UTF8_STRING' in (self.read('TARGETS') or ''))
        self.assertEqual(self.read('UTF8_STRING', timeout=20), text)
        self.assertEqual(self.read('text/plain', timeout=20), text)
        self.assertEqual(sum(r.startswith('PULL ') for r in self.requests()), 1)

    def test_empty_text_paste_is_cached(self):
        self.update('TEXT', text=''); self.start()
        self.wait_for(lambda: 'UTF8_STRING' in (self.read('TARGETS') or ''))
        self.assertEqual(self.read('UTF8_STRING'), '')
        self.assertEqual(self.read('UTF8_STRING'), '')
        self.assertEqual(sum(r.startswith('PULL ') for r in self.requests()), 1)

    def test_linux_text_copy_exports_unicode_without_import(self):
        self.update('OTHER'); self.start()
        text = 'Linux 中文 😀\n第二行' * 6000
        self.own('UTF8_STRING', text)
        self.wait_for(lambda: any(r.startswith('EXTEXT ') for r in self.requests()))
        request = next(r for r in self.requests() if r.startswith('EXTEXT '))
        self.assertEqual(base64.b64decode(request.split(' ')[2]).decode(), text)
        self.assertFalse(any(r.startswith(('PULL ', 'EXPORT ', 'EXIMAGE ')) for r in self.requests()))

    def test_new_windows_text_replaces_cached_text(self):
        self.update('TEXT', text='旧文字'); self.start()
        self.wait_for(lambda: 'UTF8_STRING' in (self.read('TARGETS') or ''))
        self.assertEqual(self.read('UTF8_STRING'), '旧文字')
        self.update('TEXT', text='新文字 😀')
        self.wait_for(lambda: any(r == 'POLL ' + str(self.seq) for r in self.requests()))
        self.assertEqual(self.read('UTF8_STRING'), '新文字 😀')
        self.assertEqual(sum(r.startswith('PULL ') for r in self.requests()), 2)

    def test_image_to_text_offer_is_lazy(self):
        self.update('IMAGE'); self.start()
        self.wait_for(lambda: 'image/png' in (self.read('TARGETS') or ''))
        self.update('TEXT', text='截图后的文字')
        self.wait_for(lambda: 'UTF8_STRING' in (self.read('TARGETS') or ''))
        self.assertNotIn('image/png', self.read('TARGETS'))
        self.assertFalse(any(r.startswith('PULL ') for r in self.requests()))
        self.assertEqual(self.read('UTF8_STRING'), '截图后的文字')

    def test_image_to_native_html_handoff(self):
        self.update('IMAGE'); self.start()
        self.wait_for(lambda: 'image/png' in (self.read('TARGETS') or ''))
        self.assertEqual(self.read_bytes('image/png'), self.png)
        self.update('OTHER'); time.sleep(0.5)
        html = '<b>原生 HTML 文本</b>'
        self.own('text/html', html)
        self.assertEqual(self.read('text/html'), html)
        self.assertFalse(any(r.startswith(('EXPORT ', 'EXIMAGE ')) for r in self.requests()))


    def test_linux_bmp_only_copy_is_published_as_image(self):
        bmp = b'BM' + struct.pack('<IHHI', 58, 0, 0, 54) + struct.pack('<IiiHHIIiiII', 40, 1, 1, 1, 24, 0, 4, 0, 0, 0, 0) + bytes((0, 0, 255, 0))
        self.update('OTHER'); self.start()
        self.own('image/bmp', bmp)
        self.wait_for(lambda: any(r.startswith('EXIMAGE ') for r in self.requests()))
        request = next(r for r in self.requests() if r.startswith('EXIMAGE '))
        self.assertEqual(base64.b64decode(request.split(' ')[2]), bmp)


    @unittest.skipUnless(os.environ.get('MIXED_CLIPBOARD_BINARY'), 'requires a mixed-format application fixture')
    def test_mixed_text_and_image_exports_text_not_image(self):
        self.update('OTHER'); self.start()
        owner = subprocess.Popen([os.environ['MIXED_CLIPBOARD_BINARY']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 env={**os.environ, 'QT_QPA_PLATFORM': 'xcb'})
        def stop():
            owner.terminate()
            try: owner.wait(timeout=3)
            except subprocess.TimeoutExpired: owner.kill(); owner.wait()
        self.addCleanup(stop)
        text = '原生 mixed 文本 😀'
        self.wait_for(lambda: self.read('UTF8_STRING') == text)
        self.wait_for(lambda: any(r.startswith('EXTEXT ') for r in self.requests()))
        self.assertIn('image/png', self.read('TARGETS'))
        self.assertIn(text, self.read('text/html'))
        request = next(r for r in self.requests() if r.startswith('EXTEXT '))
        self.assertEqual(base64.b64decode(request.split(' ')[2]).decode(), text)
        self.assertFalse(any(r.startswith(('PULL ', 'EXPORT ', 'EXIMAGE ')) for r in self.requests()))


if __name__ == '__main__': unittest.main()
