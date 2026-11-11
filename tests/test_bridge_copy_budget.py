#!/usr/bin/env python3
"""Verify the real bridge's copy budget, framing and input isolation. No USB."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    out = (args.output or ROOT/'build'/('bridge-copy-'+uuid.uuid4().hex)).resolve()
    if not any(out.is_relative_to(ROOT/p) for p in ['build', 'results']):
        raise ValueError('output must be new and under project build/results')
    out.mkdir(parents=True, exist_ok=False)
    inputs = ['firmware/ch32v407/bridge.c', 'firmware/ch32v407/bridge.h',
              'firmware/main/wire_protocol.c', 'firmware/main/wire_protocol.h',
              'tests/ch32v407_core_test.cpp', 'native/desktop_pointer.hpp', 'native/clipboard_channel.hpp']
    hashes = {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in inputs}
    commands = []

    def run(argv, name):
        argv = list(map(str, argv)); commands.append(argv)
        (out/'commands.json').write_text(json.dumps(commands, indent=2)+'\n')
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=60)
        (out/(name+'.log')).write_text(result.stdout+result.stderr)
        if result.returncode:
            raise RuntimeError(f'{name} failed: see {out/(name+".log")}')
        return result.stdout

    inc = ['-Ifirmware/ch32v407', '-Ifirmware/main', '-Inative']
    # Install the hook after Darwin's fortified string.h macros; a command-line
    # -Dmemcpy alone is replaced by those macros and would measure nothing.
    probe = out/'bridge-probe.c'
    probe.write_text('#include <stddef.h>\n#include <string.h>\n'
                     'extern void *wk407_test_memcpy(void *,const void *,size_t);\n'
                     '#undef memcpy\n#define memcpy wk407_test_memcpy\n'
                     '#include "'+str(ROOT/'firmware/ch32v407/bridge.c')+'"\n')
    run(['clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', *inc,
         '-fno-builtin', '-c', probe, '-o', out/'bridge.o'], 'bridge')
    run(['clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', *inc,
         '-c', 'firmware/main/wire_protocol.c', '-o', out/'wire.o'], 'wire')
    binary = out/'core-test'
    run(['clang++', '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror', *inc,
         '-DWK407_COPY_BUDGET', 'tests/ch32v407_core_test.cpp', out/'bridge.o', out/'wire.o', '-o', binary], 'link')
    print(run([binary], 'core').strip())
    print(run([binary, '--copy-budget'], 'copy-budget').strip())
    if hashes != {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in inputs}:
        raise RuntimeError('test sources changed during execution')
    (out/'manifest.json').write_text(json.dumps({'physicalUSB': False, 'sources': hashes,
        'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest()}, indent=2)+'\n')


if __name__ == '__main__':
    main()
