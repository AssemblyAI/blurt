package com.assemblyai.blurt.android

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.os.SystemClock
import android.view.View

/**
 * The floating button: the Blurt logo. Three looks: idle (the logo), recording
 * (a green halo around it that follows the voice), and transcribing (the logo
 * dimmed under a spinning arc).
 */
class BubbleView(context: Context) : View(context) {

    enum class State { Idle, Recording, Transcribing }

    var state = State.Idle
        set(value) {
            field = value
            if (value != State.Recording) level = 0f
            invalidate()
        }

    /** 0–1, from [MicRecorder]'s frames; eased so the halo doesn't flicker. */
    var level = 0f
        set(value) {
            field = field * 0.6f + value * 0.4f
            invalidate()
        }

    private val density = resources.displayMetrics.density
    private val discRadius = 26 * density
    private val haloReach = 10 * density

    private val logo = BitmapFactory.decodeResource(resources, R.drawable.blurt_bubble)
    private val logoSource = Rect(0, 0, logo.width, logo.height)
    private val logoBounds = RectF()
    private val logoPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val shadow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        // Opaque so the shadow draws; the logo covers it exactly.
        color = 0xFF1C1C1E.toInt()
        setShadowLayer(4 * density, 0f, 2 * density, 0x55000000)
    }
    private val halo = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = GREEN }
    private val arc = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 3 * density
        strokeCap = Paint.Cap.ROUND
        color = 0xFFFFFFFF.toInt()
    }
    private val arcBounds = RectF()

    /** The view's side: the disc plus room for the halo at full voice. */
    val sizePx = ((discRadius + haloReach) * 2).toInt()

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(sizePx, sizePx)
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f

        if (state == State.Recording) {
            halo.alpha = (90 + 140 * level).toInt()
            canvas.drawCircle(cx, cy, discRadius + haloReach * (0.35f + 0.65f * level), halo)
        }

        canvas.drawCircle(cx, cy, discRadius, shadow)
        logoBounds.set(cx - discRadius, cy - discRadius, cx + discRadius, cy + discRadius)
        logoPaint.alpha = if (state == State.Transcribing) 120 else 255
        canvas.drawBitmap(logo, logoSource, logoBounds, logoPaint)

        if (state == State.Transcribing) {
            val inset = discRadius - 4 * density
            arcBounds.set(cx - inset, cy - inset, cx + inset, cy + inset)
            val sweepStart = (SystemClock.uptimeMillis() % 1000) * 0.36f
            canvas.drawArc(arcBounds, sweepStart, 90f, false, arc)
            postInvalidateOnAnimation()
        }
    }

    private companion object {
        // The b's own green (`app/accent-dark`, App/BlurtiOS/DESIGN.md).
        const val GREEN = 0xFF67AD82.toInt()
    }
}
