package com.khm.snippets.core.git.testing

import com.khm.snippets.core.git.GitObjectId
import com.khm.snippets.core.git.GitRemote
import com.khm.snippets.core.git.GitSmartHttpClient
import com.khm.snippets.core.git.GitSshClient
import com.khm.snippets.core.git.GitSshLocation
import com.khm.snippets.core.git.GitWire
import com.khm.snippets.core.git.OkHttpGitHttpEngine
import java.io.Closeable
import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class GitCommandFailed(detail: String) : Exception(detail)

/**
 * A bare repository in a temporary directory, served through [GitTestServer], plus a
 * git CLI for playing the part of another writer. The Kotlin counterpart of
 * `GitFixture` in `Tests/Core/GitTestServer.swift`.
 *
 * Construction skips the test (JUnit `Assume`) when git or its http-backend is missing.
 */
class GitFixture(branch: String = "main") : Closeable {
    val root: File
    val bare: File
    val username = "tester"
    val password = "test-token-${UUID.randomUUID()}"
    val server: GitTestServer

    /** `http://127.0.0.1:<port>/repo.git` */
    val url: String

    private val closeables = ArrayList<Closeable>()

    init {
        GitBinary.assumeHttpBackend()
        root = Files.createTempDirectory("git-sync-").toFile().canonicalFile
        bare = File(root, "repo.git")
        git("init", "--bare", "--quiet", "--initial-branch=$branch", bare.path)
        server = GitTestServer(root, username, password)
        url = "${server.origin}/repo.git"
    }

    override fun close() {
        closeables.asReversed().forEach { runCatching { it.close() } }
        server.close()
        root.deleteRecursively()
    }

    /** A remote reached over loopback HTTP, which only the explicit test seam permits. */
    fun remote(branch: String = "main", password: String? = null, url: String = this.url): GitRemote =
        GitRemote.https(url, branch, username, password ?: this.password, allowsInsecureLoopback = true)

    /** A real HTTP engine with the loopback seam on; closed with the fixture. */
    fun engine(idleTimeoutMillis: Long = 60_000, requestTimeoutMillis: Long = 600_000): OkHttpGitHttpEngine =
        OkHttpGitHttpEngine(allowsInsecureLoopback = true, idleTimeoutMillis, requestTimeoutMillis)
            .also { closeables.add(it) }

    fun client(
        remote: GitRemote = remote(),
        engine: OkHttpGitHttpEngine = engine(),
        maximumPackBytes: Long = GitWire.MAXIMUM_PACK_BYTES,
    ): GitSmartHttpClient = GitSmartHttpClient(remote, engine, maximumPackBytes)

    fun cacheDirectory(name: String): File = File(root, "cache-$name")

    // MARK: SSH

    /** `git@ssh.fixture.invalid:repo.git`: relative to the fixture root, where the process connector runs. */
    val sshLocation: GitSshLocation
        get() = GitSshLocation(user = "git", host = "ssh.fixture.invalid", port = null, path = "repo.git", scpStyle = true)

    fun sshRemote(branch: String = "main"): GitRemote = GitRemote.ssh(sshLocation, branch)

    val sshConnector: ProcessGitSshConnector by lazy { ProcessGitSshConnector(root) }

    fun sshClient(branch: String = "main", idleTimeoutMillis: Long = 120_000): GitSshClient =
        GitSshClient(sshRemote(branch), sshLocation, sshConnector, idleTimeoutMillis = idleTimeoutMillis)

    // MARK: git

    /** Clones the branch, lets `body` edit the working tree, then commits and pushes. */
    fun commitAsAnotherWriter(
        branch: String = "main",
        message: String = "external edit",
        force: Boolean = false,
        body: (File) -> Unit,
    ) {
        val work = File(root, "work-${UUID.randomUUID()}")
        try {
            if (headOrNull(branch) == null) {
                git("init", "--quiet", "--initial-branch=$branch", work.path)
                git("-C", work.path, "remote", "add", "origin", bare.path)
            } else {
                git("clone", "--quiet", "--branch", branch, bare.path, work.path)
            }
            body(work)
            git("-C", work.path, "add", "-A")
            git("-C", work.path, "commit", "--quiet", "-m", message)
            git(*(listOf("-C", work.path, "push", "--quiet") + (if (force) listOf("--force") else emptyList()) +
                listOf("origin", "HEAD:refs/heads/$branch")).toTypedArray())
        } finally {
            work.deleteRecursively()
        }
    }

    /** The branch head in the bare repository, or null while the branch does not exist. */
    fun headOrNull(branch: String = "main"): GitObjectId? = try {
        GitObjectId.fromHex(bareGit("rev-parse", "--verify", "--quiet", "refs/heads/$branch"))
    } catch (_: GitCommandFailed) {
        null
    }

    fun head(branch: String = "main"): GitObjectId = headOrNull(branch) ?: throw GitCommandFailed("no branch $branch")

    /** `git --git-dir <bare> …`, trimmed output. */
    fun bareGit(vararg arguments: String, input: ByteArray? = null): String =
        git("--git-dir", bare.path, *arguments, input = input)

    fun bareGitBytes(vararg arguments: String, input: ByteArray? = null): ByteArray =
        gitBytes(listOf("--git-dir", bare.path) + arguments, input)

    /** Runs git with fixed authorship and no user configuration; returns trimmed output. */
    fun git(vararg arguments: String, input: ByteArray? = null): String =
        gitBytes(arguments.toList(), input).toString(Charsets.UTF_8).trim()

    fun gitBytes(arguments: List<String>, input: ByteArray? = null): ByteArray {
        val command = listOf(
            GitBinary.path!!, "-c", "user.name=Other", "-c", "user.email=other@example.invalid",
            "-c", "commit.gpgsign=false",
        ) + arguments
        val builder = ProcessBuilder(command).directory(root)
        builder.environment().clear()
        builder.environment().putAll(GitBinary.isolatedEnvironment(root))
        val process = builder.start()
        var errors = ByteArray(0)
        val errorReader = thread { errors = process.errorStream.readBytes() }
        val writer = thread {
            runCatching { process.outputStream.use { if (input != null) it.write(input) } }
        }
        val output = process.inputStream.readBytes()
        writer.join()
        errorReader.join()
        if (!process.waitFor(120, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            throw GitCommandFailed(arguments.joinToString(" ") + ": timed out")
        }
        if (process.exitValue() != 0) {
            throw GitCommandFailed(arguments.joinToString(" ") + ": " + (output + errors).toString(Charsets.UTF_8))
        }
        return output
    }
}
