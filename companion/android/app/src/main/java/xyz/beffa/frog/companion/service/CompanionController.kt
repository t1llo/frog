package xyz.beffa.frog.companion.service

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.provider.Settings
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import xyz.beffa.frog.companion.clipboard.IncomingClips
import xyz.beffa.frog.companion.clipboard.OutgoingItem
import xyz.beffa.frog.companion.clipboard.fingerprint
import xyz.beffa.frog.companion.data.DeliveryState
import xyz.beffa.frog.companion.data.Direction
import xyz.beffa.frog.companion.data.CompanionStore
import xyz.beffa.frog.companion.data.HistoryItem
import xyz.beffa.frog.companion.data.HistoryStore
import xyz.beffa.frog.companion.data.PairedMac
import xyz.beffa.frog.companion.protocol.ClipKind
import xyz.beffa.frog.companion.protocol.Limits
import xyz.beffa.frog.companion.protocol.Message
import xyz.beffa.frog.companion.protocol.PairingCode
import xyz.beffa.frog.companion.transport.BlePipe
import xyz.beffa.frog.companion.transport.BleScanner
import xyz.beffa.frog.companion.transport.BytePipe
import xyz.beffa.frog.companion.transport.NsdFinder
import xyz.beffa.frog.companion.transport.Session
import xyz.beffa.frog.companion.transport.TcpPipe
import xyz.beffa.frog.companion.transport.Transport
import java.util.UUID

enum class Link { OFFLINE, SEARCHING, WIFI, BLUETOOTH }

data class CompanionStatus(val paired: Boolean, val macName: String?, val link: Link)

sealed interface SendResult {
    data object Sending : SendResult
    data object Queued : SendResult
    data object WaitingForWifi : SendResult
    data object AlreadyOnMac : SendResult
    data object TooLarge : SendResult
    data object NotPaired : SendResult
    data object Empty : SendResult
}

/**
 * Owns the link to the Mac: finds it (TCP hosts, NSD, then BLE), runs one [Session] at a time,
 * keeps the outbox of clips until they are acked, and applies clips from the Mac.
 */
class CompanionController(context: Context) : Session.Handler {
    private val app = context.applicationContext
    val store = CompanionStore(app)
    val history = HistoryStore(app)
    private val incoming = IncomingClips(app)
    private val notifications = Notifications(app)
    private val nsd = NsdFinder(app)
    private val ble = BleScanner(app)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _status = MutableStateFlow(initialStatus())
    val status: StateFlow<CompanionStatus> = _status.asStateFlow()

    private var loopJob: Job? = null
    private val kick = Channel<Unit>(Channel.CONFLATED)
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    @Volatile
    private var session: Session? = null

    private class Pending(val id: String, val item: OutgoingItem, var sentOn: Session? = null)

    private val outboxLock = Mutex()
    private val outbox = ArrayList<Pending>()
    private val flushLock = Mutex()

    private val receivedIds = ArrayDeque(store.receivedIds())

    @Volatile
    private var lastReceivedFingerprint: String? = null

    private fun initialStatus(): CompanionStatus {
        val mac = store.pairedMac()
        return CompanionStatus(mac != null, mac?.name, Link.OFFLINE)
    }

    // region lifecycle

    @Synchronized
    fun start() {
        if (loopJob?.isActive == true) {
            kick.trySend(Unit)
            return
        }
        if (store.pairedMac() == null) return
        registerNetworkCallback()
        loopJob = scope.launch { connectionLoop() }
    }

    @Synchronized
    fun stop() {
        loopJob?.cancel()
        loopJob = null
        session?.close()
        unregisterNetworkCallback()
        setLink(Link.OFFLINE)
    }

    fun pair(code: PairingCode) {
        stop()
        store.savePairing(code)
        receivedIds.clear()
        _status.value = CompanionStatus(true, code.macName, Link.SEARCHING)
    }

    /** Tells the Mac (if connected) and forgets it. */
    suspend fun unpair() {
        session?.let { s -> runCatching { withTimeoutOrNull(2_000) { s.send(Message.Unpair) } } }
        forget()
    }

    private fun forget() {
        stop()
        store.forgetPairing()
        receivedIds.clear()
        scope.launch { outboxLock.withLock { outbox.clear() } }
        history.clear()
        _status.value = CompanionStatus(false, null, Link.OFFLINE)
        CompanionService.stop(app)
    }

    // endregion

    // region sending

