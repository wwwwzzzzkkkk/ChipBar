#!/usr/bin/env python3
"""Probe the real monitor, Charts and panel with accelerated synthetic samples.

Uses temporary source copies and command-line defaults; does not change saved
settings or use hardware sensors. Opens a test panel in the current GUI session.
Memory is TASK_VM_INFO physical footprint, including compressed allocations.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, default=180)
    parser.add_argument('--spacing-ms', type=int, default=20)
    parser.add_argument('--prefill', type=int, default=0, help='send initial samples rapidly before opening the panel')
    parser.add_argument('--chart-revision', help='read only Dashboard.swift from a Git ref, keeping the fixed reader')
    parser.add_argument('--legacy-material', action='store_true')
    parser.add_argument('--no-chart', action='store_true', help='omit only the trend in temporary test sources')
    parser.add_argument('--gaps', action='store_true', help='emit missing power metrics periodically for visual gap QA')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.seconds < 30 or args.spacing_ms < 1 or args.prefill < 0:
        parser.error('seconds must be >= 30 and spacing-ms >= 1')
    root = Path(__file__).resolve().parents[1]
    args.output = args.output.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='chipbar-ui-soak-') as directory:
        folder = Path(directory)
        core = root / 'Sources/ChipBarCore/Metrics.swift'
        subprocess.run(['xcrun', 'swiftc', '-O', '-emit-library', '-emit-module',
                        '-module-name', 'ChipBarCore', str(core),
                        '-Xlinker', '-install_name', '-Xlinker', '@rpath/libChipBarCore.dylib',
                        '-o', 'libChipBarCore.dylib'], cwd=folder, check=True)
        sources = []
        for source in sorted((root / 'Sources/ChipBar').glob('*.swift')):
            if source.name == 'App.swift':
                continue
            target = folder / source.name
            target.write_bytes(source.read_bytes())
            if args.chart_revision and source.name == 'Dashboard.swift':
                target.write_bytes(subprocess.check_output(['git', 'show', f'{args.chart_revision}:Sources/ChipBar/Dashboard.swift'], cwd=root))
            if args.no_chart and source.name == 'Dashboard.swift':
                target.write_text(target.read_text().replace('            trend\n', '            // trend omitted for the control probe\n'))
            sources.append(str(target))
        # Same-file extension can exercise private production lifecycle methods.
        # No accessibility automation, persistent defaults or product API changes.
        with (folder / 'MenuController.swift').open('a') as stream:
            stream.write('''
extension MenuController {
    func soakOpen() { if !panel.isVisible { togglePanel() } }
    func soakClose() { hidePanel(animated: false) }
    var soakMounted: Bool { dashboardMounted }
    var soakVisible: Bool { panel.isVisible }
    func soakCapture(path: String) throws {
        try capture(view: panelMaterial, path: path + ".view.png")
        captureScreenWindow(path: path + ".window.png")
    }
}
''')
        helper = folder / 'fixture-macmon'
        fixture = root / 'Tests/ChipBarCoreTests/Fixtures/m1-pro.json'
        helper.write_text('#!/usr/bin/python3\n' + f'''
import json, math, os, time
from pathlib import Path
data = json.loads(Path({str(fixture)!r}).read_text())
i = 0
while True:
    sample = dict(data)
    sample['all_power'] = 5 + 2 * math.sin(i / 20)
    if {args.gaps!r} and i % 200 < 10:
        for key in ('all_power', 'cpu_power', 'gpu_power', 'ane_power'): sample[key] = None
    os.write(1, json.dumps(sample).encode() + b'\\n')
    i += 1
    time.sleep(0.0001 if i < {args.prefill} else {args.spacing_ms / 1000!r})
''')
        helper.chmod(0o755)
        harness = folder / 'Probe.swift'
        harness.write_text('''import AppKit
import SwiftUI
@main enum Probe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let monitor = Monitor()
        let controller = MenuController(monitor: monitor)
        let duration = Int(CommandLine.arguments[1])!
        let start = Date()
        var records: [[String: Any]] = []
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let seconds = Int(Date().timeIntervalSince(start))
                let phase = seconds < duration * 2 / 3 ? "open" : seconds < duration * 5 / 6 ? "closed" : "reopened"
                if phase == "closed" { controller.soakClose() }
                else { controller.soakOpen() }
                precondition(monitor.history.count <= 600, "history exceeds bound")
                precondition(controller.soakMounted == (phase != "closed"), "hidden dashboard remains mounted")
                if seconds % 5 == 0 || seconds >= duration {
                    var info = task_vm_info_data_t()
                    var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                    let result = withUnsafeMutablePointer(to: &info) { pointer in
                        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
                        }
                    }
                    precondition(result == KERN_SUCCESS)
                    let record: [String: Any] = ["seconds": seconds, "phase": phase,
                        "historyCount": monitor.history.count, "connected": monitor.connected,
                        "panelVisible": controller.soakVisible, "dashboardMounted": controller.soakMounted,
                        "footprintBytes": info.phys_footprint, "residentBytes": info.resident_size]
                    records.append(record)
                    print(String(data: try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), encoding: .utf8)!)
                    fflush(stdout)
                }
                if seconds >= duration {
                    try! controller.soakCapture(path: CommandLine.arguments[2])
                    let data = try! JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                    try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
                    let success = monitor.connected && monitor.history.count > 0
                    monitor.stop(forQuit: true)
                    exit(success ? 0 : 1)
                }
            }
        }
        withExtendedLifetime((monitor, controller, timer)) { app.run() }
    }
}
''')
        subprocess.run(['xcrun', 'swiftc', '-O', '-I', str(folder), '-L', str(folder),
                        '-lChipBarCore', '-Xlinker', '-rpath', '-Xlinker', str(folder),
                        *sources, str(harness), '-o', 'probe'], cwd=folder, check=True)
        command = [str(folder / 'probe'), str(args.seconds), str(args.output),
                   '-macmonPath', str(helper), '-interval', '1000']
        if args.legacy_material:
            command.append('--legacy-material')
        subprocess.run(command, check=True, timeout=args.seconds + 30)
    print(f'Results: {args.output}')


if __name__ == '__main__':
    main()
