package com.khm.snippets.core.git.testing

import java.io.File
import java.util.concurrent.TimeUnit
import org.junit.Assume

/** The system git, located once. Tests that need it skip cleanly when it is missing. */
object GitBinary {
    /** Absolute path of `git`, or null. */
    val path: String? by lazy {
        sequenceOf(
            { run(listOf("/usr/bin/xcrun", "--find", "git")) },
            { run(listOf("/usr/bin/which", "git")) },
            { run(listOf("/bin/sh", "-c", "command -v git")) },
        ).mapNotNull { it() }.map { it.trim() }.firstOrNull { it.isNotEmpty() && File(it).canExecute() }
    }

    /** `git --exec-path`: where `git-http-backend`, `git-upload-pack` and the rest live. */
    val execPath: String? by lazy {
        path?.let { run(listOf(it, "--exec-path")) }?.trim()?.takeIf { File(it).isDirectory }
    }

    val isAvailable: Boolean get() = path != null && execPath != null

    val hasHttpBackend: Boolean get() = execPath?.let { File(it, "git-http-backend").canExecute() } == true

    fun assumeAvailable() {
        Assume.assumeTrue("git is not installed", isAvailable)
    }

    fun assumeHttpBackend() {
        assumeAvailable()
        Assume.assumeTrue("git http-backend is not installed", hasHttpBackend)
    }

    /** Where a shell finds `git` and the `git-*` service programs. */
    val searchPath: String
        get() = listOfNotNull(path?.let { File(it).parent }, execPath, "/usr/bin", "/bin", "/usr/sbin", "/sbin")
            .distinct().joinToString(":")

    /** Nothing inherited: no user or system git configuration, no prompts. */
    fun isolatedEnvironment(home: File): Map<String, String> {
        val environment = linkedMapOf(
            "HOME" to home.path,
            "PATH" to searchPath,
            "GIT_CONFIG_NOSYSTEM" to "1",
            "GIT_CONFIG_GLOBAL" to "/dev/null",
            "GIT_TERMINAL_PROMPT" to "0",
        )
        System.getenv("DEVELOPER_DIR")?.let { environment["DEVELOPER_DIR"] = it }
        return environment
    }

    private fun run(command: List<String>): String? = try {
        val process = ProcessBuilder(command).redirectErrorStream(false).start()
        process.outputStream.close()
        val output = process.inputStream.readBytes().toString(Charsets.UTF_8)
        process.errorStream.readBytes()
        if (process.waitFor(30, TimeUnit.SECONDS) && process.exitValue() == 0) output else null
    } catch (_: Exception) {
        null
    }
}
