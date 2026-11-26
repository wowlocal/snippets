package com.khm.snippets.android.app

import android.content.Context
import android.os.SystemClock
import android.text.format.DateFormat
import com.khm.snippets.android.data.AppSettings
import com.khm.snippets.android.data.KeywordAdvisor
import com.khm.snippets.android.data.LibraryQueryEngine
import com.khm.snippets.android.data.LibraryRepository
import com.khm.snippets.android.data.MonotonicClock
import com.khm.snippets.android.data.SecureVault
import com.khm.snippets.android.data.SnippetResolver
import com.khm.snippets.android.data.SyncController
import com.khm.snippets.android.data.VaultLockCause
import com.khm.snippets.android.data.core.CoreKeywordAdvisor
import com.khm.snippets.android.data.core.CoreLibraryQueryEngine
import com.khm.snippets.android.data.core.CoreSnippetResolver
import com.khm.snippets.android.data.fake.FakeBackends
import com.khm.snippets.android.feature.shared.RecoveryKeyPresenter
import com.khm.snippets.android.feature.shared.SnippetOperations
import com.khm.snippets.android.platform.AlarmClipClearScheduler
import com.khm.snippets.android.platform.AndroidShareSheet
import com.khm.snippets.android.platform.AndroidSnippetClipboard
import com.khm.snippets.android.platform.AndroidTimeFormatter
import com.khm.snippets.android.platform.ClipboardService
import com.khm.snippets.android.platform.DeviceAuthenticator
import com.khm.snippets.android.platform.IcuDateRenderer
import com.khm.snippets.android.platform.PlatformInfo
import com.khm.snippets.android.platform.ScreenCaptureState
import com.khm.snippets.android.platform.ShareSheet
import com.khm.snippets.android.platform.ShortcutRouter
import com.khm.snippets.android.platform.TimeFormatter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * The app's object graph, built once per process by [com.khm.snippets.android.SnippetsApplication]
 * (manual DI). Everything screens use is reached through here and typed by its contract.
 *
 * SEAM: [library], [vault], [sync], [settings] and [authenticator] are fakes ([fakes]) until
 * `:core` provides the store, vault and sync coordinator and the `BiometricPrompt`
 * authenticator lands. [resolver], [keywordAdvisor] and [newQueryEngine] are already the real
 * `:core` implementations. `docs/app-architecture.md` lists what a replacement must provide.
 */
class AppContainer(context: Context, val dispatchers: AppDispatchers = AppDispatchers()) {
    private val appContext = context.applicationContext
    private var launchApplied = false

    /** Outlives every screen: undo, clipboard timers, final saves of a closed editor. */
    val appScope: CoroutineScope = CoroutineScope(SupervisorJob() + dispatchers.main)

    /** `SystemClock.elapsedRealtime`: vault sessions and clip deadlines survive deep sleep. */
    val clock: MonotonicClock = MonotonicClock(SystemClock::elapsedRealtime)

    val platform = PlatformInfo()
    val screenCapture = ScreenCaptureState()
    val shortcuts = ShortcutRouter()
    val recoveryKeys = RecoveryKeyPresenter()

    val fakes = FakeBackends(appScope, clock)
    val authenticator: DeviceAuthenticator get() = fakes.authenticator
    val settings: AppSettings get() = fakes.settings
    val library: LibraryRepository get() = fakes.library
    val vault: SecureVault get() = fakes.vault
    val sync: SyncController get() = fakes.sync

    val resolver: SnippetResolver = CoreSnippetResolver(IcuDateRenderer.current { DateFormat.is24HourFormat(appContext) })
    val keywordAdvisor: KeywordAdvisor = CoreKeywordAdvisor()

    /** A search engine with its own index; one per screen that searches. */
    fun newQueryEngine(): LibraryQueryEngine = CoreLibraryQueryEngine(dispatchers.default)

    val clipboard = ClipboardService(
        clipboard = AndroidSnippetClipboard(appContext),
        clock = clock,
        scope = appScope,
        backstop = AlarmClipClearScheduler(appContext),
        platform = platform,
    )
    val timeFormatter: TimeFormatter = AndroidTimeFormatter(appContext)
    val shareSheet: ShareSheet = AndroidShareSheet(appContext)
    val operations = SnippetOperations(library, vault, resolver, clipboard, recoveryKeys, appScope)

    /**
     * Applies the launch extras of the first activity of this process. Later activities (a
     * configuration change, a restore after process death with the same intent) change nothing.
     */
    fun applyLaunchOptions(options: LaunchOptions) {
        if (launchApplied) return
        launchApplied = true
        options.seed?.let(fakes::seed)
        options.authAnswer?.let { fakes.authenticator.answer = it }
        options.secureClipSeconds?.let { clipboard.secureClipLifetimeMillis = it * MILLIS_PER_SECOND }
        if (options.resetHints) appScope.launch { settings.resetHints() }
    }

    /** The app left the foreground: pending writes are flushed and the vault locks. */
    fun onAppBackgrounded() {
        appScope.launch {
            library.flush()
            vault.lock(VaultLockCause.LeftApp)
        }
    }

    private companion object {
        const val MILLIS_PER_SECOND = 1_000L
    }
}
