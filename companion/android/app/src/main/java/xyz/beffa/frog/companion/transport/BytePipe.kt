package xyz.beffa.frog.companion.transport

enum class Transport { WIFI, BLUETOOTH }

/**
 * A reliable, ordered byte stream to the Mac. TCP and the BLE GATT pipe both carry the same stream
 * (handshake, then frames); chunk boundaries mean nothing.
 */
interface BytePipe {
    val transport: Transport

    /** Monotonic millis of the last byte received; used for the 60 s receive timeout. */
    val lastReceiveMillis: Long

    /** Suspends until exactly [n] bytes arrived. Throws when the pipe closes first. */
    suspend fun readExactly(n: Int): ByteArray

    /** Writes the chunks in order, as one contiguous piece of the stream. */
    suspend fun write(vararg chunks: ByteArray)

    /** Idempotent; unblocks pending reads and writes with an exception. */
    fun close()
}

class PipeClosedException(message: String = "pipe closed") : java.io.IOException(message)

/**
 * The clock for keepalive and receive timeouts. The app swaps in
 * `SystemClock.elapsedRealtime`, which keeps counting while the phone is in deep sleep,
 * so a link that died during sleep is noticed as soon as the phone wakes.
 * `System.nanoTime` (the default, for JVM tests) stops during deep sleep.
 */
internal var monotonicMillis: () -> Long = { System.nanoTime() / 1_000_000 }

fun useElapsedRealtimeClock(clock: () -> Long) {
    monotonicMillis = clock
}
