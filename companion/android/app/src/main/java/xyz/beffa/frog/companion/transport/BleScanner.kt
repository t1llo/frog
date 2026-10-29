package xyz.beffa.frog.companion.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.ParcelUuid
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/** Scans for a peripheral advertising the Frog Companion service UUID. */
@SuppressLint("MissingPermission")
class BleScanner(private val context: Context) {

    fun isAvailable(): Boolean {
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return false
        return adapter.isEnabled
    }

    /** First Frog Companion peripheral not in [skip], or null after [timeoutMs]. */
    suspend fun findMac(timeoutMs: Long, skip: Set<String> = emptySet()): BluetoothDevice? {
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return null
        if (!adapter.isEnabled) return null
        val scanner = adapter.bluetoothLeScanner ?: return null
        val found = CompletableDeferred<BluetoothDevice?>()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                if (result.device.address !in skip) found.complete(result.device)
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.firstOrNull { it.device.address !in skip }?.let { found.complete(it.device) }
            }

            override fun onScanFailed(errorCode: Int) {
                found.complete(null)
            }
        }
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(CompanionBle.SERVICE)).build())
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        return try {
            scanner.startScan(filters, settings, callback)
            withTimeoutOrNull(timeoutMs) { found.await() }
        } catch (_: SecurityException) {
            null
        } finally {
            try {
                scanner.stopScan(callback)
            } catch (_: Exception) {
            }
        }
    }
}
