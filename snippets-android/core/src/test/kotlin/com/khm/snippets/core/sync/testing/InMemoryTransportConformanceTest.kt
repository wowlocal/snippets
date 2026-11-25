package com.khm.snippets.core.sync.testing

import com.khm.snippets.core.sync.transport.SyncTransport
import com.khm.snippets.core.sync.transport.SyncTransportConformanceTest
import com.khm.snippets.core.wire.WireRecord

/**
 * The reference fake against the contract every transport is held to. A small page size,
 * so the paging test spans several pages.
 */
class InMemoryTransportConformanceTest : SyncTransportConformanceTest() {

    override fun newTransport(): SyncTransport = InMemoryTransport(pageSize = 4)

    override suspend fun writeFromAnotherDevice(transport: SyncTransport, records: List<WireRecord>) {
        (transport as InMemoryTransport).seed(records)
    }

    override fun newPollOnlyTransport(): SyncTransport = InMemoryTransport(supportsPush = false)
}

/** The same contract with the default page size, where everything fits one page. */
class InMemoryTransportSinglePageConformanceTest : SyncTransportConformanceTest() {

    override fun newTransport(): SyncTransport = InMemoryTransport()

    override suspend fun writeFromAnotherDevice(transport: SyncTransport, records: List<WireRecord>) {
        (transport as InMemoryTransport).seed(records)
    }
}

/**
 * The contract's own helper for a backend with a second client: here the "other device" is
 * the same fake, written to through `submit` with the generations it holds.
 */
class InMemoryTransportPeerConformanceTest : SyncTransportConformanceTest() {

    override fun newTransport(): SyncTransport = InMemoryTransport(pageSize = 3)

    override suspend fun writeFromAnotherDevice(transport: SyncTransport, records: List<WireRecord>) {
        submitAsPeer(transport, records)
    }
}
