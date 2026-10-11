#!/usr/bin/env python3
"""Transparent local-flake preparation for the managed Nix executable."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location('hardware', Path(__file__).with_name('hardware-identities.py'))
hardware = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hardware)


def repository(path):
    path = Path(path).resolve()
    if path.is_file():
        path = path.parent
    for candidate in (path, *path.parents):
        if (candidate / 'lib/hardware-identities-schema.json').is_file() and (candidate / 'flake.nix').is_file():
            return candidate
    return None


def local_path(argument, cwd):
    ref = argument.split('#', 1)[0]
    if ref.startswith('path:'):
        ref = ref[5:]
    if ref.startswith(('.', '/')):
        return (cwd / ref).resolve()
    return None


def rewrite(arguments, cwd, repo, source):
    """Rewrite only local flake references and --file; retain the caller's cwd."""
    result = []
    after_separator = False
    file_next = False
    for argument in arguments:
        if after_separator:
            result.append(argument)
            continue
        if argument in ('--', '-c', '--command'):
            after_separator = True
        if file_next:
            path = (cwd / argument).resolve()
            result.append(str(source / path.relative_to(repo)) if path.is_relative_to(repo) else argument)
            file_next = False
            continue
        if argument in ('-f', '--file'):
            file_next = True
        path = local_path(argument, cwd)
        if path == repo:
            suffix = '#' + argument.split('#', 1)[1] if '#' in argument else ''
            argument = 'path:' + str(source) + suffix
        result.append(argument)
    return result


def cached_inventory(repo):
    """Cache decryption by encrypted content, never by a mutable filename alone."""
    digest = hashlib.sha256()
    for path in [repo / 'lib/hardware-identities-schema.json', *sorted((repo / 'secrets/hardware').glob('*.json'))]:
        digest.update(path.name.encode() + b'\0' + path.read_bytes())
    base = Path(os.environ.get('XDG_CACHE_HOME', str(Path.home() / '.cache'))) / 'nixos-hardware'
    if base.resolve().is_relative_to(repo.resolve()):
        raise ValueError('The decrypted hardware cache must be outside the repository')
    base.mkdir(mode=0o700, parents=True, exist_ok=True)
    if base.is_symlink() or base.stat().st_uid != os.getuid() or base.stat().st_mode & 0o077:
        raise ValueError('Hardware cache must be owned by this user with mode 0700')
    target = base / (digest.hexdigest() + '.json')
    with (base / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not target.exists():
            data = hardware.read_inventory(repo)
            with tempfile.NamedTemporaryFile(mode='w', dir=base, delete=False) as output:
                json.dump(data, output)
                temporary = Path(output.name)
            temporary.replace(target)
    return target


# Flags whose values are not installables. Unknown flags still reach Nix unchanged.
FLAG_ARGUMENTS = {
    '--option': 2, '--arg': 2, '--argstr': 2, '--override-input': 2, '--override-flake': 2,
    '--out-link': 1, '-o': 1, '--max-jobs': 1, '-j': 1, '--cores': 1,
    '--builders': 1, '--system': 1, '--store': 1, '--eval-store': 1,
    '--log-format': 1, '--apply': 1, '--file': 1, '-f': 1,
    '--expr': 1, '-E': 1, '--inputs-from': 1, '--profile': 1,
    '--redirect': 2, '--reference-lock-file': 1, '--output-lock-file': 1,
}


def installables(arguments, command):
    tokens = arguments[arguments.index(command) + 1:]
    if command == 'flake':
        tokens = tokens[1:]
    result = []
    i = 0
    while i < len(tokens):
        value = tokens[i]
        if value in ('--', '-c', '--command'):
            break
        if value.startswith('-'):
            i += 1 + FLAG_ARGUMENTS.get(value, 0)
        else:
            result.append(value)
            i += 1
    return result


def main(real_nix, arguments):
    cwd = Path.cwd()
    # Commands that edit the checkout or do not evaluate a configuration pass through.
    commands = {'build', 'eval', 'develop', 'run', 'shell', 'flake'}
    command = None
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument.startswith('-'):
            index += 1 + FLAG_ARGUMENTS.get(argument, 0)
            continue
        command = argument if argument in commands else None
        break
    if command is None or command == 'flake' and not any(a in arguments for a in ('check', 'show', 'archive')):
        return subprocess.call([real_nix, *arguments])
    boundary = next((i for i, a in enumerate(arguments) if a in ('--', '-c', '--command')), len(arguments))
    if '--help' in arguments[:boundary]:
        return subprocess.call([real_nix, *arguments])
    refs = [local_path(a, cwd) for a in installables(arguments, command)]
    for index, argument in enumerate(arguments[:boundary]):
        if argument in ('-f', '--file') and index + 1 < boundary:
            refs.append((cwd / arguments[index + 1]).resolve())
    repos = {repository(p) for p in refs if p is not None}
    repos.discard(None)
    if len(repos) > 1:
        raise ValueError('Build each hardware repository separately')
    repo = next(iter(repos), repository(cwd))
    if repo is None or (repo / hardware.MANIFEST).exists():
        return subprocess.call([real_nix, *arguments])
    # Explicit references to unrelated flakes need no production inventory.
    has_local = any(p == repo for p in refs)
    has_file = any(a in arguments[:boundary] for a in ('-f', '--file'))
    if not has_local and not has_file:
        if installables(arguments, command) or any(a in arguments for a in ('--expr', '-E')):
            return subprocess.call([real_nix, *arguments])
        insert = next((i for i, a in enumerate(arguments) if a in ('--', '-c', '--command')), len(arguments))
        arguments = [*arguments[:insert], 'path:' + str(repo), *arguments[insert:]]
    with tempfile.TemporaryDirectory(prefix='nixos-hardware-') as temporary:
        source = hardware.prepare(repo, Path(temporary) / 'source', cached_inventory(repo))
        return subprocess.call([real_nix, *rewrite(arguments, cwd, repo, source)])


if __name__ == '__main__':
    os.umask(0o077)
    try:
        sys.exit(main(sys.argv[1], sys.argv[2:]))
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Hardware preparation stopped: {error}', file=sys.stderr)
        sys.exit(1)
