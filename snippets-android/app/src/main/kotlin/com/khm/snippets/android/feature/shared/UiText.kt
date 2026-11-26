package com.khm.snippets.android.feature.shared

import android.content.res.Resources
import androidx.annotation.PluralsRes
import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext

/**
 * A text the UI will show, described without resolving it: ViewModels and mappers name the
 * resource and its arguments, composables resolve it. App copy is always a resource; [Raw] is
 * only for user data (a snippet name) and for text the system supplies.
 *
 * Arguments may be [UiText]s themselves; they are resolved first.
 */
@Immutable
sealed interface UiText {
    @Immutable
    data class Res(@param:StringRes val id: Int, val args: List<Any> = emptyList()) : UiText

    @Immutable
    data class Plural(@param:PluralsRes val id: Int, val quantity: Int, val args: List<Any> = listOf(quantity)) : UiText

    @Immutable
    data class Raw(val value: String) : UiText

    /** Sentences that follow each other, separated by one space. */
    @Immutable
    data class Sentences(val parts: List<UiText>) : UiText
}

fun uiText(@StringRes id: Int, vararg args: Any): UiText = UiText.Res(id, args.toList())

fun UiText.resolve(resources: Resources): String = when (this) {
    is UiText.Res -> if (args.isEmpty()) resources.getString(id) else resources.getString(id, *resolvedArgs(args, resources))
    is UiText.Plural -> resources.getQuantityString(id, quantity, *resolvedArgs(args, resources))
    is UiText.Raw -> value
    is UiText.Sentences -> parts.joinToString(" ") { it.resolve(resources) }
}

@Composable
fun UiText.resolve(): String {
    // Reading the configuration makes the text follow a locale or font change.
    LocalConfiguration.current
    return resolve(LocalContext.current.resources)
}

private fun resolvedArgs(args: List<Any>, resources: Resources): Array<Any> =
    Array(args.size) { index -> (args[index] as? UiText)?.resolve(resources) ?: args[index] }
