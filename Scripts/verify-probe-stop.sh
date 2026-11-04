#!/bin/bash
# Verify the real production cancellation/reaper code, not a mock.
# Only a temporary owned test child is stopped; an unrelated child survives.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/.build/probe-cancellation-check"
mkdir -p "$DIR"
/usr/bin/python3 - "$ROOT" "$DIR/test.swift" <<'PY'
from pathlib import Path
import sys
root, target = map(Path, sys.argv[1:])
source = (root / "Sources/CodexHarbor/Services/HarborNodeLatencyTester.swift").read_text()
start = source.index("final class HarborLatencyCancellation:")
end = source.index("/// Safe summaries of probe failures")
helpers = source[start:end]
test = r"""
@main struct ProbeStopTest {
    static func main() {
        let token = HarborLatencyCancellation()
        let owned = Process()
        owned.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        owned.arguments = ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"]
        owned.standardOutput = FileHandle.nullDevice
        owned.standardError = FileHandle.nullDevice
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        unrelated.standardOutput = FileHandle.nullDevice
        unrelated.standardError = FileHandle.nullDevice
        defer {
            HarborProbeProcessReaper.stop(owned)
            HarborProbeProcessReaper.stop(unrelated)
        }
        do { try owned.run(); try unrelated.run() }
        catch { fputs("process start failed: \(error)\n", stderr); exit(1) }
        Thread.sleep(forTimeInterval: 0.5)
        guard token.observe({
            HarborProbeProcessReaper.requestStop(owned)
        }) != nil else { exit(2) }
        let start = Date.now
        token.cancel()
        let deadline = Date.now.addingTimeInterval(3)
        while owned.isRunning && Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.04)
        }
        guard !owned.isRunning else {
            fputs("FAIL: canceled probe child still running\n", stderr)
            exit(3)
        }
        guard unrelated.isRunning else {
            fputs("FAIL: unrelated process killed\n", stderr)
            exit(4)
        }
        print(String(format: "PASS: owned probe killed in %.2fs, unrelated child untouched",
                     Date.now.timeIntervalSince(start)))
    }
}
"""
target.write_text("import Foundation\nimport Darwin\n" + helpers + test)
PY
/usr/bin/swiftc -parse-as-library "$DIR/test.swift" -o "$DIR/probe-stop-test"
"$DIR/probe-stop-test"
