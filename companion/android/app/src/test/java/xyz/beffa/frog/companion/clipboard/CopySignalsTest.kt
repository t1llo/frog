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
}
