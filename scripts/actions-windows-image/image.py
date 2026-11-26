#!/usr/bin/env python3
"""Prepare a Windows 11 golden image on a Linux KVM host."""
import argparse
import concurrent.futures
import contextlib
import fcntl
import hashlib
import http.server
import json
import os
import re
from pathlib import Path
import secrets
import shutil
import signal
import socket
import subprocess
import threading
import time
import urllib.request
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent


def package_manifest():
    manifest = json.loads((HERE / 'packages.json').read_text())
    if manifest['schema_version'] != 1:
        raise ValueError('Unsupported Windows package manifest')
    names = set()
    for asset in manifest['github_releases']:
        name = asset['filename']
        if Path(name).name != name or name in names or not asset['tag']:
            raise ValueError('Invalid or duplicate release asset')
        names.add(name)
    ids = set()
    for package in manifest['winget_packages']:
        if package['id'] in ids or not package['version'] or package['scope'] not in ('user', 'machine'):
            raise ValueError('Invalid or duplicate WinGet package')
        ids.add(package['id'])
    return manifest


def download_packages(seed, manifest):
    return [release_asset(
        asset['repository'],
        lambda name, asset=asset: name.startswith(asset.get('prefix', '')) and name.endswith(asset['suffix']),
        seed / asset['filename'], tag=asset['tag']) for asset in manifest['github_releases']]


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def download(url, path, size):
    headers = {'User-Agent': 'actions-windows-image'}
    # Large release assets are slow over a single connection on this host.
    # Probe standard HTTP range support, then use bounded parallel requests.
    request = urllib.request.Request(url, headers=headers | {'Range': 'bytes=0-0'})
    with urllib.request.urlopen(request, timeout=120) as response:
        if response.status != 206 or response.headers.get('Content-Range') != f'bytes 0-0/{size}':
            with path.open('xb') as output:
                shutil.copyfileobj(response, output)
            return
        resolved = response.url
        response.read(1)
    with path.open('xb') as output:
        output.truncate(size)
    workers = min(8, max(1, size // (4 * 1024 ** 2)))
    step = (size + workers - 1) // workers

    def part(start):
        end = min(start + step, size) - 1
        for attempt in range(3):
            try:
                request = urllib.request.Request(resolved, headers=headers | {'Range': f'bytes={start}-{end}'})
                with urllib.request.urlopen(request, timeout=120) as response, path.open('r+b') as output:
                    if response.status != 206 or response.headers.get('Content-Range') != f'bytes {start}-{end}/{size}':
                        raise ValueError('Server returned an unexpected download range')
                    output.seek(start)
                    remaining = end - start + 1
                    while remaining:
                        data = response.read(min(1024 ** 2, remaining))
                        if not data:
                            raise ValueError('Incomplete release asset range')
                        output.write(data)
                        remaining -= len(data)
                return
            except (OSError, ValueError):
                if attempt == 2:
                    raise
                time.sleep(2)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        list(executor.map(part, range(0, size, step)))


def release_asset(repo, suffix, path, tag=None):
    release_path = f'tags/{tag}' if tag else 'latest'
    request = urllib.request.Request(f'https://api.github.com/repos/{repo}/releases/{release_path}',
                                     headers={'User-Agent': 'actions-windows-image'})
    with urllib.request.urlopen(request, timeout=60) as response:
        release = json.load(response)
    assets = [a for a in release['assets'] if suffix(a['name'])]
    if len(assets) != 1:
        raise ValueError(f'Expected one matching release asset in {repo}')
    asset = assets[0]
    expected = asset.get('digest', '')
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', expected):
        raise ValueError(f'{repo} has no published SHA256 for this asset')
    cache = path.parent.parent.parent / 'downloads'
    cache.mkdir(mode=0o700, exist_ok=True)
    cached = cache / expected.removeprefix('sha256:')
    if not cached.exists():
        temporary = cache / (cached.name + '.partial-' + secrets.token_hex(4))
        try:
            download(asset['browser_download_url'], temporary, asset['size'])
            if digest(temporary) != cached.name:
                raise ValueError(f'{repo} asset SHA256 mismatch')
            temporary.replace(cached)
        finally:
            temporary.unlink(missing_ok=True)
    actual = digest(cached)
    if actual != cached.name:
        raise ValueError(f'{repo} cached asset SHA256 mismatch')
    shutil.copyfile(cached, path)
    return {'repository': repo, 'version': release['tag_name'], 'asset': asset['name'], 'sha256': actual}


def answer_file(image_index, password):
    # Public Windows Pro installation key, not an activation credential.
    template = r'''<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage><InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration><Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
        <CreatePartitions>
          <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
          <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
          <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
        </CreatePartitions>
        <ModifyPartitions>
          <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
          <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
        </ModifyPartitions>
      </Disk><WillShowUI>OnError</WillShowUI></DiskConfiguration>
      <ImageInstall><OSImage><InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>IMAGE_INDEX</Value></MetaData></InstallFrom><InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo><WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>
      <UserData><AcceptEula>true</AcceptEula><ProductKey><Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key><WillShowUI>Never</WillShowUI></ProductKey><FullName>Runner Image</FullName></UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><RunSynchronous><RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg.exe add HKLM\SYSTEM\CurrentControlSet\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand></RunSynchronous></component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><ComputerName>actions-image</ComputerName><TimeZone>UTC</TimeZone></component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale></component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE><HideEULAPage>true</HideEULAPage><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE>
      <UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Name>runner</Name><Group>Administrators</Group><Password><Value>BUILD_PASSWORD</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>
      <AutoLogon><Username>runner</Username><Enabled>true</Enabled><LogonCount>1</LogonCount><Password><Value>BUILD_PASSWORD</Value><PlainText>true</PlainText></Password></AutoLogon>
      <FirstLogonCommands><SynchronousCommand wcm:action="add"><Order>1</Order><Description>Provision disposable runner image</Description><CommandLine>powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$v=Get-Volume | Where-Object FileSystemLabel -eq 'IMAGE_BUILD'; &amp; ($v.DriveLetter + ':\provision.ps1')"</CommandLine><RequiresUserInput>false</RequiresUserInput></SynchronousCommand></FirstLogonCommands>
    </component>
  </settings>
</unattend>'''
    return template.replace('IMAGE_INDEX', str(image_index)).replace('BUILD_PASSWORD', password)


class Qmp:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(10)
        self.socket.connect(str(path))
        self.stream = self.socket.makefile('rwb')
        self.stream.readline()
        self.call('qmp_capabilities')

    def call(self, command, arguments=None):
        self.stream.write((json.dumps({'execute': command, 'arguments': arguments or {}}) + '\n').encode())
        self.stream.flush()
        while True:
            reply = json.loads(self.stream.readline())
            if 'error' in reply:
                raise RuntimeError(str(reply['error']))
            if 'return' in reply:
                return reply['return']

    def close(self):
        self.stream.close()
        self.socket.close()


def hardware_args():
    return ['-machine', 'q35,smm=on', '-cpu', 'host', '-global', 'driver=cfi.pflash01,property=secure,value=on']


def build(args):
    work = args.work_dir
    if work.exists():
        raise ValueError('Use a fresh workspace; existing Windows installations are never erased automatically')
    if args.destination.exists():
        raise ValueError('Image destination already exists')
    if any(c in str(p) for p in [work, args.iso, args.destination] for c in ',\n\r'):
        raise ValueError('Paths must not contain commas or newlines')
    if not args.iso.is_file() or args.iso.stat().st_size < 1024 ** 3:
        raise ValueError('Expected a Windows installation ISO')
    work.mkdir(parents=True, mode=0o700)
    with (work / '.lock').open('x') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if shutil.disk_usage(work).free < 100 * 1024 ** 3:
            raise ValueError('At least 100 GiB free is required for image preparation and publication')
        seed = work / 'seed'
        seed.mkdir(mode=0o700)
        manifest = package_manifest()
        print('Downloading and verifying pinned Windows bootstrap packages', flush=True)
        assets = download_packages(seed, manifest)
        # The selected source image must be Windows 11 Pro (the installation key
        # and local-account unattended profile are specific to that edition).
        print('Inspecting Windows installation images', flush=True)
        listing = run('7zz', 'l', '-slt', args.iso, capture_output=True, text=True).stdout
        wims = [line.removeprefix('Path = ') for line in listing.splitlines()
                if line.lower() in ('path = sources/install.wim', 'path = sources/install.esd')]
        if len(wims) != 1:
            raise ValueError('Expected one sources/install.wim or install.esd on the ISO')
        installation = work / 'installation'
        installation.mkdir(mode=0o700)
        run('7zz', 'x', '-y', f'-o{installation}', args.iso, wims[0], stdout=subprocess.DEVNULL)
        wim = installation / wims[0]
        xml = run('wimlib-imagex', 'info', wim, '--xml', capture_output=True).stdout
        root = ET.fromstring(xml.decode('utf-16') if xml.startswith(b'\xff\xfe') else xml)
        images = {image.findtext('NAME'): image.attrib['INDEX'] for image in root.findall('IMAGE')}
        if 'Windows 11 Pro' not in images:
            raise ValueError(f'Windows 11 Pro was not found; available images: {list(images)}')
        index = images['Windows 11 Pro']
        shutil.rmtree(installation)
        print(f'Installing Windows 11 Pro (image {index}) in a private {args.disk_gib} GiB disk', flush=True)
        (seed / 'Autounattend.xml').write_text(answer_file(index, secrets.token_urlsafe(32) + '!9aA'))
        for script in (HERE / 'guest').glob('*.ps1'):
            shutil.copyfile(script, seed / script.name)
        shutil.copyfile(HERE / 'packages.json', seed / 'packages.json')
        shutil.copyfile(Path(os.environ.get('ACTIONS_VM_SCALER_GUEST', str(HERE.parent / 'actions-vm-scaler/guest'))) / 'windows-bootstrap.ps1', seed / 'windows-bootstrap.ps1')
        token = secrets.token_urlsafe(32)
        receipt = {}

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                if self.path != '/' + token:
                    self.send_error(404)
                    return
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 4096 or receipt:
                    self.send_error(400)
                    return
                value = json.loads(self.rfile.read(size))
                if not isinstance(value.get('success'), bool) or not isinstance(value.get('stage'), str):
                    self.send_error(400)
                    return
                receipt.update(success=value['success'], stage=value['stage'][:80])
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{}')

            def log_message(self, *unused):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        (seed / 'build.json').write_text(json.dumps({'receipt_url': f'http://10.0.2.2:{server.server_port}/{token}'}))
        run('xorriso', '-as', 'mkisofs', '-quiet', '-J', '-r', '-V', 'IMAGE_BUILD', '-o', work / 'build.iso', seed)
        # Remove the host copy containing the one-time local account password.
        shutil.rmtree(seed)
        for kind in ['CODE', 'VARS']:
            shutil.copyfile(os.environ[f'WINDOWS_OVMF_{kind}'], work / f'OVMF_{kind}.fd')
        run('qemu-img', 'create', '-f', 'qcow2', work / 'disk.qcow2', f'{args.disk_gib}G')
        tpm_dir = work / 'tpm'
        tpm_dir.mkdir(mode=0o700)
        children = []
        try:
            with (work / 'swtpm.log').open('xb') as log:
                tpm = subprocess.Popen(['swtpm', 'socket', '--tpm2', '--tpmstate', f'dir={tpm_dir}', '--ctrl', f'type=unixio,path={work}/tpm.sock', '--flags', 'not-need-init', '--terminate'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log)
            children.append(tpm)
            for _ in range(100):
                if tpm.poll() is not None:
                    raise RuntimeError('TPM exited at startup')
                if (work / 'tpm.sock').exists():
                    break
                time.sleep(.1)
            else:
                raise RuntimeError('TPM startup timed out')
            command = ['qemu-system-x86_64', '-enable-kvm', '-nodefaults', '-no-user-config', '-m', str(args.memory_mib), '-smp', str(args.cpus)] + hardware_args() + [
                '-drive', f'if=pflash,format=raw,readonly=on,file={work}/OVMF_CODE.fd',
                '-drive', f'if=pflash,format=raw,file={work}/OVMF_VARS.fd',
                '-device', 'ich9-ahci,id=sata',
                '-drive', f'id=installer,if=none,format=raw,readonly=on,media=cdrom,file={args.iso}', '-device', 'ide-cd,bus=sata.1,drive=installer',
                '-drive', f'id=seed,if=none,format=raw,readonly=on,media=cdrom,file={work}/build.iso', '-device', 'ide-cd,bus=sata.3,drive=seed',
                '-drive', f'id=os,if=none,format=qcow2,file={work}/disk.qcow2', '-device', 'ide-hd,bus=sata.4,drive=os',
                '-boot', 'order=c,once=d', '-device', 'VGA', '-device', 'qemu-xhci', '-device', 'usb-tablet', '-device', 'usb-kbd',
                '-netdev', 'user,id=net0', '-device', 'e1000e,netdev=net0',
                '-chardev', f'socket,id=chrtpm,path={work}/tpm.sock', '-tpmdev', 'emulator,id=tpm0,chardev=chrtpm', '-device', 'tpm-tis,tpmdev=tpm0',
                '-qmp', f'unix:{work}/qmp.sock,server=on,wait=off', '-vnc', f'127.0.0.1:{args.vnc_display}', '-monitor', 'none', '-serial', 'none']
            with (work / 'qemu.log').open('xb') as log:
                vm = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log)
            children.append(vm)
            deadline = time.monotonic() + args.timeout
            for _ in range(200):
                if vm.poll() is not None:
                    raise RuntimeError('QEMU exited at startup; inspect qemu.log')
                if (work / 'qmp.sock').exists():
                    break
                time.sleep(.1)
            with contextlib.closing(Qmp(work / 'qmp.sock')) as qmp:
                # Only the initial installer boot receives keys. Reboots proceed
                # from the newly installed OS, without re-running disk erasure.
                for _ in range(12):
                    time.sleep(1)
                    qmp.call('send-key', {'keys': [{'type': 'qcode', 'data': 'ret'}]})
                last_status = 0
                while vm.poll() is None:
                    if time.monotonic() >= deadline:
                        qmp.call('screendump', {'filename': str(work / 'screen.ppm')})
                        raise RuntimeError('Installation timed out; inspect the saved console')
                    if time.monotonic() - last_status > 60:
                        try:
                            qmp.call('screendump', {'filename': str(work / 'screen.ppm')})
                        except (OSError, ValueError):
                            # QEMU can close QMP just before poll observes its
                            # normal shutdown. Still require its exit status and
                            # the final guest receipt below before publication.
                            vm.wait(timeout=10)
                            break
                        print('Waiting for Windows installation/provisioning' if not receipt else f"Guest receipt: {receipt}", flush=True)
                        last_status = time.monotonic()
                    time.sleep(2)
            if vm.returncode != 0 or receipt.get('success') is not True:
                raise RuntimeError(f'Guest preparation failed: {receipt or "no receipt"}')
            tpm.wait(timeout=30)
        finally:
            for child in reversed(children):
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait()
            server.shutdown()
            server.server_close()
        # Never publish credentials/install media, and never mutate an existing image.
        (work / 'build.iso').unlink()
        publish(args, assets, manifest)


def publish(args, assets, packages=None):
    work, destination = args.work_dir, args.destination
    run('qemu-img', 'check', work / 'disk.qcow2')
    destination.mkdir(parents=True, mode=0o755, exist_ok=False)
    try:
        run('qemu-img', 'convert', '-c', '-O', 'qcow2', work / 'disk.qcow2', destination / 'windows.qcow2')
        for name in ['OVMF_CODE.fd', 'OVMF_VARS.fd']:
            shutil.copyfile(work / name, destination / name)
        shutil.copytree(work / 'tpm', destination / 'tpm')
        vm = {'guest_os': 'windows', 'base_disk': str(destination / 'windows.qcow2'),
              'firmware_code': str(destination / 'OVMF_CODE.fd'), 'firmware_vars': str(destination / 'OVMF_VARS.fd'),
              'hardware_args': hardware_args(), 'memory_mib': args.memory_mib, 'cpus': args.cpus,
              'tpm': {'state_template': str(destination / 'tpm')}}
        (destination / 'vm.json').write_text(json.dumps(vm, indent=2) + '\n')
        (destination / 'packages.json').write_text(json.dumps(packages or package_manifest(), indent=2) + '\n')
        manifest = {'source_iso_sha256': digest(args.iso), 'assets': assets,
                    'files': {str(p.relative_to(destination)): digest(p) for p in sorted(destination.rglob('*')) if p.is_file()}}
        (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        for path in destination.rglob('*'):
            path.chmod(0o555 if path.is_dir() else 0o444)
        destination.chmod(0o555)
    except BaseException:
        # Leave failed output for inspection, but without a runnable config.
        (destination / 'vm.json').unlink(missing_ok=True)
        raise
    print(f'Published sealed Windows image: {destination}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=lambda s: Path(s).absolute(), required=True)
    parser.add_argument('--iso', type=lambda s: Path(s).absolute(), required=True)
    parser.add_argument('--destination', type=lambda s: Path(s).absolute(), required=True)
    parser.add_argument('--disk-gib', type=int, default=128)
    parser.add_argument('--memory-mib', type=int, default=8192)
    parser.add_argument('--cpus', type=int, default=4)
    parser.add_argument('--timeout', type=int, default=14400)
    parser.add_argument('--vnc-display', type=int, default=10, help='Loopback VNC display (port 5900 + display)')
    args = parser.parse_args()
    if args.disk_gib < 64 or args.memory_mib < 4096 or args.cpus < 2 or args.timeout < 300 or not 1 <= args.vnc_display <= 99:
        parser.error('Windows 11 requires >=64 GiB disk, >=4096 MiB RAM, >=2 CPUs, and a valid timeout/VNC display')
    os.umask(0o077)
    def interrupted(*unused):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        build(args)
    except (ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
