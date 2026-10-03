#!/usr/bin/env python3
import argparse, re, tempfile, shlex, sys
import pathlib, subprocess, os, json, plistlib, time, uuid, urllib.request, urllib.error, concurrent.futures, signal

parser = argparse.ArgumentParser(
    description="Opt-in reproduction of concurrent Mac/Android/Linux edits against a disposable native-auth backend."
)
parser.add_argument("--origin-file", type=pathlib.Path, required=True)
parser.add_argument("--macos-derived", type=pathlib.Path, required=True)
parser.add_argument("--android-serial", required=True)
parser.add_argument("--android-apk", type=pathlib.Path, required=True)
parser.add_argument("--android-test-apk", type=pathlib.Path, required=True)
parser.add_argument("--linux-vm", default="ArchLinux")
parser.add_argument("--linux-checkout", default="/root/src/snippets-account-key")
parser.add_argument(
    "--linux-target-dir",
    default="/root/src/snippets-linux-checkpoint/snippets-linux/target",
)
parser.add_argument(
    "--allow-disposable-android-reset", action="store_true", required=True
)
parser.add_argument(
    "--allow-disposable-linux-checkout", action="store_true", required=True
)
parser.add_argument(
    "--send-order",
    default="concurrent",
    choices=[
        "concurrent",
        "macos,android,linux",
        "macos,linux,android",
        "android,macos,linux",
        "android,linux,macos",
        "linux,macos,android",
        "linux,android,macos",
    ],
    help="All edits still share the same ancestor; vary publication order to localize the race.",
)
args = parser.parse_args()
assert args.android_serial.startswith("emulator-"), "disposable emulator required"
for value in [args.linux_checkout, args.linux_target_dir]:
    assert (
        value.startswith("/")
        and re.fullmatch(r"[A-Za-z0-9_./-]+", value)
        and ".." not in pathlib.PurePosixPath(value).parts
    )
REPO = pathlib.Path(__file__).resolve().parents[1]
os.umask(0o077)
R = pathlib.Path(tempfile.mkdtemp(prefix="snippets-stateful-repro."))
origin = args.origin_file.read_text().strip()
assert re.fullmatch(r"https://[A-Za-z0-9.-]+(?::[0-9]+)?", origin)
U = "/Applications/UTM.app/Contents/MacOS/utmctl"
ADB = str(
    pathlib.Path(
        os.environ.get("ANDROID_HOME", str(pathlib.Path.home() / "Library/Android/sdk"))
    )
    / "platform-tools/adb"
)
SERIAL = args.android_serial
report = {"phases": [], "status": "running"}
sims = {}
run = str(uuid.uuid4())
count = 0
auth = None
print("Private artifacts:", R, flush=True)


def req(path, method="GET", body=None, token=None):
    h = {"Accept": "application/json"}
    if body is not None:
        h["Content-Type"] = "application/json"
    if token:
        h["Authorization"] = "Bearer " + token
    r = urllib.request.Request(
        origin + path,
        data=None if body is None else json.dumps(body).encode(),
        headers=h,
        method=method,
    )
    with urllib.request.urlopen(r, timeout=30) as response:
        return json.loads(response.read()) if response.status != 204 else None


def command(cmd, label, timeout=360):
    with (R / (label + ".log")).open("w") as log:
        p = subprocess.run(
            cmd, cwd=REPO, stdout=log, stderr=subprocess.STDOUT, timeout=timeout
        )
    assert p.returncode == 0, label + "_failed"


def save():
    (R / "result.json").write_text(json.dumps(report, indent=2))


def absolute(v, source):
    if isinstance(v, str):
        return v.replace("__TESTROOT__", str(source.parent))
    if isinstance(v, list):
        return [absolute(x, source) for x in v]
    if isinstance(v, dict):
        return {k: absolute(x, source) for k, x in v.items()}
    return v


