# App Store Connect operations

Use these direct `asc` workflows only after reading the release skill's safety rules. Run `asc <command> --help` before adapting them to a newer CLI.

## Contents

- [Authenticated command wrapper](#authenticated-command-wrapper)
- [Add a processed build to a public beta](#add-a-processed-build-to-a-public-beta)
- [Replace the build in a pending App Store release](#replace-the-build-in-a-pending-app-store-release)

## Authenticated command wrapper

Load the repository's private configuration without printing it:

```sh
set -a
source "${SNIPPETS_ASC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/snippets/app-store-connect.env}"
set +a
export ASC_KEY_PATH="$ASC_PRIVATE_KEY_PATH"

asc_snippets() {
  env \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    -u http_proxy -u https_proxy -u all_proxy \
    ASC_STRICT_AUTH=true \
    asc "$@"
}
```

Keep IDs in local shell variables and show only the minimum status fields needed for verification.

## Add a processed build to a public beta

1. List external groups and select exactly one intended group:

```sh
asc_snippets testflight groups list \
  --app "$ASC_APP_ID" \
  --external \
  --paginate \
  --output json
```

2. Resolve the target build by marketing version, build number, platform, and `VALID` processing state:

```sh
asc_snippets builds list \
  --app "$ASC_APP_ID" \
  --version "$release_version" \
  --build-number "$build_number" \
  --platform IOS \
  --processing-state VALID \
  --output json
```

3. Add only the external group and submit for Beta App Review:

```sh
asc_snippets builds add-groups \
  --build-id "$build_id" \
  --group "$external_group_id" \
  --skip-internal \
  --submit \
  --confirm \
  --output json
```

4. Verify both review and distribution state:

```sh
asc_snippets testflight review submissions list \
  --build-id "$build_id" \
  --output json

asc_snippets testflight distribution view \
  --build-id "$build_id" \
  --output json

asc_snippets testflight groups links view \
  --group-id "$external_group_id" \
  --type builds \
  --paginate \
  --output json
```

Report `APPROVED` and `IN_BETA_TESTING` only when the API returns those states. Public-link enablement belongs to the external group, not the build.

## Replace the build in a pending App Store release

Apple does not permit an in-place build swap after submission. Cancel the exact submission, attach the new build, and resubmit. This restarts the App Review queue but does not remove the build from TestFlight.

1. Resolve the version and confirm its current build:

```sh
asc_snippets versions list \
  --app "$ASC_APP_ID" \
  --version "$release_version" \
  --platform IOS \
  --output json

asc_snippets versions view \
  --version-id "$version_id" \
  --include-build \
  --include-submission \
  --output json
```

2. Resolve the active review submission and inspect its items. Cancel only after its `appStoreVersion` relationship equals `version_id`:

```sh
asc_snippets review submissions-list \
  --app "$ASC_APP_ID" \
  --platform IOS \
  --output json

asc_snippets review items list \
  --submission "$submission_id" \
  --fields state,appStoreVersion \
  --include appStoreVersion \
  --output json

asc_snippets review submissions-cancel \
  --id "$submission_id" \
  --confirm \
  --output json
```

3. Poll the submission until `CANCELING` becomes `COMPLETE`. Confirm the app version becomes editable, normally `DEVELOPER_REJECTED`, before attaching the new build:

```sh
asc_snippets versions attach-build \
  --version-id "$version_id" \
  --build-id "$build_id" \
  --output json
```

4. For builds recorded by the new workflow, use the resumable submission command:

```sh
./scripts/app-store-ios.sh submit --version "$release_version" --build "$build_number"
```

It validates readiness, reuses a single matching draft, verifies all its items, and
submits it. For historical builds without a trustworthy receipt, use the explicit
`asc review submissions-list`, `review items list`, `review submissions-create`,
`review items add`, and `review submissions-submit` commands after checking their
current `--help`. Resolve every ID from Apple, reuse an existing matching draft, and
verify that its only item is the intended app version before submitting. Do not invent
a source receipt or tag for an old binary.

5. If a mutation fails, query submissions and items before retrying. The draft or item
may already exist despite a lost response.

6. Verify `versions view --include-build --include-submission` reports the intended build and `WAITING_FOR_REVIEW`. Recheck TestFlight distribution if public beta availability must remain active.

For any DNS, TLS, timeout, or unexpected-EOF error during a mutation, query server state before retrying. Never assume a failed client response means Apple rejected the operation.
