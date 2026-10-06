#!/usr/bin/env python3
"""Apply Adobe's live, checksummed patch registry to the public Magento source tree."""
import argparse
import calendar
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile

REGISTRY_URL = 'https://repo.magento.com/patch/patch-registry.json'
PATCH_BASE = 'https://repo.magento.com/patch/'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def download(url):
    # curl is already in the image; verify TLS, refuse HTTP redirects, fail on HTTP errors.
    return subprocess.check_output(['curl', '--fail', '--silent', '--show-error', '--location',
                                    '--proto', '=https', '--proto-redir', '=https',
                                    '--retry', '3', '--connect-timeout', '20', '--max-time', '180', url])


def select_patches(registry, components, target='latest'):
    if registry.get('_schema', {}).get('version') != '1.0':
        raise ValueError('Unsupported Adobe registry schema; refusing to guess.')
    cutoff = None
    if target != 'latest':
        parsed = datetime.strptime(target, '%Y-%b')
        cutoff = f'{parsed.year:04d}-{parsed.month:02d}-{calendar.monthrange(parsed.year, parsed.month)[1]}'
    all_patches = registry['patches']
    selected = {key: value for key, value in all_patches.items()
                if components.get(value['area']) in value['applies_to']
                and (cutoff is None or value['released'] <= cutoff)}
    if not selected:
        raise ValueError(f'No applicable patches for {components}; cannot assert a security level.')
    # Do not silently stay on an old baseline if new patches require a newer -p release.
    base = components['CE']
    release_line = re.match(r'^\d+\.\d+\.\d+', base).group()
    same_line = [value for value in all_patches.values()
                 if value['area'] == 'CE'
                 and any(v == release_line or v.startswith(release_line + '-p') for v in value['applies_to'])
                 and (cutoff is None or value['released'] <= cutoff)]
    selected_ce = [value for value in selected.values() if value['area'] == 'CE']
    if same_line and (not selected_ce or max(p['released'] for p in same_line) > max(p['released'] for p in selected_ce)):
        raise ValueError(f'Newer patches on {release_line} require a different base than {base}; update the pinned source first.')
    ordered, visiting, visited = [], set(), set()

    def visit(key):
        if key in visited:
            return
        if key in visiting:
            raise ValueError(f'Cyclic patch dependency: {key}')
        if key not in selected:
            raise ValueError(f'Required patch {key} is absent or not applicable; refusing partial patching.')
        visiting.add(key)
        for prerequisite in selected[key].get('requires', []):
            visit(prerequisite)
        visiting.remove(key)
        visited.add(key)
        ordered.append((key, selected[key]))

    for key in sorted(selected, key=lambda key: (selected[key]['released'], key)):
        visit(key)
    months = [match.groups() for key in selected
              if (match := re.search(r'-(\d{4})-(\d{2})-\d+-', key))]
    if not months:
        raise ValueError('Registry contains no identifiable monthly security release.')
    year, month = max(months)
    level = f'{year}-{calendar.month_abbr[int(month)].lower()}'
    if target != 'latest' and level != target.lower():
        raise ValueError(f'Requested {target} but registry only resolves {level}.')
    return ordered, level


def package_map(root):
    mapping = {'magento/magento2-base': '.'}
    for prefix in ['app/code', 'lib/internal', 'app/design', 'app/i18n']:
        for manifest in sorted((root / prefix).rglob('composer.json'), key=lambda p: len(p.parts)):
            data = json.loads(manifest.read_text(encoding='utf-8'))
            name = data.get('name')
            if name:
                mapping.setdefault(name, manifest.parent.relative_to(root).as_posix())
    return mapping


def map_path(path, mapping):
    if path == '/dev/null':
        return path
    if not path.startswith(('a/', 'b/')):
        raise ValueError(f'Unexpected diff path: {path}')
    prefix, relative = path[:2], path[2:]
    if '\\' in relative or any(part in ('..', '.') for part in relative.split('/')):
        raise ValueError(f'Unsafe diff path: {path}')
    if relative.startswith('vendor/') and not relative.startswith('vendor/bin/'):
        parts = relative.split('/', 3)
        if len(parts) != 4:
            raise ValueError(f'Unsupported package path: {path}')
        package = '/'.join(parts[1:3])
        if package in mapping:
            directory = mapping[package]
            relative = (directory + '/' if directory != '.' else '') + parts[3]
        elif package.startswith('magento/'):
            raise ValueError(f'Patch targets an absent Magento package: {package}')
    if PurePosixPath(relative).is_absolute() or not relative:
        raise ValueError(f'Unsafe mapped path: {path}')
    return prefix + relative


def adapt_diff(raw, mapping):
    # Only diff metadata paths change. Hunk contents (including PHP strings) remain untouched.
    output, files = [], set()
    for line in raw.decode('utf-8').splitlines(keepends=True):
        if line.startswith('diff --git '):
            match = re.fullmatch(r'diff --git (\S+) (\S+)\n?', line)
            if not match:
                raise ValueError('Unsupported diff header')
            line = 'diff --git ' + ' '.join(map_path(p, mapping) for p in match.groups()) + '\n'
        elif line.startswith(('--- ', '+++ ')):
            match = re.fullmatch(r'(--- |\+\+\+ )(\S+)([^\n]*)\n?', line)
            if not match:
                raise ValueError('Unsupported file header')
            prefix, path, suffix = match.groups()
            mapped = map_path(path, mapping)
            if mapped != '/dev/null':
                files.add(mapped[2:])
            line = prefix + mapped + suffix + '\n'
        elif line.startswith(('rename from ', 'rename to ', 'GIT binary patch')):
            raise ValueError('Rename/binary patch requires explicit implementation; refusing to skip it.')
        output.append(line)
    if not files:
        raise ValueError('Patch contains no file changes')
    return ''.join(output).encode('utf-8'), files