def apple(stage, role):
    global count
    count += 1
    label = f"{count:03}-{role}-{stage}"
    platform = "macos" if role == "macos" else "ios"
    if role != "macos":
        subprocess.run(["xcrun", "simctl", "boot", sims[role]], capture_output=True)
        command(
            ["xcrun", "simctl", "bootstatus", sims[role], "-b"], label + "-boot", 300
        )
    source = next((args.macos_derived / "Build/Products").glob("*.xctestrun"))
    doc = absolute(plistlib.loads(source.read_bytes()), source)
    targets = (
        [t for c in doc["TestConfigurations"] for t in c["TestTargets"]]
        if "TestConfigurations" in doc
        else [v for k, v in doc.items() if not k.startswith("__")]
    )
    for t in targets:
        t.setdefault("EnvironmentVariables", {}).update(
            {
                "SNIPPETS_STATEFUL_AUDIT": "disposable-installation",
                "SNIPPETS_AUDIT_STAGE": stage,
                "SNIPPETS_AUDIT_ROLE": role,
                "SNIPPETS_AUDIT_RUN": run,
                "SNIPPETS_CLOUD_E2E_SERVER_URL": origin,
                "SNIPPETS_CLOUD_E2E_SPACE_ID": space["spaceId"],
                "SNIPPETS_CLOUD_E2E_SERVER_INSTANCE_ID": space["serverInstanceId"],
                "SNIPPETS_CLOUD_E2E_ACCESS_TOKEN": auth["access_token"],
                "SNIPPETS_SUPPORT_DIR": str(R / (role + "-host-support")),
            }
        )
    fixture = R / (label + ".xctestrun")
    fixture.write_bytes(plistlib.dumps(doc))
    target = "Snippets macOSTests" if role == "macos" else "Snippets iOSTests"
    destination = (
        "platform=macOS,arch=arm64"
        if role == "macos"
        else "platform=iOS Simulator,id=" + sims[role]
    )
    print("Phase", label, flush=True)
    try:
        command(
            [
                "xcodebuild",
                "-quiet",
                "test-without-building",
                "-xctestrun",
                str(fixture),
                "-destination",
                destination,
                "-collect-test-diagnostics",
                "never",
                "-parallel-testing-enabled",
                "NO",
                "-only-testing:"
                + target
                + "/SnippetsCloudAppIntegrationTests/testStatefulFaultAudit",
                "-resultBundlePath",
                str(R / (label + ".xcresult")),
            ],
            label,
        )
        summary = json.loads(
            subprocess.check_output(
                [
                    "xcrun",
                    "xcresulttool",
                    "get",
                    "test-results",
                    "summary",
                    "--path",
                    str(R / (label + ".xcresult")),
                    "--format",
                    "json",
                ]
            )
        )
        assert summary["passedTests"] == 1 and summary["skippedTests"] == 0, (
            label + "_assertions"
        )
        (R / (label + "-summary.json")).write_text(json.dumps(summary, indent=2))
        home = (
            pathlib.Path.home()
            if role == "macos"
            else pathlib.Path(
                subprocess.check_output(
                    [
                        "xcrun",
                        "simctl",
                        "get_app_container",
                        sims[role],
                        "com.khm.snippets.debug",
                        "data",
                    ],
                    text=True,
                ).strip()
            )
        )
        snapshot = json.loads(
            (
                home
                / "Library/Caches"
                / ("SnippetsFaultAudit-" + run)
                / "audit-snapshot.json"
            ).read_text()
        )
        (R / (role + "-snapshot.json")).write_text(json.dumps(snapshot, indent=2))
        (R / (label + "-snapshot.json")).write_text(json.dumps(snapshot, indent=2))
        report["phases"].append({"role": role, "stage": stage, "status": "passed"})
        save()
        return snapshot
    finally:
        fixture.unlink(missing_ok=True)


