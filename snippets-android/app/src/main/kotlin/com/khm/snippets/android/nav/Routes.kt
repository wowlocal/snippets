package com.khm.snippets.android.nav

import androidx.navigation3.runtime.NavKey
import androidx.savedstate.serialization.SavedStateConfiguration
import kotlinx.serialization.Serializable
import kotlinx.serialization.modules.SerializersModule
import kotlinx.serialization.modules.polymorphic
import kotlinx.serialization.modules.subclass

/**
 * A destination on the back stack (DESIGN.md §3). Only screens, panes and full-screen dialogs
 * are routes; menus, sheets and alert dialogs are state of the screen that shows them.
 *
 * [routeName] is the stable name the design uses (`editor/{id}`, `settings/sync`). It is not
 * user-visible.
 */
@Serializable
sealed interface Route : NavKey {
    val routeName: String
}

/** `library`: the start destination, and the list pane in two-pane windows. */
@Serializable
data object LibraryRoute : Route {
    override val routeName: String get() = "library"
}

/**
 * `editor/{id}`: one snippet. The detail pane in two-pane windows, where it also is the
 * selection.
 *
 * @param focusBody The entry was just created: open with the body focused and the keyboard up.
 */
@Serializable
data class EditorRoute(val id: String, val focusBody: Boolean = false) : Route {
    override val routeName: String get() = "editor/$id"
}

/** `sync/review`: the Review screen of a sync halt (full-screen dialog). */
@Serializable
data object SyncReviewRoute : Route {
    override val routeName: String get() = "sync/review"
}

/** `backup/new-password`: the first step of Encrypted Backup (full-screen dialog). */
@Serializable
data object BackupNewPasswordRoute : Route {
    override val routeName: String get() = "backup/new-password"
}

/** Start of the import flow (a system document picker, then its dialogs). */
@Serializable
data object ImportRoute : Route {
    override val routeName: String get() = "import"
}

/** Start of Export for Sharing (a system document picker). */
@Serializable
data object ExportRoute : Route {
    override val routeName: String get() = "export"
}

/** `settings` and its panes. */
@Serializable
sealed interface SettingsDestination : Route

@Serializable
data object SettingsRoute : SettingsDestination {
    override val routeName: String get() = "settings"
}

@Serializable
data object SettingsSyncRoute : SettingsDestination {
    override val routeName: String get() = "settings/sync"
}

@Serializable
data object SettingsSyncGitRoute : SettingsDestination {
    override val routeName: String get() = "settings/sync/git"
}

@Serializable
data object SettingsSyncCloudRoute : SettingsDestination {
    override val routeName: String get() = "settings/sync/cloud"
}

@Serializable
data object SettingsSecureRoute : SettingsDestination {
    override val routeName: String get() = "settings/secure"
}

@Serializable
data object SettingsBackupRoute : SettingsDestination {
    override val routeName: String get() = "settings/backup"
}

@Serializable
data object SettingsAppearanceRoute : SettingsDestination {
    override val routeName: String get() = "settings/appearance"
}

@Serializable
data object SettingsDiagnosticsRoute : SettingsDestination {
    override val routeName: String get() = "settings/diagnostics"
}

@Serializable
data object SettingsAboutRoute : SettingsDestination {
    override val routeName: String get() = "settings/about"
}

@Serializable
data object SettingsNoticesRoute : SettingsDestination {
    override val routeName: String get() = "settings/about/notices"
}

/**
 * How the back stack is saved: every route is registered here, so restoring after process death
 * needs no reflection and survives R8. A new route must be added to this list.
 */
val RouteSavedStateConfiguration: SavedStateConfiguration = SavedStateConfiguration {
    serializersModule = SerializersModule {
        polymorphic(NavKey::class) {
            subclass(LibraryRoute::class)
            subclass(EditorRoute::class)
            subclass(SyncReviewRoute::class)
            subclass(BackupNewPasswordRoute::class)
            subclass(ImportRoute::class)
            subclass(ExportRoute::class)
            subclass(SettingsRoute::class)
            subclass(SettingsSyncRoute::class)
            subclass(SettingsSyncGitRoute::class)
            subclass(SettingsSyncCloudRoute::class)
            subclass(SettingsSecureRoute::class)
            subclass(SettingsBackupRoute::class)
            subclass(SettingsAppearanceRoute::class)
            subclass(SettingsDiagnosticsRoute::class)
            subclass(SettingsAboutRoute::class)
            subclass(SettingsNoticesRoute::class)
        }
    }
}
