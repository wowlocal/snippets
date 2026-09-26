# iOS / iPadOS release workflow

One universal binary serves iPhone and iPad. macOS and iOS release independently.
The scripts use the installed `asc` CLI (verified with 3.7.0), Python 3, Git and Xcode.
Credentials stay in `~/.config/snippets/app-store-connect.env`; the shared loader
checks permissions and never prints the private key. `SNIPPETS_ASC_CONFIG` overrides it.

## Agent entry points

Copy a prompt from [the release prompts](prompts/ios-release.md):

- **Prepare and submit an update:** version, release notes, tests, upload, metadata,
  browser remediation if needed, App Review, and remote build tag.
- **Publish an approved update:** release the already approved binary, verify Apple's
  publication state, and create/push the release tag.
- **Browser handoff:** handle a specific Apple web-only blocker and return to scripts.
- **Recover an interrupted operation:** inspect before retrying; never rebuild silently.

The reusable entry point is [release-snippets-ios](../skills/release-snippets-ios/SKILL.md).
Invoking a submit prompt authorizes the listed upload, metadata, privacy and review
operations; it does not publish the app after approval. Invoking the publication
prompt authorizes that separate step. No extra confirmation is needed for actions
already requested in the chosen prompt.

## Versions and tags

`MARKETING_VERSION` is the App Store version; `CURRENT_PROJECT_VERSION` is a local
build-number floor. The upload script resolves a newer unused number from Apple.
Keep the marketing version stable while replacing review candidates; increase the
build number. Change the iOS version independently:

```sh
python3 scripts/project-version.py ios --set 1.3.123
# Or, for the following update:
python3 scripts/project-version.py ios --bump patch
```

Commit the project and release metadata before archiving. `Distribution/BumpVersion`
now edits only the macOS target; its existing `vX.Y.Z` tags remain unchanged.

| Tag | Created when | Meaning |
| --- | --- | --- |
| `ios/build/X.Y.Z-N` | Apple processed the upload as VALID | Exact source and binary uploaded |
| `ios/vX.Y.Z` | Apple reports READY_FOR_SALE / READY_FOR_DISTRIBUTION | Published build for this version |

Both are annotated, immutable tags on the **archive's source commit**, even if HEAD
has since moved. Their annotations include version, build, source SHA, IPA SHA-256,
App Store app ID and build resource ID. Tags are local until `push-tags` succeeds;
that command pushes only the selected tags to `origin`, without force. The remote
can then resolve their source commit even if no branch points to it yet.

## Archive and upload

```sh
./scripts/testflight-ios.sh --check
./scripts/testflight-ios.sh --upload --uses-non-exempt-encryption false
```

Verify the encryption answer against `snippets-ios/Info-iOS.plist` and the current
product before using it. The example matches the current declared value.
Use `--group "Internal Testers"` for an internal group. External beta review remains
in the skill reference. Full preflight runs Core tests, a macOS build, and iPhone /
iPad simulator tests. Missing simulator runtimes are a real preflight failure;
install a compatible runtime instead of silently adding `--skip-tests`.

Uploads require a clean worktree. `--allow-dirty` is restricted to local `--archive`
experiments; such receipts cannot be tagged or used by the release workflow.

After signed IPA/profile verification and **before upload**, the script preserves:

```text
~/.local/share/snippets/releases/ios/X.Y.Z/N/
  Snippets.xcarchive/       # includes dSYM files
  Snippets.ipa
  release.json             # source, checksums, tools, test outcome, Apple IDs/state
  readiness.json           # created by prepare/validate/submit
```

Set `SNIPPETS_IOS_RELEASES_DIR` to choose another persistent location. Keep it outside
the checkout. Back up this directory; IPA and dSYM are not committed to Git.
`--keep-artifacts` additionally retains temporary derived data and signing diagnostics.
An existing version/build directory is never overwritten. `--archive` also retains
its artifacts but does not create a tag or imply an upload; use a fresh build number
for a subsequent upload. Old pre-workflow uploads have no trustworthy source receipt:
do not manufacture a tag for them from today's HEAD.

## Prepare the App Store page

Write `Distribution/AppStore/metadata/version/X.Y.Z/en-US.json` and `ru.json` before
upload. Start with the prior version's fields, review them against current behavior,
and add truthful `whatsNew` in both languages. Commit these files with the release
source. Do not silently copy old release notes. App-info metadata lives alongside
version metadata. Review contacts and demo credentials remain private in Apple.

Use the **actual build number printed by the upload**, not the project floor:

