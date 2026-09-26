#!/usr/bin/env python3
"""Prepare, submit, release, and trace an existing universal iOS build. Never rebuilds it."""
import argparse
from datetime import datetime, timezone
import hashlib
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = "com.khm.snippets"
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"}
PUBLISHED = {"READY_FOR_SALE", "READY_FOR_DISTRIBUTION"}
IN_REVIEW = {"WAITING_FOR_REVIEW", "IN_REVIEW"}


def run(*args, cwd=None):
    return subprocess.check_output(list(map(str, args)), cwd=ROOT if cwd is None else cwd, text=True).strip()


def git(*args):
    return run("git", *args)


def asc(*args):
    env = os.environ.copy()
    for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
        env.pop(key, None)
    env["ASC_STRICT_AUTH"] = "true"
    result = subprocess.run(["asc", *map(str, args), "--output", "json"], env=env, text=True, stdout=subprocess.PIPE)
    # Readiness failures still return a useful report; retain it before blocking.
    if result.returncode and args[0] != "validate":
        raise subprocess.CalledProcessError(result.returncode, result.args)
    return json.loads(result.stdout)


def now():
    return datetime.now(timezone.utc).isoformat()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def save(path, value):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, indent=2) + "\n")
    temp.chmod(0o600)
    temp.replace(path)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def artifact_dir(version, build):
    require(re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", version), "Invalid marketing version")
    require(re.fullmatch(r"[1-9][0-9]*", build), "Invalid build number")
    root = Path(os.environ.get("SNIPPETS_IOS_RELEASES_DIR", Path.home() / ".local/share/snippets/releases/ios"))
    return root.expanduser().resolve() / version / build


def build_tag(receipt):
    return f'ios/build/{receipt["version"]}-{receipt["build"]}'


def release_tag(receipt):
    return f'ios/v{receipt["version"]}'


def ensure_tag(name, receipt, create=True):
    ref = f"refs/tags/{name}"
    exists = subprocess.run(["git", "show-ref", "--verify", "--quiet", ref], cwd=ROOT).returncode == 0
    if exists:
        require(git("rev-parse", ref + "^{commit}") == receipt["sourceCommit"], f"Conflicting immutable tag {name}")
        require(git("cat-file", "-t", ref) == "tag", f"Expected annotated tag {name}")
        annotation = json.loads(git("for-each-ref", "--format=%(contents)", ref))
        for key in ("sourceCommit", "version", "build", "ipaSHA256", "buildID", "appID"):
            require(annotation.get(key) == receipt.get(key), f"Tag {name} has different {key}")
    elif create:
        fields = {k: receipt[k] for k in ("sourceCommit", "version", "build", "ipaSHA256", "buildID", "appID")}
        git("tag", "-a", name, receipt["sourceCommit"], "-m", json.dumps(fields, indent=2))
    else:
        raise ValueError(f"Missing {name}; run reconcile first")


def record(args):
    """Called only after the existing script's signed-artifact/profile validation."""
    directory = artifact_dir(args.version, args.build)
    require(not directory.exists(), f"Artifacts already exist: {directory}; reconcile, or choose a new build")
    require(git("rev-parse", "HEAD") == args.commit, "HEAD changed during archive")
    dirty = bool(git("status", "--porcelain"))
    require(not dirty or args.dirty, "Worktree changed during archive")
    directory.mkdir(parents=True, mode=0o700)
    run("ditto", args.archive, directory / "Snippets.xcarchive")
    run("ditto", args.ipa, directory / "Snippets.ipa")
    receipt = dict(schema=1, appID=os.environ["ASC_APP_ID"], bundleID=BUNDLE,
                   version=args.version, build=args.build, sourceCommit=args.commit,
                   dirty=dirty or args.dirty, phase="exported", createdAt=now(),
                   ipaSHA256=sha256(directory / "Snippets.ipa"),
                   xcodeVersion=run("xcodebuild", "-version"), ascVersion=run("asc", "version"),
                   tests="skipped" if args.skip_tests else "passed", signedArtifactVerified=True)
    save(directory / "release.json", receipt)
    print(directory)


class Release:
    def __init__(self, version, build):
        self.directory = artifact_dir(version, build)
        self.path = self.directory / "release.json"
        self.receipt = json.loads(self.path.read_text())
        r = self.receipt
        require(r.get("schema") == 1 and r.get("version") == version and r.get("build") == build,
                "Receipt version/build/schema mismatch")
        require(r.get("appID") == os.environ["ASC_APP_ID"] and r.get("bundleID") == BUNDLE,
                "Receipt belongs to another app")
        require(not r.get("dirty", True) and r.get("signedArtifactVerified") is True,
                "Only a clean, verified archive can be released")
        require(sha256(self.directory / "Snippets.ipa") == r["ipaSHA256"], "IPA checksum mismatch")
        require(git("cat-file", "-t", r["sourceCommit"]) == "commit", "Source commit unavailable")
        app = asc("apps", "list", "--bundle-id", BUNDLE)["data"]
        require(any(a["id"] == r["appID"] and a["attributes"]["bundleId"] == BUNDLE for a in app),
                "Configured App Store app identity mismatch")

    def checkpoint(self, **fields):
        self.receipt.update(fields, updatedAt=now())
        save(self.path, self.receipt)

    def remote_build(self):
        r = self.receipt
        builds = asc("builds", "list", "--app", r["appID"], "--version", r["version"],
                     "--build-number", r["build"], "--platform", "IOS", "--paginate")["data"]
        require(len(builds) == 1, "Expected exactly one remote build; inspect upload status before retrying")
        build = builds[0]
        require(build["attributes"]["processingState"] == "VALID", "Build is not VALID")
        require(not build["attributes"].get("expired", False), "Build is expired")
        require(not r.get("buildID") or r["buildID"] == build["id"], "Remote build identity changed")
        return build

    def reconcile(self):
        # A receipt is written before upload, including an intent marker. An arbitrary
        # archive must not be retroactively associated with a matching remote number.
        require(self.receipt["phase"] != "exported", "No recorded upload attempt for this archive")
        build = self.remote_build()
        self.checkpoint(buildID=build["id"], phase="processed" if self.receipt["phase"] == "uploading" else self.receipt["phase"])
        ensure_tag(build_tag(self.receipt), self.receipt)
        print(f'Processed {self.receipt["version"]} ({self.receipt["build"]}); {build_tag(self.receipt)}')

    def version(self, required=True):
        r = self.receipt
        versions = asc("versions", "list", "--app", r["appID"], "--version", r["version"],
                       "--platform", "IOS", "--paginate")["data"]
        require(len(versions) <= 1, "Ambiguous App Store version")
        if not versions:
            require(not required, "App Store version does not exist; run prepare")
            return None
        return asc("versions", "view", "--version-id", versions[0]["id"], "--include-build")["data"]

    def attached(self, version):
        require((version.get("relationships", {}).get("build", {}).get("data") or {}).get("id")
                == self.receipt.get("buildID"), "App Store version has a different build attached")

    def validate(self, version):
        report = asc("validate", "--app", self.receipt["appID"], "--version-id", version["id"], "--platform", "IOS")
        save(self.directory / "readiness.json", report)
        print(json.dumps(report, indent=2))
        summary = report.get("summary", {})
        require(summary.get("errors") == 0 and summary.get("blocking") == 0,
                "Readiness checks failed; see retained readiness.json and browser-handoff prompt")

    def prepare(self, screenshots=False):
        r = self.receipt
        self.remote_build()
        ensure_tag(build_tag(r), r, create=False)
        metadata = ROOT / "Distribution/AppStore/metadata"
        locales = list((metadata / "version" / r["version"]).glob("*.json"))
        require(bool(locales), f'Write release metadata in {metadata / "version" / r["version"]} first')
        for locale in locales:
            require(json.loads(locale.read_text()).get("whatsNew", "").strip(), f"Missing release notes: {locale.name}")
        asc("metadata", "validate", "--dir", metadata)
        version = self.version(required=False)
        if version is None:
            asc("versions", "create", "--app", r["appID"], "--version", r["version"],
                "--platform", "IOS", "--release-type", "MANUAL")
            version = self.version()
        require(version["attributes"]["appStoreState"] in EDITABLE, "Version is not editable; inspect status")
        asc("versions", "update", "--version-id", version["id"], "--release-type", "MANUAL")
        asc("metadata", "push", "--app", r["appID"], "--version", r["version"], "--platform", "IOS", "--dir", metadata)
        asc("versions", "attach-build", "--version-id", version["id"], "--build-id", r["buildID"])
        if screenshots:
            for device in ("IPHONE_69", "IPAD_PRO_3GEN_129"):
                asc("screenshots", "upload", "--app", r["appID"], "--version-id", version["id"],
                    "--platform", "IOS", "--path", ROOT / "Distribution/AppStore/screenshots/marketing",
                    "--device-type", device, "--skip-existing")
        version = self.version()
        self.attached(version)
        require(version["attributes"]["releaseType"] == "MANUAL", "Manual publication was not retained")
        self.checkpoint(versionID=version["id"], phase="prepared")
        self.validate(version)

    def submit(self):
        r = self.receipt
        self.remote_build()
        ensure_tag(build_tag(r), r, create=False)
        version = self.version()
        self.attached(version)
        state = version["attributes"]["appStoreState"]
        if state in IN_REVIEW | PUBLISHED | {"PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "PROCESSING_FOR_APP_STORE"}:
            print(f"Already submitted: {state}")
            return
        require(state in EDITABLE | {"READY_FOR_REVIEW"}, f"Cannot submit state {state}")
        require(version["attributes"].get("releaseType") == "MANUAL", "Expected MANUAL release; run prepare")
        self.validate(version)
        submissions = asc("review", "submissions-list", "--app", r["appID"], "--platform", "IOS", "--paginate")["data"]
        active = [s for s in submissions if s["attributes"]["state"] != "COMPLETE"]
        require(len(active) <= 1, "Multiple active submissions; inspect their items before continuing")
        if active:
            submission = active[0]
            require(submission["attributes"]["state"] == "READY_FOR_REVIEW", "Existing submission is not an editable draft")
        else:
            submission = asc("review", "submissions-create", "--app", r["appID"], "--platform", "IOS")["data"]
        sid = submission["id"]
        items = asc("review", "items", "list", "--submission", sid, "--fields", "state,appStoreVersion",
                    "--include", "appStoreVersion", "--paginate")["data"]
        if not items:
            asc("review", "items", "add", "--submission", sid, "--item-type", "appStoreVersions", "--item-id", version["id"])
            items = asc("review", "items", "list", "--submission", sid, "--fields", "state,appStoreVersion",
                    "--include", "appStoreVersion", "--paginate")["data"]
        require(len(items) == 1 and (items[0].get("relationships", {}).get("appStoreVersion", {}).get("data") or {}).get("id") == version["id"],
                "Draft contains other items; refusing to submit unrelated content")
        self.checkpoint(submissionID=sid, phase="submitting")
        asc("review", "submissions-submit", "--id", sid, "--confirm")
        self.status()

    def status(self):
        version = self.version(required=False)
        if version:
            self.attached(version)
            state = version["attributes"]["appStoreState"]
            self.checkpoint(observedState=state)
            print(json.dumps(dict(version=self.receipt["version"], build=self.receipt["build"],
                                  state=state, releaseType=version["attributes"].get("releaseType")), indent=2))
        else:
            print("No App Store version yet")
        return version

    def release(self):
        ensure_tag(build_tag(self.receipt), self.receipt, create=False)
        version = self.version()
        self.attached(version)
        state = version["attributes"]["appStoreState"]
        if state in PUBLISHED:
            self.finalize()
            return
        if state in {"PENDING_APPLE_RELEASE", "PROCESSING_FOR_APP_STORE"}:
            print(f"Publication is pending: {state}; run finalize once published")
            return
        require(state == "PENDING_DEVELOPER_RELEASE", f"Not approved for manual release: {state}")
        require(not self.receipt.get("releaseRequestedAt"),
                "Release was already attempted; inspect server state before retrying (see recovery prompt)")
        self.checkpoint(releaseRequestedAt=now(), phase="releasing")
        asc("versions", "release", "--version-id", version["id"], "--confirm")
        version = self.status()
        if version["attributes"]["appStoreState"] in PUBLISHED:
            self.finalize()
        else:
            print("Release requested; run finalize when Apple reports publication")

    def finalize(self):
        version = self.version()
        self.attached(version)
        require(version["attributes"]["appStoreState"] in PUBLISHED, "Apple has not reported publication yet")
        ensure_tag(build_tag(self.receipt), self.receipt, create=False)
        ensure_tag(release_tag(self.receipt), self.receipt)
        self.checkpoint(phase="published", versionID=version["id"], publishedObservedAt=now())
        print(f'Published: {release_tag(self.receipt)}')

    def push_tags(self):
        tags = [build_tag(self.receipt)]
        ensure_tag(tags[0], self.receipt, create=False)
        if self.receipt.get("phase") == "published":
            ensure_tag(release_tag(self.receipt), self.receipt, create=False)
            tags.append(release_tag(self.receipt))
        git("push", "--atomic", "origin", *[f"refs/tags/{t}:refs/tags/{t}" for t in tags])
        print("Pushed " + ", ".join(tags))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["record", "mark-uploading", "reconcile", "prepare", "validate", "submit", "status", "release", "finalize", "push-tags"])
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--screenshots", action="store_true", help="prepare: upload missing marketing screenshots")
    parser.add_argument("--archive", help=argparse.SUPPRESS)
    parser.add_argument("--ipa", help=argparse.SUPPRESS)
    parser.add_argument("--commit", help=argparse.SUPPRESS)
    parser.add_argument("--dirty", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--skip-tests", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    os.umask(0o077)
    if args.action == "record":
        require(args.archive and args.ipa and args.commit, "record requires archive, IPA, commit")
        record(args)
        return
    # Serialize attempts for the same binary, including retries after partial success.
    lock_path = artifact_dir(args.version, args.build) / "workflow.lock"
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        execute(args)


def execute(args):
    release = Release(args.version, args.build)
    if args.action == "mark-uploading":
        require(release.receipt["phase"] == "exported", "Upload already attempted; use reconcile")
        require(git("rev-parse", "HEAD") == release.receipt["sourceCommit"] and not git("status", "--porcelain"),
                "Source changed before upload")
        existing = asc("builds", "list", "--app", release.receipt["appID"], "--version", args.version,
                       "--build-number", args.build, "--platform", "IOS", "--processing-state", "all", "--paginate")["data"]
        require(not existing, "Remote build number already exists; do not associate a new archive with it")
        release.checkpoint(phase="uploading", uploadAttemptedAt=now())
    elif args.action == "prepare":
        release.prepare(screenshots=args.screenshots)
    elif args.action == "validate":
        version = release.version()
        release.attached(version)
        release.validate(version)
    else:
        getattr(release, args.action.replace("-", "_"))()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"Error: {error}\nAfter a failed mutation inspect status before retrying. See docs/ios-release.md.", file=sys.stderr)
        sys.exit(1)
