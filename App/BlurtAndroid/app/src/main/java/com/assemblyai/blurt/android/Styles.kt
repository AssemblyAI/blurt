package com.assemblyai.blurt.android

import android.content.Context

/**
 * Output styles: a few words of instruction appended to the cleanup rewrite,
 * the way the Mac and iPhone apps do it (`CleanupInstruction.sendable(appending:)`
 * in the engine). The presets' wording is a verbatim copy of
 * `App/BlurtiOS/BlurtiOSCore/StylePreset.swift`; change it there first.
 */
enum class Style(val label: String, val instructions: String?) {
    None("None", null),
    Professional(
        "Professional",
        "Use a clear, polished, professional tone suitable for work email. Write complete sentences " +
            "with standard capitalization and punctuation. No slang and no emojis.",
    ),
    Casual(
        "Casual",
        "Use a relaxed, friendly tone, like a message to a coworker you get along with. Contractions " +
            "are fine. Keep standard capitalization and punctuation. No emojis.",
    ),
    Ultracasual(
        "Ultracasual",
        "Write like a quick text to a close friend: all lowercase, light punctuation, and no period " +
            "at the end. Keep it short and natural. An emoji is fine when it fits.",
    ),
    Custom("Custom", null),
}

/** The chosen style and the custom one's text, in the app's preferences. */
object StyleStore {
    private const val PREFS = "blurt"
    private const val STYLE = "style"
    private const val CUSTOM = "style_custom"

    fun selected(context: Context): Style =
        prefs(context).getString(STYLE, null)
            ?.let { name -> Style.entries.firstOrNull { it.name == name } }
            ?: Style.None

    fun select(context: Context, style: Style) {
        prefs(context).edit().putString(STYLE, style.name).apply()
    }

    fun custom(context: Context): String = prefs(context).getString(CUSTOM, "").orEmpty()

    fun setCustom(context: Context, text: String) {
        prefs(context).edit().putString(CUSTOM, text.take(CleanupInstruction.STYLE_BUDGET)).apply()
    }

    /** The instructions the next dictation should carry, or null for none. */
    fun instructions(context: Context): String? =
        when (val style = selected(context)) {
            Style.Custom -> custom(context).takeIf { it.isNotBlank() }
            else -> style.instructions
        }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
