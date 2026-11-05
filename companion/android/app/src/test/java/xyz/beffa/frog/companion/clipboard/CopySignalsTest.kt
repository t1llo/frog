package xyz.beffa.frog.companion.clipboard

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CopySignalsTest {
    @Test
    fun copyButtonsAndMenuItemsCount() {
        listOf("Copy", "copy", " Copy code ", "Kopieren", "Copier", "Copiar", "コピー", "Copy…", "Copy to clipboard").forEach {
            assertTrue(it, CopySignals.isCopyLabel(it))
        }
    }

    @Test
    fun otherLabelsDoNot() {
        listOf(null, "", "Cut", "Paste", "Copyright", "Copy of report.pdf", "Share", "Copies left: 3").forEach {
            assertFalse(it.toString(), CopySignals.isCopyLabel(it))
        }
    }

    @Test
    fun copiedMessagesInSeveralLanguages() {
        listOf("Code copied", "Copied to clipboard", "In die Zwischenablage kopiert", "Copié dans le presse-papiers", "Copiado", "已复制")
            .forEach { assertTrue(it, CopySignals.isCopiedMessage(it)) }
        assertFalse(CopySignals.isCopiedMessage("Message sent"))
    }

    @Test
    fun androidsClipboardReadNoticeIsNotACopy() {
        listOf(
            "Frog Companion pasted from your clipboard",
            "Frog Companion hat etwas aus der Zwischenablage eingefügt",
            "Frog Companion a collé du contenu depuis le presse-papiers",
        ).forEach { assertFalse(it, CopySignals.isCopiedMessage(it)) }
    }

    @Test
    fun clipboardOverlayPreviewIsTellingApartFromOtherSystemWindows() {
        assertTrue(CopySignals.isOverlayPreview("482 913"))
        assertTrue(CopySignals.isOverlayPreview("https://example.com/a"))
        assertFalse(CopySignals.isOverlayPreview(""))
        assertFalse(CopySignals.isOverlayPreview("Notification shade."))
        assertFalse(CopySignals.isOverlayPreview("Volume dialog"))
        assertFalse(CopySignals.isOverlayPreview("Quick settings"))
    }
}