def run_patch(root, patch, reverse=False, dry_run=False):
    args = ['patch', '--batch', '--fuzz=0', '--no-backup-if-mismatch', '-p1', '-d', str(root), '-i', str(patch)]
    args += ['--reverse'] if reverse else ['--forward']
    if dry_run:
        args.append('--dry-run')
    subprocess.run(args, check=True)


def file_hash(root, name):
    file = root / name
    return digest(file.read_bytes()) if file.is_file() else None


def apply(root, output, target):
    output.mkdir(parents=True, exist_ok=True)
    version = json.loads((root / 'composer.json').read_text())['version']
    lock = json.loads((root / 'composer.lock').read_text())
    packages = {p['name']: p['version'].lstrip('v') for p in lock['packages']}
    raw_registry = download(REGISTRY_URL)
    registry = json.loads(raw_registry)
    components = {'CE': version}
    for area, definition in registry['_areas'].items():
        package = definition.get('composer_package')
        if package in packages:
            components[area] = packages[package]
    ordered, level = select_patches(registry, components, target)
    mapping = package_map(root)
    patches, affected, before = [], set(), {}
    (output / 'registry.json').write_bytes(raw_registry)
    for key, entry in ordered:
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*\.(diff|patch)', entry['file_name']):
            raise ValueError(f'Unsupported patch filename: {entry["file_name"]}')
        if entry.get('entitlements'):
            raise ValueError(f'{key} requires credentials; not a public Open Source artifact.')
        original = download(PATCH_BASE + entry['file_name'])
        if digest(original) != entry['sha256'].lower():
            raise ValueError(f'Adobe checksum mismatch for {key}')
        mapped, files = adapt_diff(original, mapping)
        # No patch may follow a symlink outside the checked-out application.
        for name in files:
            (root / name).resolve().relative_to(root.resolve())
            if name not in before:
                before[name] = file_hash(root, name)
        affected.update(files)
        original_path = output / entry['file_name']
        original_path.write_bytes(original)
        mapped_path = output / (entry['file_name'] + '.source.patch')
        mapped_path.write_bytes(mapped)
        print(f'Applying {key}', flush=True)
        run_patch(root, mapped_path, dry_run=True)
        run_patch(root, mapped_path)
        patches.append({'id': key, 'url': PATCH_BASE + entry['file_name'],
                        'sha256': digest(original), 'mapped_sha256': digest(mapped),
                        'mapped_file': mapped_path.name, 'cves': entry.get('cves', []),
                        'released': entry['released']})
    # Validate the whole chain in a scratch tree. Later monthly patches overlap earlier ones,
    # so reverse-checking each older patch against the final tree alone would be incorrect.
    with tempfile.TemporaryDirectory(prefix='magento-patch-verify-') as directory:
        scratch = Path(directory)
        for name in affected:
            if (root / name).is_file():
                destination = scratch / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(root / name, destination)
        for entry in reversed(patches):
            run_patch(scratch, output / entry['mapped_file'], reverse=True, dry_run=True)
            run_patch(scratch, output / entry['mapped_file'], reverse=True)
        for name, expected in before.items():
            if file_hash(scratch, name) != expected:
                raise ValueError(f'Reverse-chain verification failed: {name}')
    receipt = {'security_level': f'{version}-{level}', 'base_version': version,
               'registry_url': REGISTRY_URL, 'registry_sha256': digest(raw_registry),
               'fetched_at': datetime.now(timezone.utc).isoformat(), 'components': components,
               'verification': 'checksums + zero-fuzz application + full reverse-chain round trip',
               'patches': patches, 'files': {name: file_hash(root, name) for name in sorted(affected)}}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(f'VERIFIED SECURITY LEVEL: {receipt["security_level"]}', flush=True)


def status(root, output):
    receipt = json.loads((output / 'receipt.json').read_text())
    for name, expected in receipt['files'].items():
        if file_hash(root, name) != expected:
            raise ValueError(f'Patched file changed since build: {name}')
    print(f'Security level: {receipt["security_level"]}')
    print(f'Adobe registry fetched: {receipt["fetched_at"]}')
    print(f'Verification: {receipt["verification"]}')
    for entry in receipt['patches']:
        print(f'  APPLIED {entry["id"]} ({", ".join(entry["cves"])})')
    print('All patched-file hashes match the build receipt.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['apply', 'status'])
    parser.add_argument('--root', type=Path, default=Path('/var/www/html'))
    parser.add_argument('--output', type=Path, default=Path('/opt/magento/security'))
    parser.add_argument('--target', default='latest')
    args = parser.parse_args()
    if args.command == 'apply':
        apply(args.root.resolve(), args.output.resolve(), args.target)
    else:
        status(args.root.resolve(), args.output.resolve())
