#!/usr/bin/env python3
"""Offline workflow tests. All Apple calls are fake; Git runs in temporary repositories."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load("ios_release", ROOT / "scripts/lib/ios_release.py")
versions = load("project_version", ROOT / "scripts/project-version.py")


class PlatformVersions(unittest.TestCase):
    def test_each_platform_update_preserves_other_target_and_project_structure(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "project.pbxproj"
            shutil.copyfile(versions.PROJECT, path)
            mac_before = versions.configurations(path, "macos")[1]
            versions.update(path, "ios", "2.0.0", "200")
            self.assertEqual(versions.configurations(path, "macos")[1], mac_before)
            self.assertEqual(versions.configurations(path, "ios")[1], ("2.0.0", "200"))
            versions.update(path, "macos", "3.0.0", "300")
            self.assertEqual(versions.configurations(path, "ios")[1], ("2.0.0", "200"))
            self.assertEqual(versions.configurations(path, "macos")[1], ("3.0.0", "300"))

    def test_macos_bump_script_commits_and_tags_only_macos_version(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for file in ("Snippets.xcodeproj/project.pbxproj", "Distribution/BumpVersion", "scripts/project-version.py"):
                target = root / file
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / file, target)
            def git(*args):
                return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()
            git("init", "-q")
            git("config", "user.name", "Workflow Test")
            git("config", "user.email", "test@example.invalid")
            git("config", "commit.gpgsign", "false")
            git("add", ".")
            git("commit", "-qm", "initial")
            path = root / "Snippets.xcodeproj/project.pbxproj"
            ios_before = versions.configurations(path, "ios")[1]
            before = git("rev-parse", "HEAD")
            version = subprocess.check_output(["bash", str(root / "Distribution/BumpVersion"), "patch"], text=True).strip()
            self.assertEqual(versions.configurations(path, "ios")[1], ios_before)
            self.assertEqual(versions.configurations(path, "macos")[1][0], version)
            self.assertNotEqual(git("rev-parse", "HEAD"), before)
            self.assertEqual(git("rev-parse", "v" + version), git("rev-parse", "HEAD"))
            self.assertEqual(git("status", "--porcelain"), "")


class Workflow(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        for key, value in (("user.name", "Workflow Test"), ("user.email", "test@example.invalid")):
            subprocess.run(["git", "-C", str(self.root), "config", key, value], check=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "source"], check=True)
        self.enter(patch.object(release, "ROOT", self.root))
        self.enter(patch.dict(os.environ, {"ASC_APP_ID": "123", "SNIPPETS_IOS_RELEASES_DIR": str(self.root / "artifacts")}))
        self.directory = release.artifact_dir("1.2.3", "12")
        self.directory.mkdir(parents=True)
        (self.directory / "Snippets.ipa").write_bytes(b"test binary")
        self.receipt = dict(schema=1, version="1.2.3", build="12", appID="123", bundleID=release.BUNDLE,
                            sourceCommit=release.git("rev-parse", "HEAD"), dirty=False, signedArtifactVerified=True,
                            ipaSHA256=release.sha256(self.directory / "Snippets.ipa"), phase="uploading")
        release.save(self.directory / "release.json", self.receipt)
        self.state = "PREPARE_FOR_SUBMISSION"
        self.attached = "build1"
        self.active = []
        self.items = []
        self.calls = []
        self.summary = dict(errors=0, warnings=0, blocking=0)
        self.fail_after_add = False
        self.version_exists = True
        self.view_version = "1.2.3"
        self.enter(patch.object(release, "asc", self.asc))
        self.enter(contextlib.redirect_stdout(io.StringIO()))

    def enter(self, manager):
        value = manager.__enter__()
        self.addCleanup(manager.__exit__, None, None, None)
        return value

    def asc(self, *args):
        self.calls.append(args)
        command = args[:2]
        if command == ("apps", "list"):
            return {"data": [{"id": "123", "attributes": {"bundleId": release.BUNDLE}}]}
        if command == ("builds", "list"):
            return {"data": [{"id": "build1", "attributes": {"processingState": "VALID", "expired": False}}]}
        if command == ("versions", "list"):
            return {"data": [{"id": "version1", "attributes": {
                "appStoreState": self.state, "releaseType": "MANUAL"},
                "relationships": {"build": {"links": {"related": "unused"}}}}
                ] if self.version_exists else []}
        if command == ("versions", "view"):
            return {"id": "version1", "versionString": self.view_version, "platform": "IOS",
                    "state": self.state, "buildId": self.attached}
        if args[0] == "validate":
            return {"summary": self.summary}
        if command == ("versions", "create"):
            self.version_exists = True
            return {"data": {"id": "version1"}}
        if command == ("versions", "update"):
            return {}
        if command == ("versions", "attach-build"):
            self.attached = args[args.index("--build-id") + 1]
            return {}
        if command in {("metadata", "validate"), ("metadata", "push"), ("screenshots", "upload")}:
            return {}
        if command == ("review", "submissions-list"):
            return {"data": self.active}
        if command == ("review", "submissions-create"):
            self.active = [{"id": "submission1", "attributes": {"state": "READY_FOR_REVIEW"}}]
            return {"data": self.active[0]}
        if args[:3] == ("review", "items", "list"):
            return {"data": self.items}
        if args[:3] == ("review", "items", "add"):
            self.items = [{"relationships": {"appStoreVersion": {"data": {"id": "version1"}}}}]
            if self.fail_after_add:
                self.fail_after_add = False
                raise OSError("simulated lost response after Apple accepted item")
            return {}
        if command == ("review", "submissions-submit"):
            self.state = "WAITING_FOR_REVIEW"
            self.active[0]["attributes"]["state"] = "WAITING_FOR_REVIEW"
            return {}
        if command == ("versions", "release"):
            self.state = "PROCESSING_FOR_APP_STORE"
            return {}
        raise AssertionError(f"Unexpected Apple call: {args}")

    def processed(self):
        r = release.Release("1.2.3", "12")
        r.reconcile()
        return r

    def test_git_is_confined_to_the_temporary_repository(self):
        self.assertEqual(Path(release.git("rev-parse", "--show-toplevel")).resolve(), self.root.resolve())

    def test_cli_summary_preserves_release_policy_and_resolves_attached_build(self):
        r = self.processed()
        version = r.version()
        self.assertEqual(version["attributes"]["releaseType"], "MANUAL")
        self.assertEqual(version["relationships"]["build"]["data"]["id"], "build1")
        self.attached = None
        self.assertIsNone(r.version()["relationships"]["build"]["data"])

    def test_cli_summary_for_another_version_cannot_authorize_submission(self):
        r = self.processed()
        self.view_version = "9.9.9"
        with self.assertRaisesRegex(ValueError, "summary identity mismatch"):
            r.submit()
        self.assertFalse(any(c[0] == "review" for c in self.calls))

    def test_prepare_creates_once_and_reattaches_exact_build(self):
        r = self.processed()
        directory = self.root / "Distribution/AppStore/metadata/version/1.2.3"
        directory.mkdir(parents=True)
        for locale in ("en-US", "ru"):
            (directory / (locale + ".json")).write_text(json.dumps({"whatsNew": "Verified release notes"}))
        self.version_exists = False
        self.attached = None
        r.prepare(screenshots=True)
        r.prepare()
        self.assertEqual(self.attached, "build1")
        self.assertEqual(sum(c[:2] == ("versions", "create") for c in self.calls), 1)
        self.assertEqual(sum(c[:2] == ("screenshots", "upload") for c in self.calls), 2)
        self.assertFalse(any(c[0] == "review" for c in self.calls))

    def test_reconcile_does_not_erase_published_phase(self):
        r = self.processed()
        r.checkpoint(phase="published")
        r.reconcile()
        self.assertEqual(r.receipt["phase"], "published")

    def test_push_tags_transfers_only_selected_tag_and_original_source(self):
        r = self.processed()
        bare = self.root / "remote.git"
        subprocess.run(["git", "init", "--bare", "-q", str(bare)], check=True)
        release.git("remote", "add", "origin", str(bare))
        r.push_tags()
        self.assertEqual(subprocess.check_output(["git", "--git-dir", str(bare), "rev-parse",
                                                 release.build_tag(r.receipt) + "^{commit}"], text=True).strip(),
                         self.receipt["sourceCommit"])
        self.assertEqual(subprocess.check_output(["git", "--git-dir", str(bare), "tag"], text=True).strip(),
                         release.build_tag(r.receipt))

    def test_reconcile_tags_original_commit_and_is_repeatable(self):
        r = self.processed()
        r.reconcile()
        self.assertEqual(release.git("rev-parse", release.build_tag(r.receipt) + "^{commit}"), self.receipt["sourceCommit"])
        annotation = json.loads(release.git("for-each-ref", "--format=%(contents)", "refs/tags/" + release.build_tag(r.receipt)))
        self.assertEqual(annotation["buildID"], "build1")
        self.assertEqual(annotation["ipaSHA256"], self.receipt["ipaSHA256"])

    def test_modified_ipa_or_dirty_archive_cannot_be_released(self):
        (self.directory / "Snippets.ipa").write_bytes(b"different binary")
        with self.assertRaisesRegex(ValueError, "checksum"):
            release.Release("1.2.3", "12")
        self.receipt["dirty"] = True
        release.save(self.directory / "release.json", self.receipt)
        with self.assertRaisesRegex(ValueError, "clean"):
            release.Release("1.2.3", "12")

    def test_archive_without_upload_intent_cannot_claim_remote_build(self):
        self.receipt["phase"] = "exported"
        release.save(self.directory / "release.json", self.receipt)
        with self.assertRaisesRegex(ValueError, "upload attempt"):
            release.Release("1.2.3", "12").reconcile()

    def test_tag_cannot_be_overwritten_even_on_same_commit(self):
        r = self.processed()
        conflicting = dict(r.receipt, ipaSHA256="other")
        with self.assertRaisesRegex(ValueError, "different ipaSHA256"):
            release.ensure_tag(release.build_tag(r.receipt), conflicting)

    def test_submit_reuses_draft_after_lost_response(self):
        r = self.processed()
        self.fail_after_add = True
        with self.assertRaises(OSError):
            r.submit()
        r.submit()
        r.submit()
        self.assertEqual(self.state, "WAITING_FOR_REVIEW")
        self.assertEqual(sum(c[:2] == ("review", "submissions-create") for c in self.calls), 1)
        self.assertEqual(sum(c[:3] == ("review", "items", "add") for c in self.calls), 1)
        self.assertEqual(sum(c[:2] == ("review", "submissions-submit") for c in self.calls), 1)

    def test_unrelated_draft_is_never_submitted(self):
        r = self.processed()
        self.active = [{"id": "other", "attributes": {"state": "READY_FOR_REVIEW"}}]
        self.items = [{"relationships": {"appStoreVersion": {"data": {"id": "another-version"}}}}]
        with self.assertRaisesRegex(ValueError, "other items"):
            r.submit()
        self.assertFalse(any(c[:2] == ("review", "submissions-submit") for c in self.calls))

    def test_validation_errors_block_submission_and_save_report(self):
        r = self.processed()
        self.summary = dict(errors=1, blocking=1)
        with self.assertRaisesRegex(ValueError, "Readiness"):
            r.submit()
        self.assertTrue((self.directory / "readiness.json").exists())
        self.assertFalse(any(c[0] == "review" for c in self.calls))

    def test_null_or_wrong_attached_build_blocks_submission(self):
        r = self.processed()
        for attached in (None, "other"):
            self.attached = attached
            with self.assertRaisesRegex(ValueError, "different build"):
                r.submit()
        self.assertFalse(any(c[0] == "review" for c in self.calls))

    def test_publication_tag_waits_for_apple_and_never_rebuilds(self):
        r = self.processed()
        self.state = "PENDING_DEVELOPER_RELEASE"
        r.release()
        self.assertEqual(self.state, "PROCESSING_FOR_APP_STORE")
        self.assertEqual(release.git("tag", "--list", "ios/v*"), "")
        r.release()
        self.assertEqual(sum(c[:2] == ("versions", "release") for c in self.calls), 1)
        self.state = "READY_FOR_SALE"
        r.finalize()
        r.finalize()
        self.assertEqual(release.git("tag", "--list", "ios/v*"), "ios/v1.2.3")

    def test_uncertain_release_is_not_blindly_retried(self):
        r = self.processed()
        self.state = "PENDING_DEVELOPER_RELEASE"
        r.checkpoint(releaseRequestedAt=release.now())
        with self.assertRaisesRegex(ValueError, "already attempted"):
            r.release()
        self.assertFalse(any(c[:2] == ("versions", "release") for c in self.calls))


if __name__ == "__main__":
    unittest.main()
