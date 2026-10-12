#!/usr/bin/env python3
"""Keep machine identities in local state and personalize initrds before signing."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location('hardware', Path(__file__).with_name('hardware-identities.py'))
hardware = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hardware)


def alias(host, path):
    return host + '-' + '-'.join(p.replace('/', '_').replace('.', '_') for p in path)


def leaves(value, path=()):
    if isinstance(value, dict):
        for name, item in value.items():
            yield from leaves(item, path + (name,))
    else:
        yield path, value


def get(value, path):
    for key in path:
        value = value[key]
    return value


def inventory(manifest, state):
    directory = state / 'input'
    meta = json.loads((directory / 'metadata.json').read_text())
    values = json.loads((directory / hardware.INVENTORY).read_text())
    schema = json.loads(Path(manifest['schema']).read_text())
    hardware.validate_inventory(values, schema)
    fixtures = json.loads(Path(manifest['fixtures']).read_text())
    if meta != {'version': 1, 'fixture': False} or values == fixtures:
        if not manifest.get('allowFixtures', False) or meta != {'version': 1, 'fixture': True} or values != fixtures:
            raise ValueError('Provision production hardware state before installing or activating this system')
    return values, fixtures, schema


def substitute(text, values, fixtures):
    replacements = {str(marker): get(values, path) for path, marker in leaves(fixtures)}
    # A null pin is explicitly attended installation: never attempt TPM unlock.
    for marker, replacement in replacements.items():
        if replacement is not None:
            continue
        lines = []
        for line in text.splitlines(keepends=True):
            if 'fixate-volume-key=' + marker in line:
                fields = line.split()
                fields[-1] = ','.join(o for o in fields[-1].split(',') if o not in (
                    'fixate-volume-key=' + marker, 'tpm2-device=auto', 'token-timeout=10s'))
                line = '\t'.join(fields) + '\n'
            lines.append(line)
        text = ''.join(lines)
    # One pass: a real value may happen to equal another field's fixture.
    pattern = '|'.join(re.escape(k) for k in sorted(replacements, key=len, reverse=True))
    return re.sub(pattern, lambda m: str(replacements[m[0]]) if replacements[m[0]] is not None else m[0], text)


def source_files(source, target):
    source = Path(source)
    if source.is_dir():
        for child in sorted(source.iterdir()):
            yield from source_files(child, target + '/' + child.name)
    else:
        yield target, source.read_bytes()


def files(manifest, values, fixtures, schema, initrd=False):
    host = manifest['host']
    result = {}
    mappings = {}
    for path, kind in leaves(schema[host]):
        if kind == 'uuid':
            uuid = get(values[host], path)
            mappings.setdefault(uuid, []).append('disk/by-hardware/' + alias(host, path))
    for uuid, links in mappings.items():
        result['etc/nixos-hardware/devices/' + uuid] = ('HARDWARE_LINKS=' + ' '.join(links) + '\n').encode()
    result['etc/nixos-hardware/devices/.ready'] = b'1\n'
    storage = values[host].get('storage', {})
    if 'zfs' in storage:
        result['etc/hostid'] = int(storage['zfs']['hostId'], 16).to_bytes(4, manifest['byteOrder'])
    if manifest.get('mapper'):
        result['root-volume-key-id.json'] = (json.dumps(storage['luks'][manifest['mapper']]['volumeKeyId']) + '\n').encode()
    templates = manifest['initrdTemplates' if initrd else 'templates']
    for target, source in templates.items():
        for name, data in source_files(source, target):
            result[name] = substitute(data.decode(), values, fixtures).encode()
    if initrd:
        for target, source in manifest.get('secrets', {}).items():
            for name, data in source_files(source, '.initrd-secrets/' + target.lstrip('/')):
                result[name] = data
    for name in result:
        if name.startswith('/') or '..' in Path(name).parts or '\n' in name:
            raise ValueError('Unsafe hardware output path')
    return result


def render(manifest, state):
    values, fixtures, schema = inventory(manifest, state)
    outputs = files(manifest, values, fixtures, schema)
    generations = state / 'generations'
    generations.mkdir(mode=0o755, exist_ok=True)
    generations.chmod(0o755)
    digest = hashlib.sha256()
    for name, data in sorted(outputs.items()):
        digest.update(name.encode() + b'\0' + data + b'\0')
    generation = generations / digest.hexdigest()
    if not generation.exists():
        with tempfile.TemporaryDirectory(prefix='.render-', dir=generations) as temporary:
            stage = Path(temporary) / 'generation'
            stage.mkdir(mode=0o700)
            for name, data in outputs.items():
                path = stage / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                path.chmod(0o644)
            for directory in [stage, *[p for p in stage.rglob("*") if p.is_dir()]]:
                directory.chmod(0o755)
            stage.rename(generation)
    link = state / '.current-new'
    link.unlink(missing_ok=True)
    link.symlink_to(generation.relative_to(state))
    os.replace(link, state / 'current')
    return values, schema


def device_links(manifest, values, schema, device_root):
    host = manifest['host']
    directory = device_root / 'disk/by-hardware'
    directory.mkdir(parents=True, exist_ok=True)
    for path, kind in leaves(schema[host]):
        if kind != 'uuid':
            continue
        link = directory / alias(host, path)
        target = '../by-uuid/' + get(values[host], path)
        if link.exists() and not link.is_symlink():
            raise ValueError('Refusing to replace a non-symlink device path')
        pending = link.with_name(link.name + '.new')
        pending.unlink(missing_ok=True)
        pending.symlink_to(target)
        os.replace(pending, link)


def provision(manifest, state, repo, source=None, fixtures=False, device_root=Path('/dev')):
    state.mkdir(parents=True, mode=0o700, exist_ok=True)
    if state.is_symlink() or state.stat().st_uid != os.getuid() or state.stat().st_mode & 0o022:
        raise ValueError('Hardware state must be owned and not group/world writable')
    state.chmod(0o755)
    with tempfile.TemporaryDirectory(prefix='.provision-', dir=state) as temporary:
        stage = Path(temporary)
        hardware.provision(repo, stage / 'input', source, fixtures)
        values, schema = render(manifest, stage)
        by_id = values[manifest['host']].get('storage', {}).get('installationDisk', {}).get('byId')
        link = state / 'installation-disk'
        if by_id and link.exists() and not link.is_symlink():
            raise ValueError('Refusing to replace a non-symlink installation selector')
        old_input = state / 'input'
        backup = stage / 'previous-input'
        old_current = os.readlink(state / 'current') if (state / 'current').is_symlink() else None
        if old_input.exists():
            old_input.rename(backup)
        try:
            (stage / 'input').rename(old_input)
            render(manifest, state)
            device_links(manifest, values, schema, device_root)
            if by_id:
                pending = state / '.installation-disk-new'
                pending.unlink(missing_ok=True)
                pending.symlink_to('/dev/disk/by-id/' + by_id)
                os.replace(pending, link)
        except Exception:
            shutil.rmtree(old_input)
            if backup.exists():
                backup.rename(old_input)
            (state / 'current').unlink(missing_ok=True)
            if old_current is not None:
                (state / 'current').symlink_to(old_current)
            raise


def cpio(outputs):
    """A deterministic newc overlay, unpacked before PID 1 and its generators."""
    directories = set()
    for name in outputs:
        directories.update(str(p) for p in Path(name).parents if str(p) != '.')
    entries = [(n, b'', 0o40755) for n in sorted(directories, key=lambda p: (p.count('/'), p))]
    entries += [(n, data, 0o100600 if n.startswith('.initrd-secrets/') else 0o100644) for n, data in sorted(outputs.items())]
    entries.append(('TRAILER!!!', b'', 0))
    data = bytearray()
    for ino, (name, content, mode) in enumerate(entries, 1):
        encoded = name.encode() + b'\0'
        fields = [ino, mode, 0, 0, 1, 0, len(content), 0, 0, 0, 0, len(encoded), 0]
        header = b'070701' + ''.join(f'{v:08x}' for v in fields).encode()
        data.extend(header + encoded)
        data.extend(b'\0' * (-len(data) % 4))
        data.extend(content)
        data.extend(b'\0' * (-len(data) % 4))
    return bytes(data)


def append(manifest, state, initrd):
    values, fixtures, schema = inventory(manifest, state)
    overlay = cpio(files(manifest, values, fixtures, schema, initrd=True))
    # Validate and generate the whole overlay before opening the installer's copy.
    with Path(initrd).open('ab') as output:
        # Linux recognizes an uncompressed newc archive only at a four-byte
        # boundary, including after an arbitrarily sized compressed archive.
        output.write(b'\0' * (-output.tell() % 4))
        output.write(overlay)
        output.flush()
        os.fsync(output.fileno())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('action', choices=['provision', 'verify', 'render', 'append'])
    parser.add_argument('initrd', type=Path, nargs='?')
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--inventory', type=Path)
    parser.add_argument('--root', type=Path, default=Path('/'))
    parser.add_argument('--fixtures', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        manifest = json.loads(args.manifest.read_text())
        state = args.root / manifest['stateDirectory'].lstrip('/')
        if args.action == 'provision':
            provision(manifest, state, args.repo, args.inventory, args.fixtures)
        elif args.action == 'verify':
            inventory(manifest, state)
        elif args.action == 'render':
            values, schema = render(manifest, state)
            device_links(manifest, values, schema, Path('/dev'))
        elif args.action == 'append' and args.initrd:
            append(manifest, state, args.initrd)
        else:
            parser.error('append requires an initrd file')
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.CalledProcessError):
        print('Hardware state unavailable or invalid. Provision this host with sys hardware-provision before installation or activation. Details withheld to keep identifiers out of logs.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
