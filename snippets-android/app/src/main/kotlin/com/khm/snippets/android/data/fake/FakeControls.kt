package com.khm.snippets.android.data.fake

import com.khm.snippets.android.data.LibraryError
import kotlinx.coroutines.delay

/**
 * What a test (or a debug launch) can make the fakes do. One instance is shared by the fakes of
 * an [com.khm.snippets.android.app.AppContainer].
 *
 * @property latencyMillis Delay of every repository, vault and sync call. With a test
 *   dispatcher this is virtual time.
 * @property writeError While set, every library write fails with it and changes nothing.
 * @property saveError While set, an accepted edit stays in memory but [flushing][com.khm.snippets.android.data.LibraryRepository.flush]
 *   and updating report it (autosave failure).
 */
class FakeControls {
    @Volatile var latencyMillis: Long = 0
    @Volatile var writeError: LibraryError? = null
    @Volatile var saveError: LibraryError? = null

    internal suspend fun pause() {
        val millis = latencyMillis
        if (millis > 0) delay(millis)
    }
}