def android(stage):
    global count
    count += 1
    label = f"{count:03}-android-{stage}"
    print("Phase", label, flush=True)
    command(
        [
            ADB,
            "-s",
            SERIAL,
            "shell",
            "am",
            "instrument",
            "-w",
            "-r",
            "-e",
            "class",
            "com.khm.snippets.android.StatefulFaultAuditTest",
            "-e",
            "snippetsKeepDeletion",
            "1",
            "-e",
            "snippetsStatefulAudit",
            "disposable-emulator",
            "-e",
            "snippetsStage",
            stage,
            "-e",
            "snippetsServerUrl",
            origin,
            "-e",
            "snippetsSpaceId",
            space["spaceId"],
            "-e",
            "snippetsAccessToken",
            auth["access_token"],
            "com.khm.snippets.android.test/androidx.test.runner.AndroidJUnitRunner",
        ],
        label,
    )
    log = (R / (label + ".log")).read_text()
    assert "OK (1 test)" in log and "FAILURES" not in log, label + "_assertions"
    snapshot = json.loads(
        subprocess.check_output(
            [
                ADB,
                "-s",
                SERIAL,
                "exec-out",
                "run-as",
                "com.khm.snippets.android",
                "cat",
                "no_backup/audit-snapshot.json",
            ]
        )
    )
    (R / "android-snapshot.json").write_text(json.dumps(snapshot, indent=2))
    (R / (label + "-snapshot.json")).write_text(json.dumps(snapshot, indent=2))
    report["phases"].append({"role": "android", "stage": stage, "status": "passed"})
    save()
    return snapshot


def linux(stage):
    global count
    count += 1
    label = f"{run}-{count:03}-linux-{stage}"
    print("Phase", label, flush=True)
    c = {
        "origin": origin,
        "token": auth["access_token"],
        "space": space["spaceId"],
        "run": run,
        "stage": stage,
    }
    subprocess.run(
        [U, "file", "push", args.linux_vm, "/root/snippets-stateful-config.json"],
        input=json.dumps(c).encode(),
        check=True,
        capture_output=True,
    )
    script = f"#!/bin/bash\numask 077\nexport HOME=/root CARGO_BUILD_JOBS=1 CARGO_TARGET_DIR={args.linux_target_dir}\ncd {args.linux_checkout}\ncargo test --locked --manifest-path snippets-linux/Cargo.toml --lib audit_stateful_fault -- --ignored --test-threads=1 > /root/{label}.log 2>&1\necho $? > /root/{label}.status\n"
    subprocess.run(
        [U, "file", "push", args.linux_vm, "/root/stateful-phase.sh"],
        input=script.encode(),
        check=True,
        capture_output=True,
    )
    subprocess.run(
        [
            U,
            "exec",
            args.linux_vm,
            "--cmd",
            "/usr/bin/systemd-run",
            "--collect",
            "--unit=snippets-" + label,
            "/bin/bash",
            "/root/stateful-phase.sh",
        ],
        capture_output=True,
        check=True,
    )
    deadline = time.monotonic() + 240
    result = None
    while time.monotonic() < deadline:
        p = subprocess.run(
            [U, "file", "pull", args.linux_vm, "/root/" + label + ".status"],
            capture_output=True,
        )
        if p.returncode == 0 and p.stdout.strip() in [b"0", b"1", b"101", b"127"]:
            result = p.stdout.strip()
            break
        time.sleep(2)
    (R / (label + ".log")).write_bytes(
        subprocess.check_output(
            [U, "file", "pull", args.linux_vm, "/root/" + label + ".log"]
        )
    )
    assert result == b"0", label + "_assertions"
    snapshot = json.loads(
        subprocess.check_output(
            [
                U,
                "file",
                "pull",
                args.linux_vm,
                "/root/snippets-stateful-" + run + "/audit-snapshot.json",
            ]
        )
    )
    (R / "linux-snapshot.json").write_text(json.dumps(snapshot, indent=2))
    (R / (label + "-snapshot.json")).write_text(json.dumps(snapshot, indent=2))
    report["phases"].append({"role": "linux", "stage": stage, "status": "passed"})
    save()
    return snapshot


def guest_script(script):
    path = "/root/snippets-stateful-repro-setup.sh"
    subprocess.run(
        [U, "file", "push", args.linux_vm, path],
        input=script.encode(),
        check=True,
        capture_output=True,
    )
    subprocess.run(
        [U, "exec", args.linux_vm, "--cmd", "/bin/bash", path],
        check=True,
        capture_output=True,
    )


