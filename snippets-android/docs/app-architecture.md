# App architecture (`:app`)

How the Android app is put together, and the patterns every screen follows. The design
specification (`design/DESIGN.md` and the screen files) says *what* the app does; this file says
*where* code goes and *how* it talks. Package root: `com.khm.snippets.android`.

## Layers and packages

| Package | Holds | May depend on |
|---|---|---|
| `data` | Contracts: interfaces and immutable models (`LibraryRepository`, `SecureVault`, `SyncController`, `LibraryQueryEngine`, `SnippetResolver`, `KeywordAdvisor`, `AppSettings`, `Outcome`, typed errors). No Android UI types, no strings. | `:core` (`core.model`, `core.search`, `core.text`, `core.clock`) |
| `data.core` | Contract implementations that are real today because `:core` already has the logic: `CoreLibraryQueryEngine`, `CoreSnippetResolver`, `CoreKeywordAdvisor`, `ContentMatch`. | `data`, `:core` |
| `data.fake` | Deterministic in-memory fakes of the contracts `:core` cannot back yet (`FakeLibraryRepository` over `FakeLibraryStore`, `FakeSecureVault`, `FakeSyncController`, `FakeAppSettings`), wired together by `FakeBackends`. | `data`, `platform` |
| `platform` | Android services behind small interfaces: `ClipboardService` (sensitive flag, timed clear, `AlarmManager` backstop), `DeviceAuthenticator` (+ `FakeDeviceAuthenticator`), `TimeFormatter`, `ShareSheet`, `SecureWindowEffect` (`FLAG_SECURE`), `ScreenCaptureState`, `IcuDateRenderer`, keyboard shortcuts. | `data` |
| `app` | The shell: `AppContainer` (manual DI), `SnippetsApp` (root composable), `SnippetsNavHost`, `LaunchOptions`. Debug-only `LaunchOptionsReader` and `DemoLibrary` live in `src/debug`; `src/release` has a reader that ignores every extra. | everything |
| `nav` | Routes (`NavKey`s named as DESIGN §3), `AppNavigator`, `BackPolicy` (pure), `TwoPaneSceneStrategy`, `WindowLayout`, `PlaceholderScreen`. | `ui` |
| `feature.<name>` | One feature per package: `…Destination` (route entry), `…Screen` and its parts, `…ViewModel`, `…UiState` / `…Effect`, `…Actions`, mappers, `…Tags`. `feature.shared` holds what several features use (`AppDialog`, `UiText`, `SyncPresentation`, `SnippetOperations`, `AppSnackbars`, `EffectChannel`). | `data`, `platform`, `nav`, `ui` |
| `ui` | The component library, theme, icons and models (`SnippetRowUi`, `SecurePanelState`, …). Knows nothing about data or features. | — |

Rules: `ui` never imports `data`; `data` never imports Compose UI or resources; a feature never
reaches into another feature except through `feature.shared` or navigation.

## Naming

- Contracts are nouns (`SecureVault`); fakes are `Fake…`; `:core`-backed ones are `Core…`.
- Per screen: `XDestination`, `XScreen`, `XViewModel`, `XUiState`, `XEffect`, `XActions`, `XTags`.
- Routes: `XRoute`, `routeName` exactly as DESIGN §3 (`editor/{id}`, `settings/sync`).
- Strings: one resource file per area (`strings_library.xml`, `strings_editor.xml`,
  `strings_sync.xml`, `strings_shared.xml`, …), ids `<area>_<element>[_<variant>]`.

## State and effects

- A ViewModel exposes `uiState: StateFlow<XUiState>`: one immutable `@Immutable` data class,
  collected with `collectAsStateWithLifecycle()`.
