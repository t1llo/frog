package xyz.beffa.frog.companion.protocol

/** c2s and s2c keys from docs/companion-protocol.md section 3. */
class SessionKeys(val c2sKey: ByteArray, val s2cKey: ByteArray) {
    companion object {
        private val INFO_C2S = "frog-companion/v1/c2s".toByteArray(Charsets.US_ASCII)
        private val INFO_S2C = "frog-companion/v1/s2c".toByteArray(Charsets.US_ASCII)

        fun derive(secret: ByteArray, clientNonce: ByteArray, serverNonce: ByteArray): SessionKeys {
            require(clientNonce.size == Handshake.NONCE_SIZE && serverNonce.size == Handshake.NONCE_SIZE)
            val salt = clientNonce + serverNonce
            return SessionKeys(
                c2sKey = Hkdf.derive(secret, salt, INFO_C2S, 32),
                s2cKey = Hkdf.derive(secret, salt, INFO_S2C, 32),
            )
        }
    }
}
