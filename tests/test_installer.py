"""Regression checks without installing packages or requiring a Windows host."""
import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = (Path(__file__).resolve().parents[1] / 'install.sh').read_text()


def embedded(marker):
    return SOURCE.split("<<'" + marker + "'\n", 1)[1].split('\n' + marker + '\n', 1)[0] + '\n'


class StagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        helper = self.base / 'stage.py'
        helper.write_text(embedded('STAGE_FILES'))
        spec = importlib.util.spec_from_file_location('staging', helper)
        self.stage = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.stage)
        self.root = self.base / 'cache'
        self.root.mkdir()
        self.source = self.base / '文件 空格\nemoji😀'
        self.source.write_bytes('中文文本'.encode())

    def test_copy_permissions_and_duplicate_names(self):
        other = self.base / 'other'
        other.mkdir()
        duplicate = other / self.source.name
        duplicate.write_bytes(b'different')
        self.source.chmod(0o400)
        names = self.stage.stage([self.source, duplicate], self.root)
        self.assertEqual(Path(names[0]).read_bytes(), self.source.read_bytes())
        self.assertEqual(Path(names[1]).read_bytes(), b'different')
        self.assertEqual(stat.S_IMODE(Path(names[0]).stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(Path(names[0]).parents[1].stat().st_mode), 0o700)

    def test_symlinks_rejected_in_nested_directory(self):
        directory = self.base / 'nested'
        directory.mkdir()
        (directory / 'link').symlink_to(self.source)
        with self.assertRaisesRegex(ValueError, 'symbolic'):
            self.stage.stage([directory], self.root)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_size_limit_is_aggregate(self):
        with patch.object(self.stage, 'MAX_BYTES', self.source.stat().st_size):
            with self.assertRaisesRegex(ValueError, '512 MiB'):
                self.stage.stage([self.source, self.source], self.root)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_space_reserve(self):
        usage = self.stage.shutil.disk_usage(self.root)
        with patch.object(self.stage.shutil, 'disk_usage', return_value=usage._replace(free=0)):
            with self.assertRaisesRegex(ValueError, 'disk space'):
                self.stage.stage([self.source], self.root)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_partial_copy_is_removed(self):
        original_open = self.stage.os.open
        def open_source(path, *args, **kwargs):
            if path == self.source:
                raise OSError('source unavailable')
            return original_open(path, *args, **kwargs)
        with patch.object(self.stage.os, 'open', side_effect=open_source):
            with self.assertRaises(OSError):
                self.stage.stage([self.source], self.root)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_cleanup_only_expired_copies(self):
        old, recent, unrelated = [self.root / n for n in ('copy-old', 'copy-new', 'keep')]
        for path in (old, recent, unrelated):
            path.mkdir()
        past = time.time() - self.stage.TTL - 1
        for path in (old, unrelated):
            os.utime(path, (past, past))
        self.stage.cleanup(self.root)
        self.assertFalse(old.exists())
        self.assertTrue(recent.exists())
        self.assertTrue(unrelated.exists())

    def test_null_protocol_preserves_newlines(self):
        helper = self.base / 'stage.py'
        result = subprocess.run(['python3', str(helper), '--null', str(self.source)],
                                env={**os.environ, 'HOME': str(self.base)}, capture_output=True, check=True)
        name = result.stdout.rstrip(b'\0').decode()
        self.assertEqual(Path(name).name, self.source.name)
        self.assertEqual(Path(name).read_bytes(), self.source.read_bytes())

    def test_idle_cleanup_does_not_create_cache(self):
        helper = self.base / 'stage.py'
        subprocess.run(['python3', str(helper), '--cleanup'],
                       env={**os.environ, 'HOME': str(self.base)}, check=True)
        self.assertFalse((self.base / '.cache/wsl-clipboard/files').exists())


class InstallerTests(unittest.TestCase):
    def test_default_and_mode_plans(self):
        script = Path(__file__).resolve().parents[1] / 'install.sh'
        for args, mode in [([], 'files'), (['--native'], 'native'), (['--with-files'], 'files')]:
            output = subprocess.check_output(['bash', str(script), '--dry-run', *args], text=True)
            self.assertIn('剪贴板模式=' + mode, output)
            self.assertIn('中文环境=是', output)
            if mode == 'files':
                self.assertIn('纯文本经桥接写入 Wayland', output)
            else:
                self.assertIn('桥接关闭，不传输 Windows 文件', output)
                self.assertIn('文本和图片均由 WSLg 原生通道处理', output)
        for args, expected in [(['--without-chinese'], '否'),
                               (['--with-chinese'], '是'),
                               (['--without-chinese', '--with-chinese'], '是')]:
            output = subprocess.check_output(['bash', str(script), '--dry-run', *args], text=True)
            self.assertIn('中文环境=' + expected, output)
            self.assertIn('剪贴板模式=files', output)

    def test_all_embedded_shell_scripts_parse(self):
        for marker in ('DIRECT', 'DIRECT_APP', 'DESKTOP_START'):
            subprocess.run(['bash', '-n'], input=embedded(marker), text=True, check=True)


if __name__ == '__main__':
    unittest.main()
