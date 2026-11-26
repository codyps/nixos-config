#!/usr/bin/env python3
import hashlib
import io
import importlib.util
import json
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
        self.assertEqual(root.findtext('.//u:AutoLogon/u:Username', namespaces=ns), 'runner')

    def test_pinned_bootstrap_asset_selection(self):
        manifest = image.package_manifest()
        selected = []
        def release(repo, match, path, tag):
            candidates = {
                'runner.zip': ('actions-runner-win-x64-2.338.2.zip', 'actions-runner-win-arm64-2.338.2.zip'),
                'git.exe': ('Git-2.56.1-64-bit.exe', 'Git-2.56.1-arm64.exe'),
                'powershell.msi': ('PowerShell-7.6.10-win-x64.msi', 'PowerShell-7.6.10-win-arm64.msi'),
                'winget.msixbundle': ('Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle', 'DesktopAppInstallerPolicies.zip'),
                'winget-dependencies.zip': ('DesktopAppInstaller_Dependencies.zip', 'DesktopAppInstallerPolicies.zip'),
            }
            good, wrong = candidates[path.name]
            self.assertTrue(match(good))
            self.assertFalse(match(wrong))
            self.assertTrue(tag.startswith('v'))
            selected.append(path.name)
            return {'repository': repo, 'version': tag}
        with patch.object(image, 'release_asset', side_effect=release):
            assets = image.download_packages(Path('/synthetic-seed'), manifest)
        self.assertEqual(len(assets), 5)
        self.assertEqual(len(set(selected)), 5)

    def test_rejects_ambiguous_package_manifest(self):
        manifest = image.package_manifest()
        manifest['winget_packages'].append(manifest['winget_packages'][0])
        with patch.object(Path, 'read_text', return_value=json.dumps(manifest)):
            with self.assertRaisesRegex(ValueError, 'duplicate WinGet'):
                image.package_manifest()

    def test_cached_release_is_reverified_before_reuse(self):
        data = b'synthetic-bootstrap-installer'
        expected = hashlib.sha256(data).hexdigest()
        release = {'tag_name': 'v1.0', 'assets': [{
            'name': 'bootstrap.exe', 'digest': 'sha256:' + expected,
            'size': len(data), 'browser_download_url': 'https://example.invalid/bootstrap.exe',
        }]}
        def response(*args, **kwargs):
            return io.BytesIO(json.dumps(release).encode())
        def download(url, path, size):
            path.write_bytes(data)
        with tempfile.TemporaryDirectory() as temporary:
            seed = Path(temporary) / 'build' / 'seed'
            seed.mkdir(parents=True)
            with patch.object(image.urllib.request, 'urlopen', side_effect=response), patch.object(image, 'download', side_effect=download) as fetch:
                for name in ['first.exe', 'second.exe']:
                    result = image.release_asset('synthetic/repo', lambda n: n.endswith('.exe'), seed / name, tag='v1.0')
                    self.assertEqual(result['sha256'], expected)
                    self.assertEqual((seed / name).read_bytes(), data)
                self.assertEqual(fetch.call_count, 1)
                (Path(temporary) / 'downloads' / expected).write_bytes(b'corrupt')
                with self.assertRaisesRegex(ValueError, 'cached asset SHA256 mismatch'):
                    image.release_asset('synthetic/repo', lambda n: True, seed / 'third.exe', tag='v1.0')
                self.assertFalse((seed / 'third.exe').exists())

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

    def test_publication_uses_the_build_manifest_and_hashes_read_only_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work = root / 'build'
            work.mkdir()
            for name in ['disk.qcow2', 'OVMF_CODE.fd', 'OVMF_VARS.fd']:
                (work / name).write_bytes(b'synthetic image fixture')
            (work / 'tpm').mkdir()
            (work / 'tpm/state').write_bytes(b'synthetic TPM fixture, not a production key')
            iso = root / 'installation.iso'
            iso.write_bytes(b'synthetic ISO fixture')
            args = SimpleNamespace(work_dir=work, destination=root / 'published', iso=iso, memory_mib=8192, cpus=4)
            snapshot = {'schema_version': 1, 'image_version': 'synthetic-v2'}
            def run(*command):
                if command[1] == 'convert':
                    Path(command[-1]).write_bytes((work / 'disk.qcow2').read_bytes())
            with patch.object(image, 'run', side_effect=run), patch.object(image, 'package_manifest', side_effect=AssertionError('Publication must use the captured build manifest')):
                image.publish(args, [], snapshot)
            published = args.destination
            self.assertEqual(json.loads((published / 'packages.json').read_text()), snapshot)
            manifest = json.loads((published / 'manifest.json').read_text())
            self.assertEqual(manifest['source_iso_sha256'], image.digest(iso))
            for name, expected in manifest['files'].items():
                self.assertEqual(image.digest(published / name), expected)
            for path in [published, *published.rglob('*')]:
                self.assertEqual(path.stat().st_mode & 0o222, 0)


if __name__ == '__main__':
    unittest.main()
