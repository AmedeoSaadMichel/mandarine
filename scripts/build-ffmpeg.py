#!/usr/bin/env python3
"""Build pinned, standalone FFmpeg/ffprobe for macOS 13 (arm64 + x86_64).
Requires Xcode command-line tools, Python 3, CMake and pkg-config.
All codec libraries are built from the matching sources; no Homebrew dylibs ship.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import os, subprocess, json, hashlib, urllib.request, shutil
ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / 'build/ffmpeg'
VENDOR = ROOT / 'vendor/ffmpeg'
SOURCES = VENDOR / 'sources'
OUT = VENDOR / 'universal'
MANIFEST = json.loads((VENDOR / 'sources.json').read_text())
JOBS = max(2, min(5, (os.cpu_count() or 4) // 2))

def log(s): print(s, flush=True)
def run(args, cwd, env, name):
    dest = cwd / (name + '.log')
    with dest.open('w') as f:
        result = subprocess.run([str(a) for a in args], cwd=cwd, env=env, stdout=f, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'{cwd}: {name} failed:\n' + dest.read_text()[-6000:])

def unpack(name, dest):
    if not dest.exists():
        dest.mkdir(parents=True)
        subprocess.run(['tar', '-xf', str(SOURCES / name), '--strip-components=1', '-C', str(dest)], check=True)
    return dest

SOURCES.mkdir(parents=True, exist_ok=True)
for item in MANIFEST:
    path = SOURCES / item['name']
    if not path.exists():
        log('Downloading ' + item['name'])
        urllib.request.urlretrieve(item['url'], path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']:
        raise RuntimeError('Checksum mismatch: ' + item['name'])
BASE.mkdir(parents=True, exist_ok=True)
env0 = os.environ.copy()
nasm = BASE / 'host/bin/nasm'
if not nasm.exists():
    src = unpack('nasm-2.16.03.tar.xz', BASE / 'nasm')
    log('Building host assembler')
    run(['./configure', '--prefix=' + str(BASE / 'host')], src, env0, 'configure')
    run(['make', '-j' + str(JOBS), 'install'], src, env0, 'make')
env0['PATH'] = str(nasm.parent) + ':' + env0['PATH']

def build(arch):
    base = BASE / arch
    prefix = base / 'prefix'
    base.mkdir(exist_ok=True)
    prefix.mkdir(exist_ok=True)
    env = env0.copy()
    flags = f'-O2 -arch {arch} -mmacosx-version-min=13.0'
    env.update(CC='clang', CXX='clang++', CFLAGS=flags, CXXFLAGS=flags, LDFLAGS=f'-arch {arch} -mmacosx-version-min=13.0',
               MACOSX_DEPLOYMENT_TARGET='13.0', PKG_CONFIG_PATH=str(prefix / 'lib/pkgconfig'), PKG_CONFIG_LIBDIR=str(prefix / 'lib/pkgconfig'))
    host = ('aarch64' if arch == 'arm64' else 'x86_64') + '-apple-darwin'
    def autotools(archive, name, options, marker):
        if (prefix / marker).exists(): return
        log(arch + ': building ' + name)
        src = unpack(archive, base / name)
        run(['./configure', '--prefix=' + str(prefix)] + options, src, env, 'configure')
        run(['make', '-j' + str(JOBS)], src, env, 'make')
        run(['make', 'install'], src, env, 'install')
    autotools('x264-b35605a.tar.gz', 'x264', ['--host=' + host, '--enable-static', '--enable-pic', '--disable-cli', '--disable-opencl'], 'lib/libx264.a')
    autotools('lame-3.100.tar.gz', 'lame', ['--host=' + host, '--disable-shared', '--enable-static', '--disable-frontend', '--disable-decoder', '--disable-dependency-tracking'], 'lib/libmp3lame.a')
    autotools('opus-1.5.2.tar.gz', 'opus', ['--host=' + host, '--disable-shared', '--enable-static', '--disable-extra-programs', '--disable-doc'], 'lib/libopus.a')
    autotools('libwebp-1.5.0.tar.gz', 'webp', ['--host=' + host, '--disable-shared', '--enable-static', '--disable-gl', '--disable-sdl', '--disable-libwebpmux', '--disable-libwebpdemux', '--disable-png', '--disable-jpeg', '--disable-tiff', '--disable-gif'], 'lib/libwebp.a')
    autotools('libvpx-1.15.2.tar.gz', 'vpx', ['--target=' + ('arm64-darwin20-gcc' if arch == 'arm64' else 'x86_64-darwin20-gcc'), '--disable-shared', '--enable-static', '--enable-pic', '--disable-examples', '--disable-tools', '--disable-docs', '--disable-unit-tests'], 'lib/libvpx.a')
    if not (prefix / 'lib/libaom.a').exists():
        log(arch + ': building AV1 encoder')
        src = unpack('libaom-3.12.1.tar.gz', base / 'aom')
        obj = base / 'aom-build'; obj.mkdir(exist_ok=True)
        run(['cmake', '-S', src, '-B', obj, '-DCMAKE_INSTALL_PREFIX=' + str(prefix), '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=' + arch,
             '-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0', '-DCMAKE_SYSTEM_PROCESSOR=' + ('arm64' if arch == 'arm64' else 'x86_64'),
             '-DCMAKE_SYSTEM_NAME=Darwin', '-DBUILD_SHARED_LIBS=OFF', '-DENABLE_TESTS=OFF', '-DENABLE_DOCS=OFF', '-DENABLE_EXAMPLES=OFF', '-DENABLE_TOOLS=OFF'], obj, env, 'configure')
        run(['cmake', '--build', obj, '--parallel', str(JOBS)], obj, env, 'make')
        run(['cmake', '--install', obj], obj, env, 'install')
    revision = prefix / '.runtime-revision'
    if not (prefix / 'bin/ffmpeg').exists() or not revision.exists() or revision.read_text() != '2':
        log(arch + ': building FFmpeg')
        src = unpack('ffmpeg-9.0.2.tar.xz', base / 'ffmpeg')
        if not (src / 'ffbuild/config.mak').exists() or not revision.exists() or revision.read_text() != '2':
            run(['./configure', '--prefix=' + str(prefix), '--arch=' + ('aarch64' if arch == 'arm64' else 'x86_64'), '--target-os=darwin', '--enable-cross-compile',
                 '--cc=clang', '--cxx=clang++', '--extra-cflags=' + flags + ' -I' + str(prefix / 'include'), '--extra-ldflags=' + env['LDFLAGS'] + ' -L' + str(prefix / 'lib'),
                 '--extra-libs=-liconv', '--pkg-config-flags=--static', '--disable-autodetect', '--disable-shared', '--enable-static', '--disable-debug', '--disable-doc', '--disable-ffplay',
                 '--disable-network', '--disable-indevs', '--enable-indev=lavfi', '--disable-outdevs', '--enable-gpl', '--enable-pthreads', '--enable-zlib', '--enable-iconv',
                 '--enable-videotoolbox', '--enable-audiotoolbox', '--enable-libx264', '--enable-libmp3lame', '--enable-libopus', '--enable-libvpx', '--enable-libwebp', '--enable-libaom'], src, env, 'configure')
        run(['make', '-j' + str(JOBS)], src, env, 'make')
        run(['make', 'install'], src, env, 'install')
        revision.write_text('2')
    return prefix

with ThreadPoolExecutor(2) as pool:
    prefixes = list(pool.map(build, ['arm64', 'x86_64']))
OUT.mkdir(parents=True, exist_ok=True)
for name in ['ffmpeg', 'ffprobe']:
    dest = OUT / name
    subprocess.run(['lipo', '-create', *[str(p / 'bin' / name) for p in prefixes], '-output', str(dest)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(dest)], check=True)
    deps = subprocess.check_output(['otool', '-L', str(dest)], text=True)
    for line in deps.splitlines():
        if 'compatibility version' in line and not line.strip().startswith(('/usr/lib/', '/System/Library/')):
            raise RuntimeError('Non-system dependency: ' + line)
    subprocess.run(['lipo', str(dest), '-verify_arch', 'arm64', 'x86_64'], check=True)
log('Standalone universal FFmpeg and ffprobe ready: ' + str(OUT))

# Include the license/patent notices from every component next to the executables.
licenses = VENDOR / 'licenses'
for name in ['ffmpeg', 'x264', 'lame', 'opus', 'webp', 'vpx', 'aom']:
    src = BASE / 'arm64' / name
    dest = licenses / name
    dest.mkdir(parents=True, exist_ok=True)
    for item in src.iterdir():
        if item.is_file() and (item.name.startswith(('COPYING', 'LICENSE', 'PATENTS')) or item.name in ['AUTHORS', 'NOTICE']):
            shutil.copy2(item, dest / item.name)
