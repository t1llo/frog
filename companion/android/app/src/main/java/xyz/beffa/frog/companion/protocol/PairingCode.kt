package xyz.beffa.frog.companion.protocol

import java.io.ByteArrayOutputStream
import java.util.Base64
import java.util.UUID

/** Contents of the pairing QR code (docs/companion-protocol.md section 1). */
data class PairingCode(
    val macId: UUID,
    val macName: String,
    val secret: ByteArray,
    val port: Int,
    val hosts: List<String>,
) {
    companion object {
        private const val PREFIX = "frog://pair?"

        /** Returns null for anything that is not a valid v=1 Frog Companion pairing URL. */
        fun parse(text: String): PairingCode? {
            val trimmed = text.trim()
            if (!trimmed.startsWith(PREFIX, ignoreCase = true)) return null
            val query = trimmed.substring(PREFIX.length).substringBefore('#')
            val params = HashMap<String, String>()
            for (part in query.split('&')) {
                if (part.isEmpty()) continue
                val key = percentDecode(part.substringBefore('=')) ?: return null
                val value = percentDecode(part.substringAfter('=', "")) ?: return null
                params.putIfAbsent(key, value)
            }
            if (params["v"] != "1") return null
            val id = params["id"]?.let(Uuids::parse) ?: return null
            val secret = params["k"]?.let(::decodeBase64Url) ?: return null
            if (secret.size != 32) return null
            val port = params["p"]?.takeIf { it.isNotEmpty() }?.let { it.toIntOrNull() ?: return null }
                ?: Limits.TCP_PORT
            if (port !in 1..65535) return null
            val hosts = params["h"].orEmpty().split(',').map { it.trim() }.filter { isIpv4(it) }
            val name = params["n"]?.takeIf { it.isNotBlank() } ?: "Mac"
            return PairingCode(id, name, secret, port, hosts)
        }

        fun decodeBase64Url(s: String): ByteArray? = try {
            Base64.getUrlDecoder().decode(s.trimEnd('='))
        } catch (_: IllegalArgumentException) {
            null
        }

        fun encodeBase64Url(bytes: ByteArray): String =
            Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

        /** RFC 3986 percent-decoding. '+' stays a literal plus. Null on malformed input. */
        fun percentDecode(s: String): String? {
            if ('%' !in s) return s
            val out = ByteArrayOutputStream(s.length)
            var i = 0
            while (i < s.length) {
                val c = s[i]
                if (c == '%') {
                    if (i + 2 >= s.length) return null
                    val hi = Character.digit(s[i + 1], 16)
                    val lo = Character.digit(s[i + 2], 16)
                    if (hi < 0 || lo < 0) return null
                    out.write(hi * 16 + lo)
                    i += 3
                } else {
                    out.write(c.toString().toByteArray(Charsets.UTF_8))
                    i++
                }
            }
            return out.toByteArray().toString(Charsets.UTF_8)
        }

        private fun isIpv4(s: String): Boolean {
            val parts = s.split('.')
            return parts.size == 4 && parts.all { p -> p.isNotEmpty() && p.length <= 3 && p.all(Char::isDigit) && p.toInt() <= 255 }
        }
    }

    override fun equals(other: Any?): Boolean =
        other is PairingCode && macId == other.macId && macName == other.macName &&
            secret.contentEquals(other.secret) && port == other.port && hosts == other.hosts

    override fun hashCode(): Int = macId.hashCode()
}
