#!/usr/bin/env python3
import hashlib
import io
import importlib.util
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('windows_image', Path(__file__).parent / 'actions-windows-image/image.py')
image = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image)


class WindowsImageTests(unittest.TestCase):
    def test_answer_selects_only_the_private_disk_and_requested_image(self):
        root = ET.fromstring(image.answer_file(6, 'temporary-test-password'))
        ns = {'u': 'urn:schemas-microsoft-com:unattend'}
        disks = root.findall('.//u:DiskConfiguration/u:Disk', ns)
        self.assertEqual([d.findtext('u:DiskID', namespaces=ns) for d in disks], ['0'])
        self.assertEqual(root.findtext('.//u:InstallTo/u:DiskID', namespaces=ns), '0')
        self.assertEqual(root.findtext('.//u:MetaData/u:Value', namespaces=ns), '6')
        self.assertIn('PreventDeviceEncryption /t REG_DWORD /d 1', root.findtext('.//u:RunSynchronousCommand/u:Path', namespaces=ns))
        self.assertEqual(root.findtext('.//u:AutoLogon/u:LogonCount', namespaces=ns), '1')

    def test_parallel_download_preserves_content_and_checks_ranges(self):
        data = b'Windows-image-test-content' * (400 * 1024)
        def response(request, timeout):
            limits = request.get_header('Range').removeprefix('bytes=').split('-')
            start, end = map(int, limits)
            stream = io.BytesIO(data[start:end + 1])
            stream.status = 206
            stream.headers = {'Content-Range': f'bytes {start}-{end}/{len(data)}'}
            stream.url = request.full_url
            return stream
        with tempfile.TemporaryDirectory() as temporary, patch.object(image.urllib.request, 'urlopen', side_effect=response):
            path = Path(temporary) / 'asset'
            image.download('https://example.invalid/asset', path, len(data))
            self.assertEqual(image.digest(path), hashlib.sha256(data).hexdigest())

    def test_download_accepts_servers_without_range_support(self):
        data = b'complete-server-response'
        response = io.BytesIO(data)
        response.status = 200
        response.headers = {}
        with tempfile.TemporaryDirectory() as temporary, patch.object(image.urllib.request, 'urlopen', return_value=response):
            path = Path(temporary) / 'asset'
            image.download('https://example.invalid/asset', path, len(data))
            self.assertEqual(path.read_bytes(), data)

    def test_existing_workspace_is_never_reinstalled(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(image, 'run') as run:
            args = SimpleNamespace(work_dir=Path(temporary), destination=Path(temporary) / 'published')
            with self.assertRaisesRegex(ValueError, 'existing Windows installations'):
                image.build(args)
            run.assert_not_called()

    def test_failed_publication_cannot_be_loaded_by_scaler(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args = SimpleNamespace(work_dir=root / 'build', destination=root / 'published')
            with patch.object(image, 'run', side_effect=[None, RuntimeError('failed disk conversion')]):
                with self.assertRaisesRegex(RuntimeError, 'disk conversion'):
                    image.publish(args, [])
            self.assertFalse((args.destination / 'vm.json').exists())


if __name__ == '__main__':
    unittest.main()
