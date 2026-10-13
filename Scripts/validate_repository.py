"""No compilation/network: validate deliverable structure and bundled facts."""
from __future__ import annotations

import json
import plistlib
import re
import runpy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    checks = []
    required = [
        "Package.swift", "project.yml", "README.md", "Docs/Architecture.md",
        "Docs/Inference.md", "Docs/Sources.md", "Docs/AltStore.md",
        "Docs/Privacy.md", "Docs/Validation.md",
        "Sources/CommuteApp/Resources/Timetable.json",
        "Sources/CommuteApp/Resources/SourceManifest.json",
        "Tests/CommuteCoreTests/CommuteEngineTests.swift",
    ]
    for item in required:
        require((ROOT / item).is_file(), f"Missing deliverable: {item}")
    checks.append("required source/data/documentation files")

    for item in ROOT.glob("Sources/**/*.plist"):
        with item.open("rb") as stream:
            plistlib.load(stream)
    for item in ROOT.glob("Sources/**/*.xcprivacy"):
        with item.open("rb") as stream:
            plistlib.load(stream)
    infos = []
    entitlements = []
    for folder, name in [("CommuteApp", "CommutePulse"), ("CommuteWidgets", "CommutePulseWidgets")]:
        with (ROOT / f"Sources/{folder}/Info.plist").open("rb") as stream:
            infos.append(plistlib.load(stream))
        with (ROOT / f"Sources/{folder}/{name}.entitlements").open("rb") as stream:
            entitlements.append(plistlib.load(stream))
    key = "com.apple.security.application-groups"
    require(entitlements[0][key] == entitlements[1][key], "Target App Groups differ")
    require(infos[0]["AppGroupIdentifier"] == infos[1]["AppGroupIdentifier"] == entitlements[0][key][0],
            "Runtime App Group differs from requested entitlements")
    require("location" in infos[0]["UIBackgroundModes"], "Location background mode absent")
    require(infos[0]["NSSupportsLiveActivities"], "Live Activity permission declaration absent")
    checks.append("plist validity and both-target App Group consistency")

    workflows = list(ROOT.glob(".github/workflows/*"))
    require(len(workflows) == 1, "Unexpected workflows")
    workflow = workflows[0].read_text(encoding="utf-8")
    event_block = re.search(r"^on:\s*\n(.*?)(?=^\S)", workflow, flags=re.M | re.S)
    require(event_block is not None, "Workflow trigger block absent")
    event_names = re.findall(r"^  ([a-z_]+):", event_block.group(1), flags=re.M)
    require(event_names == ["workflow_dispatch"], f"Non-manual triggers: {event_names}")
    require("runs-on: macos-15" in workflow and "xcodebuild archive" in workflow, "macOS/Xcode archive absent")
    require("actions/upload-artifact@" in workflow and "CommutePulse-AltStore.ipa" in workflow,
            "IPA artifact output absent")
    checks.append("manual-only macOS Xcode workflow and IPA artifact")

    shared = (ROOT / "Sources/Shared/RouteProgressView.swift").read_text(encoding="utf-8")
    require("ProgressView(timerInterval:" in shared and "countsDown: false" in shared,
            "System time-linked progress missing")
    require('["高", "輪", "GW"]' in shared, "Takanawa display grouping missing")
    require("state.isSimulated" in shared, "Virtual-clock simulation not marked")
    sensor = (ROOT / "Sources/CommuteApp/SensorClient.swift").read_text(encoding="utf-8")
    require("TravelObservation(" in sensor, "Real sensors bypass shared engine")
    debug = (ROOT / "Sources/CommuteApp/DebugPlayback.swift").read_text(encoding="utf-8")
    require("TravelObservation(" in debug, "Simulation bypasses shared engine")
    checks.append("system timer, grouped vertical labels and common observation input")

    # The app has no network client; developer-side data maintenance scripts are separate.
    for source in ROOT.glob("Sources/**/*.swift"):
        text = source.read_text(encoding="utf-8")
        require(not re.search(r"\b(URLSession|NWConnection|import Network)\b", text),
                f"Unexpected runtime network client: {source.relative_to(ROOT)}")
    checks.append("no runtime network client in app/core/extension")

    for item in ROOT.glob("Sources/CommuteApp/Resources/*.json"):
        json.loads(item.read_text(encoding="utf-8"))
    require((ROOT / "Data/SourceManifest.json").read_bytes() ==
            (ROOT / "Sources/CommuteApp/Resources/SourceManifest.json").read_bytes(),
            "Published/bundled source manifests differ")
    checks.append("all bundled JSON parses; source manifest synchronized")

    validator = ROOT / "Scripts/validate_data.py"
    require(validator.exists(), "Missing timetable validator")
    runpy.run_path(str(validator), run_name="__main__")
    checks.append("timetable and evidence validator")

    print(f"Repository static validation: PASS ({len(checks)} check groups)")
    for check in checks:
        print("  - " + check)
    print("Swift/Xcode compilation, XCTest execution, IPA signing and device checks: NOT RUN")


if __name__ == "__main__":
    main()
