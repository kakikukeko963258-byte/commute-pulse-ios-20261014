#!/usr/bin/env python3
"""Build-output simulator screenshot capture helper for macOS CI runners."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any


BUNDLE_ID = "dev.commutepulse.app"
SCENARIOS = (
    "idle",
    "missedOrigin",
    "intermediateRecovery",
    "reverse",
    "midnight",
    "express",
    "gpsMissing",
    "ambiguous",
)
REQUIRED_SCENARIOS = {"idle", "reverse", "express"}
SCENARIO_STEPS = {"idle": 0, "missedOrigin": 2, "intermediateRecovery": 3,
                  "reverse": 1, "midnight": 1, "express": 1, "gpsMissing": 2, "ambiguous": 1}
DEVICE_PRIORITY = ("iPhone 17e", "iPhone 16e", "iPhone 17")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class Runner:
    def __init__(self, out_dir: Path) -> None:
        self.out_dir = out_dir
        self.operations: list[dict[str, Any]] = []

    def run(
        self,
        label: str,
        args: list[str],
        timeout: int,
        *,
        optional: bool = False,
    ) -> subprocess.CompletedProcess[str] | None:
        command = ["xcrun", "simctl", *args]
        record: dict[str, Any] = {
            "step": label,
            "command": command,
            "timeoutSeconds": timeout,
            "optional": optional,
        }
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
            record.update(
                {
                    "returnCode": result.returncode,
                    "stdout": result.stdout.strip(),
                    "stderr": result.stderr.strip(),
                    "succeeded": result.returncode == 0,
                }
            )
            self.operations.append(record)
            if result.returncode != 0 and not optional:
                print(f"ERROR {label}: {result.stderr.strip() or result.stdout.strip()}", file=sys.stderr)
            return result
        except subprocess.TimeoutExpired as exc:
            record.update(
                {
                    "succeeded": False,
                    "error": f"timed out after {timeout}s",
                    "stdout": _decode(exc.stdout),
                    "stderr": _decode(exc.stderr),
                }
            )
        except OSError as exc:
            record.update({"succeeded": False, "error": str(exc)})
        self.operations.append(record)
        if not optional:
            print(f"ERROR {label}: {record.get('error', 'command failed')}", file=sys.stderr)
        return None


class AbortCapture(Exception):
    """Stop after a required setup step fails, then persist metadata and clean up."""


def _decode(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace").strip()
    return value.strip()


def _json_result(result: subprocess.CompletedProcess[str] | None) -> Any:
    if result is None or result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def _version_key(value: str) -> tuple[int, ...]:
    numbers = re.findall(r"\d+", value)
    return tuple(int(part) for part in numbers) or (0,)


def _available_runtime(payload: Any) -> dict[str, Any] | None:
    runtimes = payload.get("runtimes", []) if isinstance(payload, dict) else []
    candidates = [
        runtime
        for runtime in runtimes
        if (runtime.get("platform") == "iOS"
            or str(runtime.get("identifier", "")).startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
            or str(runtime.get("name", "")).startswith("iOS "))
        and runtime.get("isAvailable", False)
        and runtime.get("identifier")
    ]
    return max(
        candidates,
        key=lambda item: _version_key(str(item.get("version", item.get("name", "0")))),
        default=None,
    )


def _available_iphone_type(payload: Any) -> dict[str, Any] | None:
    devicetypes = payload.get("devicetypes", []) if isinstance(payload, dict) else []
    candidates = [
        item
        for item in devicetypes
        if item.get("productFamily") == "iPhone"
        and item.get("name")
        and item.get("identifier")
    ]
    if not candidates:
        candidates = [
            item
            for item in devicetypes
            if "iphone" in str(item.get("name", "")).lower()
            and item.get("identifier")
        ]
    lowered = [(item, str(item.get("name", "")).lower()) for item in candidates]
    for wanted in DEVICE_PRIORITY:
        match = next((item for item, name in lowered if name == wanted.lower()), None)
        if match:
            return match
    return max(candidates, key=lambda item: _version_key(str(item.get("name", ""))), default=None)


def _write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _select_device_type(payload: Any) -> dict[str, Any] | None:
    return _available_iphone_type(payload)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Built iOS Simulator .app directory")
    parser.add_argument("--output", type=Path, default=Path("artifacts/screenshots"),
                        help="Screenshot artifact directory")
    parser.add_argument("--steps", type=int, default=4, help="Synthetic observation steps for scenarios")
    parser.add_argument("--wait-seconds", type=float, default=5.0, help="Wait after each launch before capture")
    args = parser.parse_args()

    if args.steps < 0:
        parser.error("--steps must be zero or greater")
    if args.wait_seconds < 0:
        parser.error("--wait-seconds must be zero or greater")

    app_path = args.app.expanduser().resolve()
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = args.output.expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    runner = Runner(out_dir)

    metadata: dict[str, Any] = {
        "createdAtUTC": dt.datetime.now(dt.timezone.utc).isoformat(),
        "appPath": str(app_path),
        "bundleIdentifier": BUNDLE_ID,
        "scenarioKeys": list(SCENARIOS),
        "stepsPerScenario": args.steps,
        "waitSecondsAfterLaunch": args.wait_seconds,
        "simulator": True,
        "simulated": True,
        "realGPS": False,
        "deviceName": None,
        "actualDeviceName": None,
        "runtime": None,
        "deviceType": None,
        "type": None,
        "screenshotFiles": [],
        "scenarios": [],
        "operations": runner.operations,
        "errors": [],
    }

    created_udid: str | None = None
    boot_attempted = False
    try:
        devices_result = runner.run("list available devices", ["list", "devices", "available", "-j"], 30)
        types_result = runner.run("list device types", ["list", "devicetypes", "-j"], 30)
        runtimes_result = runner.run("list runtimes", ["list", "runtimes", "-j"], 30)
        inventory = {
            "capturedAtUTC": dt.datetime.now(dt.timezone.utc).isoformat(),
            "availableDevices": _json_result(devices_result),
            "deviceTypes": _json_result(types_result),
            "runtimes": _json_result(runtimes_result),
        }
        inventory_path = out_dir / "simulator_inventory.json"
        _write_json(inventory_path, inventory)
        metadata["simulatorInventoryFile"] = str(inventory_path)

        if not app_path.is_dir():
            metadata["errors"].append(f"Simulator app does not exist: {app_path}")
            raise AbortCapture

        runtime = _available_runtime(inventory["runtimes"])
        device_type = _select_device_type(inventory["deviceTypes"])
        if runtime is None:
            metadata["errors"].append("No available iOS Simulator runtime was found")
            raise AbortCapture
        if device_type is None:
            metadata["errors"].append("No available iPhone Simulator device type was found")
            raise AbortCapture

        metadata["runtime"] = runtime.get("name", runtime.get("identifier"))
        metadata["runtimeIdentifier"] = runtime["identifier"]
        metadata["deviceType"] = device_type.get("name")
        metadata["type"] = device_type.get("name")
        metadata["deviceTypeIdentifier"] = device_type["identifier"]
        device_name = f"CommutePulse-Capture-{timestamp}"
        create = runner.run(
            "create simulator",
            ["create", device_name, device_type["identifier"], runtime["identifier"]],
            90,
        )
        if create is None or create.returncode != 0:
            metadata["errors"].append("Could not create the selected iPhone simulator")
            raise AbortCapture
        created_udid = create.stdout.strip().splitlines()[-1].strip()
        if not re.fullmatch(r"[0-9A-Fa-f-]{36}", created_udid):
            metadata["errors"].append(f"simctl create returned an invalid device id: {created_udid}")
            created_udid = None
            raise AbortCapture
        metadata["deviceName"] = device_name
        metadata["actualDeviceName"] = device_name
        metadata["deviceUDID"] = created_udid

        boot_attempted = True
        boot = runner.run("boot simulator", ["boot", created_udid], 120)
        if boot is None or boot.returncode != 0:
            metadata["errors"].append("Could not boot the created simulator")
            raise AbortCapture
        bootstatus = runner.run("wait for boot", ["bootstatus", created_udid, "-b"], 300)
        if bootstatus is None or bootstatus.returncode != 0:
            metadata["errors"].append("Simulator bootstatus did not complete")
            raise AbortCapture

        install = runner.run("install app", ["install", created_udid, str(app_path)], 180)
        if install is None or install.returncode != 0:
            metadata["errors"].append("Could not install the simulator app")
            raise AbortCapture

        runner.run(
            "override status bar",
            ["status_bar", created_udid, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100"],
            30,
            optional=True,
        )

        for scenario in SCENARIOS:
            launch = runner.run(
                f"launch {scenario}",
                [
                    "launch",
                    "--terminate-running-process",
                    created_udid,
                    BUNDLE_ID,
                    "--screenshot-scenario",
                    scenario,
                    "--screenshot-steps",
                    str(SCENARIO_STEPS.get(scenario, args.steps)),
                ],
                90,
            )
            record: dict[str, Any] = {
                "scenario": scenario,
                "steps": SCENARIO_STEPS.get(scenario, args.steps),
                "deviceName": device_name,
                "actualDeviceName": device_name,
                "runtime": metadata["runtime"],
                "deviceType": metadata["deviceType"],
                "type": metadata["type"],
                "simulator": True,
                "simulated": True,
                "realGPS": False,
                "screenshotFile": None,
                "succeeded": False,
            }
            if launch is None or launch.returncode != 0:
                record["error"] = "simctl launch failed"
                metadata["errors"].append(f"{scenario}: simctl launch failed")
                metadata["scenarios"].append(record)
                print(f"FAIL {scenario}: launch failed", file=sys.stderr)
                continue

            time.sleep(args.wait_seconds)
            container = runner.run(f"read data container {scenario}",
                                   ["get_app_container", created_udid, BUNDLE_ID, "data"], 30)
            state = None
            if container is not None and container.returncode == 0:
                state_path = Path(container.stdout.strip()) / "Documents/screenshot-state.json"
                if state_path.is_file():
                    state = json.loads(state_path.read_text(encoding="utf-8"))
                    _write_json(out_dir / f"{scenario}-state.json", state)
                    record["state"] = state
            if state is None or state.get("scenario") != scenario:
                record["error"] = "App did not produce the expected scenario state"
                metadata["errors"].append(f"{scenario}: no matching app state")
                metadata["scenarios"].append(record)
                continue
            image_path = out_dir / f"{scenario}.png"
            screenshot = runner.run(
                f"screenshot {scenario}",
                ["io", created_udid, "screenshot", str(image_path)],
                60,
            )
            if screenshot is None or screenshot.returncode != 0 or not image_path.is_file():
                record["error"] = "simctl screenshot failed or output file is missing"
                metadata["errors"].append(f"{scenario}: screenshot command failed")
            elif image_path.read_bytes()[: len(PNG_SIGNATURE)] != PNG_SIGNATURE:
                record["error"] = "screenshot output is not a PNG file"
                metadata["errors"].append(f"{scenario}: output was not a PNG")
            else:
                relative = image_path.as_posix()
                record["screenshotFile"] = relative
                record["succeeded"] = True
                metadata["screenshotFiles"].append(relative)
                print(f"OK {scenario}: {relative} [{device_name}]")
            metadata["scenarios"].append(record)

    except AbortCapture:
        pass
    finally:
        if created_udid is not None and boot_attempted:
            shutdown = runner.run("shutdown simulator", ["shutdown", created_udid], 60, optional=True)
            metadata["shutdownSucceeded"] = shutdown is not None and shutdown.returncode == 0
        metadata["operations"] = runner.operations

    required_ok = all(
        any(item.get("scenario") == key and item.get("succeeded") for item in metadata["scenarios"])
        for key in REQUIRED_SCENARIOS
    )
    return _finish(metadata, out_dir, required_ok)


def _finish(metadata: dict[str, Any], out_dir: Path, success: bool) -> int:
    metadata["requiredScenarios"] = sorted(REQUIRED_SCENARIOS)
    metadata["requiredScenariosSucceeded"] = success
    metadata["finishedAtUTC"] = dt.datetime.now(dt.timezone.utc).isoformat()
    metadata_path = out_dir / "metadata.json"
    _write_json(metadata_path, metadata)
    print(f"Metadata: {metadata_path}")
    if success:
        print("Required screenshots captured: idle, reverse, express")
        return 0
    print("Required screenshots are incomplete; see metadata and operation errors", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
