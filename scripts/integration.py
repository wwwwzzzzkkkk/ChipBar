#!/usr/bin/env python3
"""Test subprocess boundaries without sensor load or admin rights."""
import os
import pathlib
import subprocess
import tempfile
import time
import sys

root = pathlib.Path(__file__).resolve().parents[1]
binary = root / "dist/ChipBar.app/Contents/MacOS/ChipBar"
if not binary.exists():
    sys.exit("Run scripts/build.sh first")

with tempfile.TemporaryDirectory(prefix="chipbar-test-") as directory:
    folder = pathlib.Path(directory)

    def helper(name, source):
        path = folder / name
        path.write_text("#!/usr/bin/python3\n" + source)
        path.chmod(0o755)
        return path

    def run(path, success, needle):
        result = subprocess.run([str(binary), "--diagnose", "--macmon", str(path)],
                                text=True, capture_output=True, timeout=22)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        assert needle in result.stdout + result.stderr, result.stdout + result.stderr

    fragmented = helper("fragmented", '''import os, time
line = b'{"cpu_power":2,"gpu_power":1,"ane_power":0,"temp":{"cpu_temp_avg":null}}\\n'
for _ in range(4):
    os.write(1, line[:13]); time.sleep(.02); os.write(1, line[13:])
time.sleep(5)
''')
    run(fragmented, True, "total=3.0W")
    print("PASS fragmented pipe output and null temperature")
    rejected = helper("unsupported", 'import sys\nsys.stderr.write("CPU power unavailable on this hardware\\n")\nsys.exit(7)\n')
    run(rejected, False, "CPU power unavailable on this hardware")
    print("PASS unsupported hardware stderr and nonzero exit")
    malformed = helper("malformed", "print('not json', flush=True)\n")
    run(malformed, False, "JSON")
    print("PASS malformed JSON rejects the stream")
    partial = helper("partial", 'import time\nfor _ in range(4): print(\'{"cpu_power":2}\', flush=True)\ntime.sleep(5)\n')
    run(partial, True, "total=unavailableW")
    print("PASS partial schema never fabricates a total")
    missing = subprocess.run([str(binary), "--diagnose", "--macmon", str(folder / "missing")], capture_output=True, text=True, timeout=5)
    assert missing.returncode != 0 and missing.stderr
    print("PASS missing executable")
    stubborn = helper("stubborn", f'''import os, signal, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path({str(folder / 'child.pid')!r}).write_text(str(os.getpid()))
for _ in range(4): print('{{"all_power":1}}', flush=True)
time.sleep(30)
''')
    run(stubborn, True, "total=1.0W")
    child = int((folder / "child.pid").read_text())
    time.sleep(.2)
    try:
        os.kill(child, 0)
    except ProcessLookupError:
        pass
    else:
        os.kill(child, 9)
        raise AssertionError("helper survived application shutdown")
    print("PASS forced cleanup of an unresponsive helper")
    silent = helper("silent", 'import time\ntime.sleep(30)\n')
    run(silent, False, "15 秒")
    print("PASS bounded diagnostic timeout")
print("7 integration checks passed")