    suspend fun send(item: OutgoingItem): SendResult {
        if (store.pairedMac() == null) return SendResult.NotPaired
        if (item.body.isEmpty()) return SendResult.Empty
        if (item.fingerprint == lastReceivedFingerprint) return SendResult.AlreadyOnMac
        if (item.body.size > Limits.MAX_CLIP_TCP) return SendResult.TooLarge

        val id = UUID.randomUUID().toString()
        val uri = if (item.kind == ClipKind.IMAGE) {
            runCatching { incoming.saveImage(id, item.mime, item.body).toString() }.getOrNull()
        } else {
            null
        }
        val tooBigForBle = item.body.size > Limits.MAX_CLIP_BLE
        val current = session?.takeIf { it.isOpen }
        history.add(
            HistoryItem(
                id = id,
                direction = Direction.SENT,
                kind = item.kind,
                mime = item.mime,
                name = item.name,
                size = item.body.size.toLong(),
                preview = item.previewText,
                text = if (item.kind == ClipKind.TEXT) item.body.toString(Charsets.UTF_8).take(HistoryItem.MAX_TEXT) else null,
                uri = uri,
                timeMillis = System.currentTimeMillis(),
                state = DeliveryState.QUEUED,
                waitingForWifi = tooBigForBle && current?.transport == Transport.BLUETOOTH,
            ),
        )
        outboxLock.withLock { outbox += Pending(id, item) }
        start()
        current?.let { s -> scope.launch { flush(s) } }
        return when {
            current == null -> SendResult.Queued
            tooBigForBle && current.transport == Transport.BLUETOOTH -> SendResult.WaitingForWifi
            else -> SendResult.Sending
        }
    }

    /** Sends every queued clip that fits the session's transport and was not sent on it yet. */
    private suspend fun flush(s: Session) = flushLock.withLock {
        val limit = if (s.transport == Transport.WIFI) Limits.MAX_CLIP_TCP else Limits.MAX_CLIP_BLE
        val todo = outboxLock.withLock { outbox.filter { it.sentOn !== s } }
        for (p in todo) {
            if (!s.isOpen) return@withLock
            if (p.item.body.size > limit) {
                history.update(p.id) { it.copy(waitingForWifi = true) }
                continue
            }
            history.update(p.id) { it.copy(state = DeliveryState.SENDING, waitingForWifi = false) }
            try {
                s.send(
                    Message.Clip(
                        id = p.id,
                        kind = p.item.kind,
                        mime = p.item.mime,
                        name = if (p.item.kind == ClipKind.TEXT) null else p.item.name,
                        body = p.item.body,
                    ),
                )
                p.sentOn = s
            } catch (e: OutOfMemoryError) {
                outboxLock.withLock { outbox.remove(p) }
                history.update(p.id) { it.copy(state = DeliveryState.DELIVERED, preview = "Too large to send: ${it.preview}") }
            } catch (e: Exception) {
                history.update(p.id) { it.copy(state = DeliveryState.QUEUED) }
                return@withLock
            }
        }
    }

    // endregion

    // region Session.Handler

    override suspend fun onOpen(session: Session, mac: Message.Hello) {
        if (mac.name.isNotBlank()) store.updateMacName(mac.name)
        val name = store.pairedMac()?.name
        _status.update {
            it.copy(
                paired = true,
                macName = name,
                link = if (session.transport == Transport.WIFI) Link.WIFI else Link.BLUETOOTH,
            )
        }
        scope.launch { flush(session) }
    }

    override suspend fun onClip(session: Session, clip: Message.Clip): Boolean {
        if (clip.id in receivedIds) return true
        val stored = try {
            incoming.store(clip)
        } catch (e: Exception) {
            Log.w(TAG, "could not store clip", e)
            return false
        }
        receivedIds.addLast(clip.id)
        while (receivedIds.size > Limits.DEDUPE_WINDOW) receivedIds.removeFirst()
        store.saveReceivedIds(receivedIds.toList())
        lastReceivedFingerprint = fingerprint(clip.kind, clip.body)

        val (preview, text, uri) = when (stored) {
            is IncomingClips.Stored.Text -> Triple(stored.text.trim().take(300), stored.text.take(HistoryItem.MAX_TEXT), null)
            is IncomingClips.Stored.Image -> Triple(clip.name ?: "Image", null, stored.uri.toString())
            is IncomingClips.Stored.File -> Triple(stored.name, null, stored.uri.toString())
        }
        history.add(
            HistoryItem(
                id = clip.id,
                direction = Direction.RECEIVED,
                kind = clip.kind,
                mime = clip.mime,
                name = clip.name,
                size = clip.size,
                preview = preview,
                text = text,
                uri = uri,
                timeMillis = System.currentTimeMillis(),
                state = DeliveryState.DELIVERED,
            ),
        )
        if (stored is IncomingClips.Stored.File) notifications.fileReceived(stored.uri, stored.name, clip.mime)
        return true
    }

    override suspend fun onAck(session: Session, id: String) {
        val removed = outboxLock.withLock { outbox.removeAll { it.id == id } }
        if (removed) history.update(id) { it.copy(state = DeliveryState.DELIVERED, waitingForWifi = false) }
    }

    override suspend fun onUnpair(session: Session) {
        scope.launch { forget() }
    }

    // endregion

    // region connection

