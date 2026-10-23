package com.assemblyai.blurt.android

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Android's equivalent of the Mac app's Accessibility reads and paste: finds
 * the field with input focus, reads the text before the cursor, and inserts
 * the dictation at the cursor.
 *
 * It listens for one thing, windows coming and going, to publish whether a
 * keyboard is on screen ([keyboardVisible]) so the bubble shows only while
 * you're typing. Otherwise it is asked, at the start of a dictation and at the
 * end, through [instance] — the system binds it while the user has it turned
 * on in Settings › Accessibility.
 */
class BlurtAccessibilityService : AccessibilityService() {

    override fun onServiceConnected() {
        instance = this
        _connected.value = true
        publishKeyboard()
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        _connected.value = false
        _keyboardVisible.value = false
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED) publishKeyboard()
    }

    /** A keyboard is up exactly when an input-method window is on screen. */
    private fun publishKeyboard() {
        _keyboardVisible.value = windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
    }

    override fun onInterrupt() = Unit

    /** The field being edited, searched across every window (see accessibility_service.xml). */
    private fun focusedField(): AccessibilityNodeInfo? =
        findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.takeIf { it.isEditable }

    /** Up to [limit] characters before the cursor, or "" when nothing is readable. */
    fun textBeforeCursor(limit: Int = 1000): String {
        val field = focusedField() ?: return ""
        if (field.isPassword) return ""
        val contents = contents(field) ?: return ""
        return contents.before.takeLast(limit)
    }

    /**
     * Inserts [dictation] at the cursor, replacing any selection, with a space
     * on either side where the neighbouring text needs one. Returns false when
     * there is no field to type into, so the caller can fall back to the clipboard.
     */
    fun insert(dictation: String): Boolean {
        val field = focusedField() ?: return false
        // A password field reports its text masked, so setting text from it
        // would replace the real contents with bullets. A field that reports no
        // cursor can't be trusted to report its text either (see [contents]).
        // Both get a paste, which the app itself puts at its own cursor.
        if (field.isPassword) return paste(field, dictation.trim())
        val contents = contents(field) ?: return paste(field, dictation.trim())
        val piece = Spacing.join(contents.before, dictation, contents.after)
        val arguments = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                contents.before + piece + contents.after,
            )
        }
        // Web views and some custom editors refuse SET_TEXT; paste works in more of them.
        if (!field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)) {
            return paste(field, piece)
        }
        val cursor = contents.before.length + piece.length
        field.performAction(
            AccessibilityNodeInfo.ACTION_SET_SELECTION,
            Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, cursor)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, cursor)
            },
        )
        return true
    }

    private fun paste(field: AccessibilityNodeInfo, text: String): Boolean {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Blurt", text))
        return field.performAction(AccessibilityNodeInfo.ACTION_PASTE)
    }

    /** A field's text split at its selection: what's before it and what's after. */
    private class Contents(val before: String, val after: String)

    /**
     * The field's text around the selection, or null when the field doesn't
     * report a cursor. That null is the tell for a placeholder passed off as
     * text: Telegram's empty message box reports "Message" as its text, with no
     * hint and no showing-hint flag, but with its selection at -1 — a real empty
     * field reports a cursor at 0. Guessing a cursor there (the end, say) is how
     * "Message" ended up in front of every dictation.
     *
     * Apps that do flag their placeholder, or report it as the hint too, are
     * caught by the first two checks.
     */
    private fun contents(field: AccessibilityNodeInfo): Contents? {
        val raw = field.text?.toString().orEmpty()
        val hint = field.hintText?.toString()
        val text = if (field.isShowingHintText || (hint != null && raw == hint)) "" else raw
        val start = field.textSelectionStart
        val end = field.textSelectionEnd
        if (start !in 0..text.length || end !in 0..text.length) return null
        return Contents(text.substring(0, minOf(start, end)), text.substring(maxOf(start, end)))
    }

    companion object {
        @Volatile var instance: BlurtAccessibilityService? = null
            private set

        private val _connected = MutableStateFlow(false)
        /** Whether the user has the service turned on (and the system has bound it). */
        val connected: StateFlow<Boolean> = _connected

        private val _keyboardVisible = MutableStateFlow(false)
        val keyboardVisible: StateFlow<Boolean> = _keyboardVisible
    }
}

/** The spacing rule around an insertion (`InsertionSeparator` on the Mac, simplified). */
object Spacing {
    private const val NO_SPACE_BEFORE = ".,!?;:)]}'\"…"

    fun join(before: String, dictation: String, after: String): String {
        val text = dictation.trim()
        if (text.isEmpty()) return text
        val lead = if (before.isNotEmpty() && !before.last().isWhitespace() &&
            text.first() !in NO_SPACE_BEFORE
        ) " " else ""
        val trail = if (after.isNotEmpty() && !after.first().isWhitespace() &&
            after.first() !in NO_SPACE_BEFORE
        ) " " else ""
        return lead + text + trail
    }
}
