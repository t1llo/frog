package xyz.beffa.frog.companion.transport

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.net.Inet4Address
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.Executors

/** Finds the paired Mac through `_frogcompanion._tcp` whose TXT `id` matches (docs/companion-protocol.md section 6). */
class NsdFinder(private val context: Context) {
    data class Endpoint(val host: String, val port: Int)

    private val executor = Executors.newSingleThreadExecutor()

    suspend fun find(macId: UUID, timeoutMs: Long): Endpoint? {
        val nsd = context.getSystemService(NsdManager::class.java) ?: return null
        val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
        val lock = wifi?.createMulticastLock("frog-companion-nsd")?.apply { setReferenceCounted(false) }
        val result = CompletableDeferred<Endpoint?>()
        val wanted = macId.toString().lowercase()
        val legacyQueue = ArrayDeque<NsdServiceInfo>()
        var legacyBusy = false
        val infoCallbacks = mutableListOf<NsdManager.ServiceInfoCallback>()

        fun accept(info: NsdServiceInfo) {
            val id = info.attributes["id"]?.toString(Charsets.UTF_8)?.trim()?.lowercase()
            if (id != wanted) return
            val addresses: List<InetAddress> = if (Build.VERSION.SDK_INT >= 34) {
                info.hostAddresses
            } else {
                @Suppress("DEPRECATION")
                listOfNotNull(info.host)
            }
            val v4 = addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull() ?: return
            result.complete(Endpoint(v4.hostAddress ?: return, info.port))
        }

        lateinit var resolveNextLegacy: () -> Unit
        resolveNextLegacy = {
            synchronized(legacyQueue) {
                if (!legacyBusy) {
                    legacyQueue.removeFirstOrNull()?.let { next ->
                        legacyBusy = true
                        @Suppress("DEPRECATION")
                        nsd.resolveService(next, object : NsdManager.ResolveListener {
                            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                                synchronized(legacyQueue) { legacyBusy = false }
                                resolveNextLegacy()
                            }

                            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                                accept(serviceInfo)
                                synchronized(legacyQueue) { legacyBusy = false }
                                resolveNextLegacy()
                            }
                        })
                    }
                }
            }
        }

        val discovery = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                result.complete(null)
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {}

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (Build.VERSION.SDK_INT >= 34) {
                    val cb = object : NsdManager.ServiceInfoCallback {
                        override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {}
                        override fun onServiceUpdated(serviceInfo: NsdServiceInfo) = accept(serviceInfo)
                        override fun onServiceLost() {}
                        override fun onServiceInfoCallbackUnregistered() {}
                    }
                    synchronized(infoCallbacks) { infoCallbacks += cb }
                    try {
                        nsd.registerServiceInfoCallback(serviceInfo, executor, cb)
                    } catch (_: Exception) {
                    }
                } else {
                    synchronized(legacyQueue) { legacyQueue.addLast(serviceInfo) }
                    resolveNextLegacy()
                }
            }
        }

        return try {
            lock?.acquire()
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
            withTimeoutOrNull(timeoutMs) { result.await() }
        } catch (_: Exception) {
            null
        } finally {
            try { nsd.stopServiceDiscovery(discovery) } catch (_: Exception) {}
            if (Build.VERSION.SDK_INT >= 34) {
                synchronized(infoCallbacks) {
                    infoCallbacks.forEach { try { nsd.unregisterServiceInfoCallback(it) } catch (_: Exception) {} }
                }
            }
            try { lock?.release() } catch (_: Exception) {}
        }
    }

    companion object {
        const val SERVICE_TYPE = "_frogcompanion._tcp"
    }
}