    private suspend fun connectionLoop() {
        var backoff = MIN_BACKOFF
        while (true) {
            val mac = store.pairedMac() ?: return
            if (_status.value.link != Link.WIFI && _status.value.link != Link.BLUETOOTH) setLink(Link.SEARCHING)

            val tcp = findTcp(mac)
            val startedAt = System.currentTimeMillis()
            if (tcp != null) {
                runSession(tcp, mac)
            } else {
                val blePipe = connectBle()
                if (blePipe != null) {
                    val handover = runBleSession(blePipe, mac)
                    if (handover != null) runSession(handover, mac)
                } else {
                    setLink(Link.OFFLINE)
                    withTimeoutOrNull(backoff) { kick.receive() }
                    backoff = (backoff * 2).coerceAtMost(MAX_BACKOFF)
                    continue
                }
            }
            setLink(Link.SEARCHING)
            if (System.currentTimeMillis() - startedAt < 10_000) {
                // The link died right away (e.g. the Mac rejected us); don't spin.
                withTimeoutOrNull(backoff) { kick.receive() }
                backoff = (backoff * 2).coerceAtMost(MAX_BACKOFF)
            } else {
                backoff = MIN_BACKOFF
            }
        }
    }

    private suspend fun runSession(pipe: BytePipe, mac: PairedMac) {
        val s = Session(pipe, store.deviceId, deviceName(), mac.id, mac.secret, this)
        session = s
        try {
            s.run()
        } catch (e: Exception) {
            Log.i(TAG, "session ended: ${e.message}")
        } finally {
            if (session === s) session = null
            markInFlightQueued()
        }
    }

    /** Runs a BLE session and retries TCP every 30 s; returns a TCP pipe if one took over. */
    private suspend fun runBleSession(pipe: BytePipe, mac: PairedMac): TcpPipe? = coroutineScope {
        var handover: TcpPipe? = null
        val s = Session(pipe, store.deviceId, deviceName(), mac.id, mac.secret, this@CompanionController)
        session = s
        val retry = launch {
            while (true) {
                withTimeoutOrNull(Limits.BLE_TCP_RETRY_MS) { kick.receive() }
                val tcp = findTcp(mac)
                if (tcp != null) {
                    handover = tcp
                    s.close()
                    break
                }
            }
        }
        try {
            s.run()
        } catch (e: Exception) {
            Log.i(TAG, "BLE session ended: ${e.message}")
        } finally {
            retry.cancelAndJoin()
            if (session === s) session = null
            markInFlightQueued()
        }
        handover
    }

    private suspend fun markInFlightQueued() {
        val ids = outboxLock.withLock {
            outbox.onEach { it.sentOn = null }.map { it.id }
        }
        ids.forEach { id -> history.update(id) { if (it.state == DeliveryState.SENDING) it.copy(state = DeliveryState.QUEUED) else it } }
    }

    private suspend fun findTcp(mac: PairedMac): TcpPipe? {
        for (host in mac.hosts) {
            val pipe = runCatching { TcpPipe.connect(host, mac.port, Limits.CONNECT_TIMEOUT_MS) }.getOrNull()
            if (pipe != null) {
                store.rememberEndpoint(host, mac.port)
                return pipe
            }
        }
        val endpoint = nsd.find(mac.id, NSD_TIMEOUT_MS) ?: return null
        val pipe = runCatching { TcpPipe.connect(endpoint.host, endpoint.port, Limits.CONNECT_TIMEOUT_MS) }.getOrNull()
        if (pipe != null) store.rememberEndpoint(endpoint.host, endpoint.port)
        return pipe
    }

    private suspend fun connectBle(): BytePipe? {
        if (!hasBlePermissions() || !ble.isAvailable()) return null
        val device = ble.findMac(BLE_SCAN_MS) ?: return null
        return runCatching { BlePipe.connect(app, device) }
            .onFailure { Log.i(TAG, "BLE connect failed: ${it.message}") }
            .getOrNull()
    }

    private fun hasBlePermissions(): Boolean {
        val perms = if (Build.VERSION.SDK_INT >= 31) {
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        return perms.all { app.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    }

    private fun setLink(link: Link) = _status.update { it.copy(link = link, macName = store.pairedMac()?.name ?: it.macName) }

    private fun registerNetworkCallback() {
        if (networkCallback != null) return
        val cm = app.getSystemService(ConnectivityManager::class.java) ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                kick.trySend(Unit)
            }
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .build()
        runCatching { cm.registerNetworkCallback(request, cb) }.onSuccess { networkCallback = cb }
    }

    private fun unregisterNetworkCallback() {
        val cb = networkCallback ?: return
        runCatching { app.getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(cb) }
        networkCallback = null
    }

    fun deviceName(): String =
        Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: Build.MODEL

    // endregion

    companion object {
        private const val TAG = "FrogCompanion"
        private const val MIN_BACKOFF = 3_000L
        private const val MAX_BACKOFF = 60_000L
        private const val NSD_TIMEOUT_MS = 4_000L
        private const val BLE_SCAN_MS = 10_000L
    }
}