```sh
./scripts/app-store-ios.sh prepare --version 1.3.123 --build 125
# Include missing screenshots from the existing marketing assets when appropriate:
./scripts/app-store-ios.sh prepare --version 1.3.123 --build 125 --screenshots
./scripts/app-store-ios.sh validate --version 1.3.123 --build 125
```

`prepare` validates the receipt and remote build, creates/reuses the editable iOS
version, sets MANUAL release, syncs metadata without deleting locales, attaches the
exact build and runs readiness checks. Screenshot upload uses checksum-based
`--skip-existing`; replacing an existing screenshot set is a deliberate separate
operation, not an automatic delete. Inspect inherited screenshots and regenerate
with `scripts/generate-app-store-screenshots.sh` when the UI has changed.

`validate` retains the report and blocks on errors or blocking checks. Warnings
remain visible for the agent to resolve or explain. It cannot prove that App Privacy
has been published. Use the web-session helper when the current declaration needs
updating and the session is authenticated:

```sh
./scripts/app-store-privacy.sh plan
./scripts/app-store-privacy.sh apply
./scripts/app-store-privacy.sh publish
```

`apply` changes only the draft; `publish` is an explicit separate action. Review the
plan and local privacy declaration before publication. The helper never deletes
remote declarations automatically. Use the browser prompt for login/2FA, publishing
privacy when the web-session CLI cannot do it, or other API gaps. A new legal
agreement, tax declaration, or unknown product/compliance fact needs the user's input.
Do not invent those answers to get past a blocker.

## Submit, inspect, publish

```sh
./scripts/app-store-ios.sh submit --version 1.3.123 --build 125
./scripts/app-store-ios.sh status --version 1.3.123 --build 125
./scripts/app-store-ios.sh push-tags --version 1.3.123 --build 125
```

Submission reuses a matching draft after partial success. It refuses drafts with
unrelated items and never cancels an active review. The lower-level review commands
are used because `asc publish appstore` requires an IPA upload/local build; we submit
the already tested build without uploading it again. A successful HTTP response alone
is not proof of WAITING_FOR_REVIEW: inspect status, including after a timeout.
If Apple has already started review or approved this exact build, do not resubmit it.

Once approved and publication is requested:

```sh
./scripts/app-store-ios.sh release --version 1.3.123 --build 125
# Apple may process publication asynchronously. Run after it reports publication:
./scripts/app-store-ios.sh finalize --version 1.3.123 --build 125
./scripts/app-store-ios.sh push-tags --version 1.3.123 --build 125
```

`release` only requests publication from PENDING_DEVELOPER_RELEASE. `finalize` only
creates the release tag once Apple reports publication, and checks the attached
build again. Storefront availability may propagate later; report that separately.

## Recovery

- Upload response lost: use `reconcile --version X.Y.Z --build N`. It resolves the
  exact remote pair, requires VALID, verifies the local IPA and creates the missing
  tag. It requires a recorded upload attempt; an unuploaded archive is not evidence.
- Processing pending: inspect `asc builds` and retry reconcile after processing.
  No automatic second upload. Failed/reserved numbers require a new build number.
- Prepare failed: fix the reported field/session and rerun prepare. It reuses the
  existing version and attaches the same build.
- Submit response lost: inspect status, then rerun submit only if needed. It reuses
  the single draft, verifies all its items, and recognizes already-submitted states.
- Release response lost: the receipt keeps `releaseRequestedAt`. Do not remove it
  merely to retry. Inspect Apple via API/browser. If Apple definitively did not accept
  the request and the version still awaits developer release, the agent can retry
  the exact `asc versions release --version-id … --confirm` within the user's existing
  publication authorization, then run finalize. Never claim success while uncertain.
- Tag push failed: rerun push-tags; do not re-upload or replace tags. A conflicting
  remote tag requires investigation.

Per-build actions take a nonblocking local lock. Keep one uploader per app/version;
Apple's build-number query is not a distributed reservation across machines.

## Verification of the automation

```sh
python3 scripts/test-ios-release.py
bash -n scripts/testflight-ios.sh scripts/app-store-ios.sh scripts/app-store-privacy.sh \
  scripts/lib/asc-common.sh Distribution/BumpVersion Distribution/common.sh
```

Tests use temporary Git repositories and fake Apple responses. They cover platform
version independence, tag provenance/conflicts, tampered artifacts, partial submission
recovery, unrelated drafts, readiness failures and delayed publication. They do not
upload a build or exercise Apple's live mutation endpoints.

Apple references: [upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds),
[submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app),
[manual release](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option),
[App Privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy).
