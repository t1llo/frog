package xyz.beffa.frog.companion.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class HkdfTest {
    @Test
    fun rfc5869_case1() {
        val okm = Hkdf.derive(
            ikm = ByteArray(22) { 0x0b },
            salt = hex("000102030405060708090a0b0c"),
            info = hex("f0f1f2f3f4f5f6f7f8f9"),
            length = 42,
        )
        assertEquals(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
            okm.hex(),
        )
    }

    @Test
    fun rfc5869_case2_longInputs() {
        val okm = Hkdf.derive(
            ikm = ByteArray(80) { it.toByte() },
            salt = ByteArray(80) { (0x60 + it).toByte() },
            info = ByteArray(80) { (0xb0 + it).toByte() },
            length = 82,
        )
        assertEquals(
            "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c" +
                "59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71" +
                "cc30c58179ec3e87c14c01d5c1f3434f1d87",
            okm.hex(),
        )
    }

    @Test
    fun rfc5869_case3_emptySaltAndInfo() {
        val okm = Hkdf.derive(ByteArray(22) { 0x0b }, ByteArray(0), ByteArray(0), 42)
        assertEquals(
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8",
            okm.hex(),
        )
    }
}
