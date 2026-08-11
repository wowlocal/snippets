---
name: release-snippets-ios
description: Build, validate, upload, distribute, and resubmit the Snippets universal iOS app through TestFlight and App Store Connect. Use for TestFlight builds, internal or public beta groups, export compliance, Beta App Review, App Store submissions, or replacing the build attached to a pending iOS release.
---

# Release Snippets iOS

Ship the universal iPhone/iPad target with the repository's signing checks, then manage its TestFlight or App Store state without exposing credentials or accidentally duplicating submissions.

## Start safely

1. Read `AGENTS.md` and work from the repository root.
2. Treat uploads, tester distribution, review cancellation, and review submission as external mutations. Perform them only when the user explicitly requests them.
3. Check `git status --short`. Require a clean worktree for upload unless the user explicitly accepts `--allow-dirty`.
4. Never print, commit, or copy the contents of `Distribution/.env`, the App Store Connect configuration, or its private key.
5. Inspect current App Store Connect state immediately before a mutation. Resolve app, version, build, submission, and group IDs from the API instead of reusing remembered IDs.

## Choose the workflow

- For credentials, identity, and the next build number, run `./scripts/testflight-ios.sh --check`.
- For a normal TestFlight upload, use the repository script. It archives Release, exports the IPA, validates the signed artifact, uploads it, waits for processing, and records export compliance.
- For an internal group, pass `--group`. The script deliberately searches internal groups only.
- For an external/public group or App Store review operation, first complete the upload, then read [references/app-store-connect.md](references/app-store-connect.md).
- For status-only requests, use read-only `asc` queries and do not alter distribution or review state.

## Upload a build

Use the full preflight by default:

```sh
./scripts/testflight-ios.sh \
  --upload \
  --uses-non-exempt-encryption false
```

Add `--group "Internal Testers"` only for an existing internal group. Add `--skip-tests` only when the user explicitly requests skipping preflight or equivalent tests already passed elsewhere.

Do not infer export compliance from memory. Confirm `ITSAppUsesNonExemptEncryption` in `snippets-ios/Info-iOS.plist`; pass the matching answer. The current value is `false`.

If upload fails during DNS, TLS, or object-storage transfer:

1. Keep the retained artifacts.
2. Query App Store Connect before retrying; a timed-out mutation may have succeeded.
3. Run `./scripts/testflight-ios.sh --check` again. Apple may reserve the failed build number even when no usable build appears in `asc builds list`.
4. Let the script choose the next unused build number unless the user requires a specific number.

## Verify the result

Require all applicable facts before reporting success:

- the processed build state is `VALID`;
- export compliance is resolved;
- the signed IPA passed the repository's entitlement and provisioning checks;
- the intended TestFlight group contains the build;
- external distribution is `IN_BETA_TESTING` when public testing was requested;
- the App Store version shows the intended build and `WAITING_FOR_REVIEW` when an App Store resubmission was requested.

Keep marketing version and build number distinct. Replacing build 73 with build 75 for version 1.3.71 does not require creating version 1.3.72. App Store Connect's sidebar displays the marketing version, not the internal build number.
