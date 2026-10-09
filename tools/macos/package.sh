#!/usr/bin/env bash
# Build-host packaging only. End users do not run this script.
set -euo pipefail
if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
    echo 'A real Apple Silicon Mac build host is required.' >&2
    exit 1
fi
repo=$(cd "$(dirname "$0")/../.." && pwd)
build=${1:?Usage: package.sh BUILD_DIRECTORY OUTPUT_DIRECTORY MACDEPLOYQT}
out=${2:?Missing output directory}
deploy=${3:?Missing full macdeployqt path}
mkdir -p "$out"
out=$(cd "$out" && pwd)
stage=$(mktemp -d)
pending="$out/.suyu-macos-arm64.pending.zip"
trap 'rm -rf "$stage"; rm -f "$pending"' EXIT
APP="$stage/suyu.app"
ditto "$build/bin/suyu.app" "$APP"
cp "$build/bin/suyu-cmd" "$APP/Contents/MacOS/"
# Homebrew splits Qt modules across formulae; qtbase's own rpaths do not
# locate QtSvg, QtPdf and QtVirtualKeyboard when deploying their plugins.
brew_prefix=$(brew --prefix)
qt_prefix=$(brew --prefix qt)
deploy_args=(-executable="$APP/Contents/MacOS/suyu-cmd" -always-overwrite
             -no-codesign -verbose=2
             -libpath="$qt_prefix/lib" -libpath="$brew_prefix/lib")
for qt_lib in "$brew_prefix"/opt/qt*/lib; do
    [[ -d "$qt_lib" && "$qt_lib" != "$brew_prefix/opt/qt@5/lib" ]] || continue
    deploy_args+=(-libpath="$qt_lib")
done
"$deploy" "$APP" "${deploy_args[@]}"
# Keep SVG image/icon support for suyu's themes. Exclude unused PDF/input plugins.
rm -f "$APP/Contents/PlugIns/imageformats/libqpdf.dylib" \
      "$APP/Contents/PlugIns/platforminputcontexts/libqtvirtualkeyboardplugin.dylib"
python3 - "$repo" "$APP" <<'PY'
import plistlib
import re
import subprocess
import sys
from pathlib import Path
repo, app = map(Path, sys.argv[1:])
sys.path.insert(0, str(repo / 'tools/macos'))
from verify_bundle import parse_rpaths, run
for name in ('suyu', 'suyu-cmd'):
    exe = app / 'Contents/MacOS' / name
    rpaths = parse_rpaths(run('/usr/bin/otool', '-arch', 'arm64', '-l', str(exe)))
    for path in rpaths:
        if path.startswith(('/opt/homebrew/', '/usr/local/')):
            subprocess.run(['/usr/bin/install_name_tool', '-delete_rpath', path, str(exe)], check=True)
    bundled = '@executable_path/../Frameworks'
    if bundled not in rpaths:
        subprocess.run(['/usr/bin/install_name_tool', '-add_rpath', bundled, str(exe)], check=True)
for image in (app / 'Contents/Frameworks').glob('*.dylib'):
    identity = run('/usr/bin/otool', '-arch', 'arm64', '-D', str(image)).splitlines()[1:]
    if identity and identity[0].strip().startswith(('/opt/homebrew/', '/usr/local/')):
        subprocess.run(['/usr/bin/install_name_tool', '-id',
                        '@rpath/' + image.name, str(image)], check=True)
# Fill Finder's otherwise blank version metadata from the checkout's declared version.
version = re.search(r'Current version:\s+\*\*v(\d+\.\d+\.\d+)\*\*',
                    (repo / 'README.md').read_text())
if not version:
    raise SystemExit('Cannot determine bundle version from README.md')
plist = app / 'Contents/Info.plist'
with plist.open('rb') as stream:
    info = plistlib.load(stream)
info.update(CFBundleShortVersionString=version[1], CFBundleVersion=version[1],
            LSMinimumSystemVersion='15.0', NSHighResolutionCapable=True)
info.pop('LSRequiresCarbon', None)
with plist.open('wb') as stream:
    plistlib.dump(info, stream)
PY
codesign --force --deep --sign - "$APP"
if ! python3 "$repo/tools/macos/verify_bundle.py" "$APP" --report "$out/bundle-audit.json"; then
    echo 'Bundle verification failed; details follow:' >&2
    python3 -m json.tool "$out/bundle-audit.json" >&2
    exit 1
fi
if ! python3 "$repo/tools/macos/verify_startup.py" "$APP" --evidence "$out/startup-evidence"; then
    echo 'Startup verification failed; details follow:' >&2
    python3 -m json.tool "$out/startup-evidence/startup-report.json" >&2
    exit 1
fi
# No application ZIP is emitted if the audit or startup check fails.
python3 "$repo/tools/package_policy/third_party_notices.py" --package-dir "$stage"
cp "$repo/docs/macos-first-run.md" "$stage/FIRST-RUN.md"
ditto -c -k --sequesterRsrc "$stage" "$pending"
python3 "$repo/tools/package_policy/scan_release.py" --kind macos "$pending"
mv "$pending" "$out/suyu-macos-arm64.zip"
python3 - "$repo" "$out" <<'PY'
import hashlib
import json
import platform
import subprocess
import sys
from pathlib import Path
repo, out = map(Path, sys.argv[1:])
archive = out / 'suyu-macos-arm64.zip'
record = {'source_commit': subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip(),
          'source_modified': bool(subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain'], text=True).strip()),
          'host': platform.platform(), 'architecture': platform.machine(),
          'compiler': subprocess.check_output(['/usr/bin/xcrun', 'clang', '--version'], text=True).strip(),
          'sdk_version': subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip(),
          'archive': archive.name, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
          'signing': 'ad hoc', 'notarized': False, 'games_included': False,
          'target_mac_tested': False}
(out / 'build-record.json').write_text(json.dumps(record, indent=2) + '\n')
(out / 'SHA256SUMS.txt').write_text(record['sha256'] + '  ' + archive.name + '\n')
PY
