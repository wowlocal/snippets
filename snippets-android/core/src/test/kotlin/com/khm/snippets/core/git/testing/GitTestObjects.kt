package com.khm.snippets.core.git.testing

import com.khm.snippets.core.git.GitCommit
import com.khm.snippets.core.git.GitObject
import com.khm.snippets.core.git.GitObjectId
import com.khm.snippets.core.git.GitObjectType
import com.khm.snippets.core.git.GitTree
import com.khm.snippets.core.git.GitTreeEntry

/** Builds the objects of a commit in Kotlin, the way the sync transport will. */
object GitTestObjects {
    class Snapshot(
        /** Blobs, then trees (children before parents), then the commit. */
        val objects: List<GitObject>,
        val commit: GitObject,
        val tree: GitObjectId,
    ) {
        val id: GitObjectId get() = commit.id
    }

    /** One commit whose tree holds `files` (slash-separated path to content). */
    fun snapshot(
        files: Map<String, ByteArray>,
        parent: GitObjectId? = null,
        epochSeconds: Long = 1_700_000_000,
        message: String = "Sync ${files.size} records",
    ): Snapshot {
        val objects = ArrayList<GitObject>()
        val root = tree(files, objects)
        val commit = GitObject(
            GitObjectType.COMMIT,
            GitCommit.serialize(root, listOfNotNull(parent), epochSeconds, message),
        )
        objects.add(commit)
        return Snapshot(objects, commit, root)
    }

    private fun tree(files: Map<String, ByteArray>, objects: MutableList<GitObject>): GitObjectId {
        val entries = ArrayList<GitTreeEntry>()
        val directories = LinkedHashMap<String, MutableMap<String, ByteArray>>()
        for ((path, content) in files) {
            val slash = path.indexOf('/')
            if (slash < 0) {
                val blob = GitObject(GitObjectType.BLOB, content)
                objects.add(blob)
                entries.add(GitTreeEntry.blob(path, blob.id))
            } else {
                directories.getOrPut(path.substring(0, slash)) { LinkedHashMap() }[path.substring(slash + 1)] = content
            }
        }
        for ((name, children) in directories) entries.add(GitTreeEntry.tree(name, tree(children, objects)))
        val tree = GitObject(GitObjectType.TREE, GitTree.serialize(entries))
        objects.add(tree)
        return tree.id
    }
}
