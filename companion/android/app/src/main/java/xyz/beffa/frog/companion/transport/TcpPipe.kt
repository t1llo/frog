package xyz.beffa.frog.companion.transport

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

class TcpPipe private constructor(private val socket: Socket, val host: String) : BytePipe {
    override val transport = Transport.WIFI

    @Volatile
    override var lastReceiveMillis: Long = monotonicMillis()
        private set

    private val input = DataInputStream(socket.getInputStream())
    private val output = BufferedOutputStream(socket.getOutputStream(), 64 * 1024)
    private val closed = AtomicBoolean(false)

    override suspend fun readExactly(n: Int): ByteArray = withContext(Dispatchers.IO) {
        val out = ByteArray(n)
        var off = 0
        try {
            while (off < n) {
                val r = input.read(out, off, minOf(n - off, 256 * 1024))
                if (r < 0) throw PipeClosedException("connection closed by Mac")
                off += r
                lastReceiveMillis = monotonicMillis()
            }
        } catch (e: IOException) {
            close()
            throw e
        }
        out
    }

    override suspend fun write(vararg chunks: ByteArray) = withContext(Dispatchers.IO) {
        try {
            for (c in chunks) output.write(c)
            output.flush()
        } catch (e: IOException) {
            close()
            throw e
        }
    }

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            try {
                socket.close()
            } catch (_: IOException) {
            }
        }
    }

    companion object {
        suspend fun connect(host: String, port: Int, timeoutMs: Int): TcpPipe = withContext(Dispatchers.IO) {
            val socket = Socket()
            try {
                socket.tcpNoDelay = true
                socket.keepAlive = true
                socket.connect(InetSocketAddress(host, port), timeoutMs)
            } catch (e: IOException) {
                try { socket.close() } catch (_: IOException) {}
                throw e
            }
            TcpPipe(socket, host)
        }
    }
}
