#!/usr/bin/env python3
"""Accelerated memory probe of the real StreamClient, without UI or sensor access.

--revision v1.0.4 reads baseline sources from Git without changing the checkout.
RSS is sampled externally; it is not Activity Monitor's physical footprint.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', help='Git ref for baseline, default: working files')
    parser.add_argument('--samples', type=int, default=20000)
    parser.add_argument('--spacing-ms', type=float, default=1)
    parser.add_argument('--stderr-bytes', type=int, default=0)
    parser.add_argument('--inspect', action='store_true', help='save vmmap and autorelease-pool inspection at the end')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.samples < 1 or args.spacing_ms < 0 or args.stderr_bytes < 0:
        parser.error('sample count must be positive; spacing and stderr size nonnegative')
    root = Path(__file__).resolve().parents[1]
    source_paths = ['Sources/ChipBarCore/Metrics.swift', 'Sources/ChipBar/StreamClient.swift']
    with tempfile.TemporaryDirectory(prefix='chipbar-soak-') as directory:
        folder = Path(directory)
        for path in source_paths:
            content = (subprocess.check_output(['git', 'show', f'{args.revision}:{path}'], cwd=root)
                       if args.revision else (root / path).read_bytes())
            (folder / Path(path).name).write_bytes(content)
        fixture = root / 'Tests/ChipBarCoreTests/Fixtures/m1-pro.json'
        helper = folder / 'macmon-fixture'
        helper.write_text('#!/usr/bin/python3\n' + f'''
import os, time
from pathlib import Path
line = Path({str(fixture)!r}).read_bytes().rstrip(b'\\n') + b'\\n'
for _ in range({args.samples}):
    os.write(1, line)
    if {args.stderr_bytes}: os.write(2, b'x' * {args.stderr_bytes})
    time.sleep({args.spacing_ms / 1000!r})
time.sleep(90)
''')
        helper.chmod(0o755)
        harness = folder / 'Probe.swift'
        harness.write_text('''import Foundation
import ChipBarCore
@main enum Probe {
    static func memory() -> String {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return "task_info_error=\\(result)" }
        return "resident_bytes=\\(info.resident_size) footprint_bytes=\\(info.phys_footprint) compressed_bytes=\\(info.compressed)"
    }
    static func main() {
        let target = Int(CommandLine.arguments[2])!
        let ready = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var count = 0
        var failed = false
        let client = StreamClient(path: CommandLine.arguments[1], interval: 1000,
            onSample: { _ in
                lock.lock(); count += 1; let current = count; lock.unlock()
                if current % 1000 == 0 || current == target {
                    print("samples=\\(current) \\(memory())"); fflush(stdout)
                }
                if current == target { ready.signal() }
            }, onFailure: { message in
                lock.lock(); failed = true; lock.unlock()
                fputs(message + "\\n", stderr); ready.signal()
            })
        do { try client.start() } catch { fputs("\\(error)\\n", stderr); exit(1) }
        let result = ready.wait(timeout: .now() + 600)
        // Keep the readers alive and blocked, so releasing the worker at exit
        // cannot disguise retained temporary objects during the measurement.
        sleep(UInt32(CommandLine.arguments[3])!)
        print("before_stop \\(memory())"); fflush(stdout)
        client.stop(wait: true)
        lock.lock(); let success = !failed && count == target; lock.unlock()
        exit(success && result != .timedOut ? 0 : 1)
    }
}
''')
        subprocess.run(['xcrun', 'swiftc', '-O', '-emit-library', '-emit-module',
                        '-module-name', 'ChipBarCore', 'Metrics.swift',
                        '-Xlinker', '-install_name', '-Xlinker', '@rpath/libChipBarCore.dylib',
                        '-o', 'libChipBarCore.dylib'], cwd=folder, check=True)
        subprocess.run(['xcrun', 'swiftc', '-O', '-I', str(folder), '-L', str(folder),
                        '-lChipBarCore', '-Xlinker', '-rpath', '-Xlinker', str(folder),
                        'StreamClient.swift', 'Probe.swift', '-o', 'probe'], cwd=folder, check=True)
        records = []
        inspected = False
        started = time.monotonic()
        log = folder / 'probe.log'
        with log.open('w') as stream:
            process = subprocess.Popen([str(folder / 'probe'), str(helper), str(args.samples),
                                        '30' if args.inspect else '5'],
                                       # Leave inspection time while both read loops remain alive.
                                       # The helper must also stay alive throughout this interval.
                                       stdout=stream, stderr=subprocess.STDOUT)
            try:
                while process.poll() is None:
                    rss = subprocess.run(['ps', '-o', 'rss=', '-p', str(process.pid)],
                                         capture_output=True, text=True).stdout.strip()
                    if rss:
                        record = {'seconds': round(time.monotonic() - started, 2), 'rss_kib': int(rss)}
                        records.append(record)
                        print(f"{record['seconds']:6.2f}s  RSS={int(rss) / 1024:8.2f} MiB", flush=True)
                    if args.inspect and not inspected and f'samples={args.samples} ' in log.read_text():
                        inspected = True
                        args.output.parent.mkdir(parents=True, exist_ok=True)
                        for suffix, command in [
                            ('.vmmap.txt', ['vmmap', '-summary', str(process.pid)]),
                            ('.autorelease.txt', ['leaks', '--autoreleasePools', '--groupByType', str(process.pid)])
                        ]:
                            inspection = subprocess.run(command, capture_output=True, text=True, timeout=20)
                            args.output.with_suffix(suffix).write_text(inspection.stdout + inspection.stderr)
                    if time.monotonic() - started > 620:
                        raise TimeoutError('probe exceeded 620 seconds')
                    time.sleep(1)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
        result = {'revision': args.revision or 'working-tree', 'samples': args.samples,
                  'spacing_ms': args.spacing_ms, 'stderr_bytes_per_sample': args.stderr_bytes,
                  'fixture_bytes': fixture.stat().st_size, 'exit_code': process.returncode,
                  'os': subprocess.check_output(['sw_vers'], text=True),
                  'records': records, 'probe_log': log.read_text()}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2))
        print(result['probe_log'], end='')
        if process.returncode:
            raise SystemExit(process.returncode)


if __name__ == '__main__':
    main()