- Text being typed is **snapshot state** on the ViewModel (`var query by mutableStateOf`,
  the editor's `EditorDraft`), never a StateFlow round trip: the keyboard must not wait.
- Events are functions of an `XActions` interface that the ViewModel implements; the screen
  takes it as one `@Stable` parameter (tests and previews pass their own).
- One-shot effects (navigate, snackbar, haptic, announce, share, focus) go through one
  mechanism: `EffectChannel<XEffect>` in the ViewModel, `CollectEffects(viewModel.effects)` in the
  destination (main-immediate, while started). Nothing one-shot is ever modelled as state.
- Snackbars are requested as `SnackbarRequest` effects and shown by the window's
  `LocalAppSnackbars`; Undo runs through the application-scoped `SnippetOperations`, so it works
  after the screen that raised it has gone.
- All user-facing text is a resource. ViewModels and mappers return `UiText` (resource id +
  arguments); composables resolve it. `UiText.Raw` is only for user data and system messages.
- Errors are typed (`LibraryError`, `VaultError`, `SyncError`); `feature.shared.ErrorText`
  and `Feedback` turn them into sentences and dialogs. A cancelled authentication is
  `VaultResult.Cancelled`, never an error, and is silent everywhere (D15).
- Long work is `suspend` and main-safe; CPU work goes to `AppDispatchers.default`. No
  `GlobalScope`, no `runBlocking`; work that must outlive a screen uses `AppContainer.appScope`.

## Navigation

- One Navigation 3 back stack of `Route`s (`rememberNavBackStack(RouteSavedStateConfiguration)`),
  saved across process death. Register every new route in `RouteSavedStateConfiguration`.
- Screens, panes and full-screen dialogs that may be restored are routes. Menus, sheets and
  alert dialogs are state of the screen that shows them (their root carries the route name as a
  test tag, `dialog.delete-secure`). Secret screens (recovery key) are app-scoped overlays, so
  a secret can never reach saved state.
- `TwoPaneSceneStrategy` shows a list entry and the newest detail entry side by side at
  ≥ 840 × 480 dp (`WindowLayout.isTwoPane`). The two-pane selection *is* the `EditorRoute` on
  top: rotating or resizing needs no translation.
- Back and Up call `AppNavigator.back(isTwoPane)`, which applies `BackPolicy` (DESIGN §3.3);
  screens add a `BackHandler` only for the transient states of rule 1–4 (open query, working
  dialog). The editor never intercepts back.
- `WindowLayout` comes from the size of the root, so tests force any window with
  `DeviceConfigurationOverride` instead of resizing the device.

## Adding a screen

1. Add the route (`@Serializable`, `routeName` from DESIGN §3) to `nav/Routes.kt` and to
   `RouteSavedStateConfiguration`; give it pane metadata (`Panes.list` / `Panes.detail`) if it
   is part of a two-pane layout.
2. Create `feature/<name>/`: `XUiState`, `XEffect`, `XActions`, `XViewModel` (with a
   `factory(container)`), `XScreen` (stateless: state + actions in), `XDestination` (ViewModel,
   effects, lifecycle), `XTags`.
3. Replace the `PlaceholderScreen` line in `app/SnippetsNavHost.kt` with the destination.
4. Strings in a new `strings_<name>.xml`; test tags from the screen file; components from
   `ui.components` (extend one only where the screen needs it, and keep its tests green).
5. Tests: ViewModel and mapper tests on the JVM against `FakeBackends`; an instrumented flow
   test through `AppHarness`.

## Testing

- **JVM** (`app/src/test`, `kotlinx-coroutines-test`): ViewModels with
  `Dispatchers.setMain(StandardTestDispatcher)`, virtual time for debounces and timers,
  `ViewModelStore().clear()` for `onCleared`. Android framework classes are not available:
  pass `PlatformInfo(sdkInt = …)`, a recording `SnippetClipboard`, a fixed `TimeFormatter`,
  `JvmDateRenderer` for the resolver.
- **Instrumented** (`app/src/androidTest`, `emulator-5556` only): `AppHarness` composes
  `SnippetsApp` on a fresh `AppContainer` per test with `DemoLibrary` seeded; window size and
  font scale are forced; process death is `StateRestorationTester` with a fresh
  `ViewModelStore`; `MainActivityTest` covers the real activity (extras, hardware keys through `onKeyDown`,
  recreation). `IcuDateRendererL05Test` runs the core L05 placeholder vectors on device ICU.
  Visual checks of `FLAG_SECURE` windows use `captureToImage()`.

## Fakes and how tests control them

`AppContainer.fakes` (`FakeBackends`) wires one `FakeLibraryStore` behind the repository and
the vault, plus:

| Control | Effect |
|---|---|
| `fakes.seed(entries)` / `DemoLibrary.standard()` | Replace the library; a secure entry brings a locked vault |
| `fakes.controls.latencyMillis` | Delay of every repository, vault and sync call (virtual time under a test dispatcher) |
| `fakes.controls.writeError` / `saveError` | Writes fail and change nothing / edits stay in memory but saving reports the error |
| `fakes.authenticator.answer`, `holdNext()`, `requests`, `isDeviceSecure` | Prompt outcome, keep a prompt "on screen", recorded prompts, no screen lock |
| `fakes.vault.setVault(…)`, `setUnreadable`, `gitVaultSetupRequired`, `syncIsOn`, `nextRecoveryKey` | Vault states and setup |
| `fakes.sync.connect(provider)`, `setStatus(…)`, `nextRoundState`, `manualRounds` | Any sync state, the result of the next round, counters |
| `fakes.store.setAvailability(…)` | Loading or quarantined library |
| `clipboard.secureClipLifetimeMillis` | Shorter secure-clip lifetime |

Debug launch extras (`LaunchOptionsReader`): `demo-seed=standard`, `ui-testing-reset=true`,
`ui-testing-auth=approve|cancel|fail`, `ui-testing-secure-clip-seconds=<n>`. Release builds
ignore them and contain no demo content.

## Test tags

`Modifier.testTag` on every interactive element and key text, format `area.element[.qualifier]`
(DESIGN §13), lower case, dots between levels, hyphens inside a level, dynamic parts appended
(`library.row.<id>`, `editor.tags.completion.<foldedTag>`). Shared tags are in
`ui.components.TestTags`; screen tags in `feature/<name>/XTags`. `testTagsAsResourceId` is set
on the root, so UI Automator and `adb uiautomator dump` see them.

## Integration checklist

What a real implementation must provide when it replaces a fake (`AppContainer` is the only
place that changes):

- **LibraryRepository** (store + bridge): `snapshot` starts `Loading`, then publishes immutable
  snapshots built with `LibrarySnapshot.build(ordinary, secureShells, …)` (display order and
  tag order from `core.search`), secure bodies never included; every mutation visible in the
  snapshot before it returns; `update` field-level, no-op without touching `updatedAt`, keyword
  sanitised and tags normalised, duplicates allowed; autosave persistence lagging behind with
  `flush()` waiting for it; `discardBlankDraft` only for the remembered blank draft; delete
  tokens restoring at the original index once (50 kept); duplicate rule (copy disabled when the
  source is enabled with a keyword, inserted after the source); quarantine reported as
  `RecoveryRequired`; import conflicts refuse the whole import; typed errors, never throws.
- **SecureVault**: `state` with `NoVault` / `Locked(lastLock)` / `Unlocked(deadline)` /
  `KeyMissing(owner)` / `Unavailable(cause)`; `reveal` prompts only without a session;
  `withBodyOnce` authenticates every time and ends a session; session 5 min idle, 30 min max,
  locks on `onAppBackgrounded` with `LeftApp`; pre-lock hooks run while the key still works;
  `Cancelled` for a dismissed prompt; ids kept on promotion and demotion; the real
  `BiometricPrompt` authenticator behind `DeviceAuthenticator` (`MainActivity` is already a
  `FragmentActivity`), prompt texts from `authPromptText`.
- **SyncController**: `status` with the engine state, provider, `hasFetchedLibrary`,
  `recoveryAction`; `syncNow` unpaced and returning when the round ends; `performRecovery`;
  `setEnabled` (merge on enable); starts "not set up".
- **AppSettings**: persisted appearance and one-time hints.
- Leaving the foreground (`MainActivity.onStop` → `AppContainer.onAppBackgrounded`): flush,
  lock, and push a waiting Git change (WorkManager) once sync exists.
