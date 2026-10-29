package xyz.beffa.frog.companion.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.os.Build
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/** BLE UUIDs from docs/companion-protocol.md section 7. */
object CompanionBle {
    val SERVICE: UUID = UUID.fromString("F0C00001-2A32-4AC4-AF29-8824B655BF6F")
    val RX: UUID = UUID.fromString("F0C00002-2A32-4AC4-AF29-8824B655BF6F")
    val TX: UUID = UUID.fromString("F0C00003-2A32-4AC4-AF29-8824B655BF6F")
    val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    const val REQUESTED_MTU = 517

    /** An ATT attribute value is at most 512 bytes, so MTU - 3 is capped there. */
    const val MAX_ATTRIBUTE = 512
}

/**
 * The phone as BLE central: writes the stream to rx (write with response) in chunks of
 * min(MTU - 3, 512) and receives the Mac's stream as tx notifications.
 */
@SuppressLint("MissingPermission")
class BlePipe private constructor(
    private val gatt: BluetoothGatt,
    private val callback: Callback,
    private val rx: BluetoothGattCharacteristic,
    mtu: Int,
) : BytePipe {
    override val transport = Transport.BLUETOOTH
    override val lastReceiveMillis: Long get() = callback.lastReceive

    private val chunkSize = (mtu - 3).coerceIn(20, CompanionBle.MAX_ATTRIBUTE)
    private val writeLock = Mutex()
    private val closed = AtomicBoolean(false)
    private var pending: ByteArray = ByteArray(0)
    private var pendingOffset = 0

    override suspend fun readExactly(n: Int): ByteArray {
        val out = ByteArray(n)
        var off = 0
        while (off < n) {
            if (pendingOffset >= pending.size) {
                pending = callback.incoming.receiveCatching().getOrNull() ?: throw PipeClosedException("Bluetooth link closed")
                pendingOffset = 0
                continue
            }
            val take = minOf(n - off, pending.size - pendingOffset)
            System.arraycopy(pending, pendingOffset, out, off, take)
            off += take
            pendingOffset += take
        }
        return out
    }

    override suspend fun write(vararg chunks: ByteArray) = writeLock.withLock {
        for (chunk in chunks) {
            var off = 0
            while (off < chunk.size) {
                val end = minOf(chunk.size, off + chunkSize)
                writeChunk(chunk.copyOfRange(off, end))
                off = end
            }
        }
    }

    @Suppress("DEPRECATION")
    private suspend fun writeChunk(value: ByteArray) {
        if (closed.get() || callback.isDisconnected) throw PipeClosedException("Bluetooth link closed")
        var attempts = 0
        while (true) {
            val started = if (Build.VERSION.SDK_INT >= 33) {
                gatt.writeCharacteristic(rx, value, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                    BluetoothStatusCodes.SUCCESS
            } else {
                rx.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                rx.value = value
                gatt.writeCharacteristic(rx)
            }
            if (started) break
            if (++attempts > 50 || callback.isDisconnected) {
                close()
                throw PipeClosedException("Bluetooth write failed")
            }
            delay(20)
        }
        val status = withTimeoutOrNull(10_000) { callback.writeResults.receiveCatching().getOrNull() }
        if (status != BluetoothGatt.GATT_SUCCESS) {
            close()
            throw PipeClosedException("Bluetooth write status $status")
        }
    }

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            callback.shutdown()
            try {
                gatt.disconnect()
                gatt.close()
            } catch (_: Exception) {
            }
        }
    }

    internal class Callback : BluetoothGattCallback() {
        val connected = CompletableDeferred<Unit>()
        val mtu = CompletableDeferred<Int>()
        val services = CompletableDeferred<Boolean>()
        val descriptorWritten = CompletableDeferred<Int>()
        val writeResults = Channel<Int>(Channel.UNLIMITED)
        val incoming = Channel<ByteArray>(Channel.UNLIMITED)

        @Volatile
        var lastReceive = monotonicMillis()

        @Volatile
        var isDisconnected = false

        fun shutdown() {
            isDisconnected = true
            val e = PipeClosedException("Bluetooth link closed")
            connected.completeExceptionally(e)
            mtu.completeExceptionally(e)
            services.completeExceptionally(e)
            descriptorWritten.completeExceptionally(e)
            writeResults.close()
            incoming.close()
        }

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                connected.complete(Unit)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                shutdown()
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            this.mtu.complete(if (status == BluetoothGatt.GATT_SUCCESS) mtu else 23)
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            services.complete(status == BluetoothGatt.GATT_SUCCESS)
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            descriptorWritten.complete(status)
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            writeResults.trySend(status)
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            received(characteristic, value)
        }

        @Deprecated("Deprecated in API 33")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT < 33) received(characteristic, characteristic.value ?: return)
        }

        private fun received(characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            if (characteristic.uuid != CompanionBle.TX || value.isEmpty()) return
            lastReceive = monotonicMillis()
            incoming.trySend(value.copyOf())
        }
    }

    companion object {
        /**
         * Connects, requests MTU 517 and high priority, discovers the Frog Companion service, subscribes to
         * tx. The returned pipe is ready for the client to write its handshake.
         */
        @Suppress("DEPRECATION")
        suspend fun connect(context: Context, device: BluetoothDevice): BlePipe {
            val callback = Callback()
            val gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
                ?: throw PipeClosedException("connectGatt failed")
            try {
                withTimeout(15_000) { callback.connected.await() }
                gatt.requestMtu(CompanionBle.REQUESTED_MTU)
                val mtu = withTimeoutOrNull(5_000) { callback.mtu.await() } ?: 23
                gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                if (!gatt.discoverServices()) throw PipeClosedException("discoverServices failed")
                if (!withTimeout(15_000) { callback.services.await() }) throw PipeClosedException("service discovery failed")
                val service = gatt.getService(CompanionBle.SERVICE) ?: throw PipeClosedException("Frog Companion service missing")
                val rx = service.getCharacteristic(CompanionBle.RX) ?: throw PipeClosedException("rx missing")
                val tx = service.getCharacteristic(CompanionBle.TX) ?: throw PipeClosedException("tx missing")

                gatt.setCharacteristicNotification(tx, true)
                val cccd = tx.getDescriptor(CompanionBle.CCCD) ?: throw PipeClosedException("tx CCCD missing")
                val value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                val started = if (Build.VERSION.SDK_INT >= 33) {
                    gatt.writeDescriptor(cccd, value) == BluetoothStatusCodes.SUCCESS
                } else {
                    cccd.value = value
                    gatt.writeDescriptor(cccd)
                }
                if (!started) throw PipeClosedException("subscribe failed")
                val status = withTimeout(10_000) { callback.descriptorWritten.await() }
                if (status != BluetoothGatt.GATT_SUCCESS) throw PipeClosedException("subscribe status $status")
                callback.lastReceive = monotonicMillis()
                return BlePipe(gatt, callback, rx, mtu)
            } catch (e: Throwable) {
                callback.shutdown()
                try {
                    gatt.disconnect()
                    gatt.close()
                } catch (_: Exception) {
                }
                throw e
            }
        }
    }
}