installed = False
try:
    source = REPO / "scripts/test-fixtures/stateful_fault_audit.rs"
    guest = args.linux_checkout + "/snippets-linux/src/audit_stateful.rs"
    # This helper is only for an explicitly disposable checkout. A unique module
    # marker is removed after the run; production source is never patched.
    exists = subprocess.run(
        [U, "file", "pull", args.linux_vm, guest], capture_output=True
    )
    assert not exists.stdout, "remove an earlier audit fixture before running"
    subprocess.run(
        [U, "file", "push", args.linux_vm, guest],
        input=source.read_bytes(),
        check=True,
        capture_output=True,
    )
    guest_script(
        "set -eu\nprintf '\\n#[cfg(test)] mod audit_stateful; // stateful-e2e-fixture\\n' >> "
        + shlex.quote(args.linux_checkout + "/snippets-linux/src/lib.rs")
        + "\n"
    )
    installed = True
    auth = req("/v2/auth/accounts", "POST")["session"]
    space = req("/v2/spaces", "POST", token=auth["access_token"])["scope"]
    for label, apk in [("app", args.android_apk), ("tests", args.android_test_apk)]:
        command(
            [ADB, "-s", SERIAL, "install", "-r", "-t", str(apk)], "install-" + label
        )
    command(
        [ADB, "-s", SERIAL, "shell", "pm", "clear", "com.khm.snippets.android"],
        "clear-owned-emulator",
    )
    apple("seed", "macos")
    baseline = req(
        "/v2/spaces/" + space["spaceId"] + "/changes?limit=50",
        token=auth["access_token"],
    )["records"]
    for action in [
        lambda: apple("prepare", "macos"),
        lambda: android("prepare"),
        lambda: linux("prepare"),
    ]:
        action()
        assert (
            req(
                "/v2/spaces/" + space["spaceId"] + "/changes?limit=50",
                token=auth["access_token"],
            )["records"]
            == baseline
        ), "offline_fixture_changed_server"
    report["same_remote_ancestor_verified"] = True
    save()
    senders = {
        "macos": lambda: apple("replay", "macos"),
        "android": lambda: android("replay"),
        "linux": lambda: linux("replay"),
    }
    report["send_order"] = args.send_order
    if args.send_order == "concurrent":
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            futures = [pool.submit(sender) for sender in senders.values()]
            for future in futures:
                future.result()
    else:
        for role in args.send_order.split(","):
            senders[role]()
    for cycle in range(3):
        a = apple("verify", "macos")
        b = android("verify")
        c = linux("verify")
        report["cycles"] = cycle + 1
        report["counts"] = [len(a), len(b), len(c)]
        report["equal"] = a == b == c
        save()
    report["preserved_bodies"] = [
        role
        for role in ["macos", "android", "linux"]
        if "audit-concurrent-" + role in {r["content"] for r in a}
    ]
    save()
    assert a == b == c, "clients_not_converged"
    assert len(report["preserved_bodies"]) == 3, "lost_concurrent_body"
    assert len(a) == 5, "extra_conflict_copies"
    report["status"] = "passed"
except Exception as error:
    report["status"] = "failed"
    report["failure"] = (
        str(error) if isinstance(error, AssertionError) else type(error).__name__
    )
finally:
    if auth:
        try:
            req(
                "/v2/auth/revoke",
                "POST",
                {"token": auth["refresh_token"], "tokenTypeHint": "refresh_token"},
            )
        except Exception:
            report["revocation"] = "failed"
    if installed:
        try:
            guest_script(
                "set -eu\nsed -i '/stateful-e2e-fixture/d' "
                + shlex.quote(args.linux_checkout + "/snippets-linux/src/lib.rs")
                + "\nrm -f "
                + shlex.quote(guest)
                + " /root/snippets-stateful-config.json\n"
            )
        except Exception:
            report["guest_cleanup"] = "failed"
    save()
    print(json.dumps(report, indent=2), flush=True)
sys.exit(0 if report["status"] == "passed" else 1)
