package com.assemblyai.blurt.android

import android.Manifest
import android.annotation.SuppressLint
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import android.view.animation.OvershootInterpolator
import android.widget.Toast
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.hypot

/**
 * The always-on bubble: a microphone foreground service that floats a
 * [BubbleView] over every app.
 *
 * Tap to start dictating, tap again to stop; the words land in the focused
 * field (through [BlurtAccessibilityService]) or, without it, on the
 * clipboard. Long-press cancels a dictation, or opens Blurt when idle. Drag to
 * move; it snaps to the nearer edge.
 *
 * The overlay is not focusable, so tapping it leaves the keyboard and the
 * field's focus where they were — that is what lets the words go back in.
 */
class BubbleService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var windowManager: WindowManager
    private lateinit var bubble: BubbleView
    private lateinit var params: WindowManager.LayoutParams

    private var typing = true
    private var snap: ValueAnimator? = null

    /**
     * Gap between the bubble's view and the screen edge, on top of the room
     * the view already keeps around the logo for the recording halo.
     */
    private val edgeMarginPx by lazy { (10 * resources.displayMetrics.density).toInt() }
    private var recorder: MicRecorder? = null
    private var upload: Deferred<String>? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startForeground(
            NOTIFICATION_ID,
            notification(),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
        )
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        showBubble()
        _running.value = true
        scope.launch {
            combine(BlurtAccessibilityService.connected, BlurtAccessibilityService.keyboardVisible) { connected, keyboard ->
                // Without the accessibility service there's no way to know when
                // you're typing, so the bubble stays up.
                !connected || keyboard
            }.collect { typing ->
                this@BubbleService.typing = typing
                updateVisibility()
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) stopSelf()
        // Not sticky: a service the system restarts in the background isn't
        // allowed the microphone, so it comes back only when the user turns it on.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        recorder?.stop()
        snap?.cancel()
        scope.cancel()
        if (::bubble.isInitialized) windowManager.removeView(bubble)
        _running.value = false
        super.onDestroy()
    }

    // dictation

    private fun setState(state: BubbleView.State) {
        bubble.state = state
        updateVisibility()
    }

    /**
     * Shown while you're typing, the way Wispr Flow's is, and kept up for the
     * whole of a dictation even if the keyboard closes under it.
     */
    private fun updateVisibility() {
        val show = typing || bubble.state != BubbleView.State.Idle
        bubble.visibility = if (show) android.view.View.VISIBLE else android.view.View.GONE
    }

    private fun toggle() {
        when (bubble.state) {
            BubbleView.State.Idle -> startDictation()
            BubbleView.State.Recording -> finishDictation()
            BubbleView.State.Transcribing -> Unit
        }
    }

    private fun startDictation() {
        val apiKey = ApiKeyStore.load(this)
        if (apiKey.isNullOrBlank()) {
            toast("Add your AssemblyAI API key in Blurt first")
            openApp()
            return
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            toast("Blurt needs the microphone")
            openApp()
            return
        }
        // Read at the press, while the field the user means is still focused.
        val context = BlurtAccessibilityService.instance?.textBeforeCursor().orEmpty()
        val mic = MicRecorder { level -> bubble.post { bubble.level = level } }
        val frames = mic.start(scope)
        recorder = mic
        // The style is read per dictation, so a change in the app applies to the next one.
        val instruction = CleanupInstruction.withStyle(StyleStore.instructions(this))
        upload = scope.async { DictationClient(apiKey, instruction).transcribe(frames, context) }
        setState(BubbleView.State.Recording)
        bubble.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
    }

    private fun finishDictation() {
        val mic = recorder ?: return
        val pending = upload ?: return
        mic.stop()
        recorder = null
        upload = null
        bubble.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        if (mic.bytesRecorded < MicRecorder.MIN_BYTES) {
            pending.cancel()
            setState(BubbleView.State.Idle)
            return
        }
        setState(BubbleView.State.Transcribing)
        scope.launch {
            try {
                val text = pending.await().trim()
                if (text.isNotEmpty()) deliver(text)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                toast(e.message ?: "Dictation failed")
            } finally {
                setState(BubbleView.State.Idle)
            }
        }
    }

    private fun cancelDictation() {
        recorder?.stop()
        upload?.cancel()
        recorder = null
        upload = null
        setState(BubbleView.State.Idle)
        bubble.performHapticFeedback(HapticFeedbackConstants.REJECT)
    }

    private fun deliver(text: String) {
        if (BlurtAccessibilityService.instance?.insert(text) == true) return
        val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Blurt", text))
        toast("Copied — paste it where you want it")
    }

    // the overlay

    @SuppressLint("ClickableViewAccessibility")
    private fun showBubble() {
        bubble = BubbleView(this)
        val screen = windowManager.currentWindowMetrics.bounds
        params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = screen.width() - bubble.sizePx - edgeMarginPx
            y = (screen.height() * 0.4).toInt()
        }
        bubble.contentDescription = "Blurt dictation"
        bubble.setOnClickListener { toggle() }
        bubble.setOnTouchListener(DragOrTap())
        windowManager.addView(bubble, params)
    }

    /** Tells a tap, a long-press, and a drag apart on the bubble. */
    private inner class DragOrTap : android.view.View.OnTouchListener {
        private val slop = ViewConfiguration.get(this@BubbleService).scaledTouchSlop
        private val longPressMs = ViewConfiguration.getLongPressTimeout().toLong()
        private var downX = 0f
        private var downY = 0f
        private var startX = 0
        private var startY = 0
        private var dragging = false
        private var longPressed = false
        private var lastTickX = 0f
        private var lastTickY = 0f
        private val tickDistance = 32 * resources.displayMetrics.density
        private val longPress = Runnable {
            longPressed = true
            if (bubble.state == BubbleView.State.Idle) openApp() else cancelDictation()
        }

        override fun onTouch(view: android.view.View, event: MotionEvent): Boolean {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    snap?.cancel()
                    downX = event.rawX
                    downY = event.rawY
                    startX = params.x
                    startY = params.y
                    dragging = false
                    longPressed = false
                    view.postDelayed(longPress, longPressMs)
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downX
                    val dy = event.rawY - downY
                    if (!dragging && (abs(dx) > slop || abs(dy) > slop)) {
                        dragging = true
                        view.removeCallbacks(longPress)
                        // Picked up.
                        view.performHapticFeedback(HapticFeedbackConstants.GESTURE_START)
                        lastTickX = event.rawX
                        lastTickY = event.rawY
                    }
                    if (dragging) {
                        // A light tick every so often while it moves, like a detent.
                        if (hypot(event.rawX - lastTickX, event.rawY - lastTickY) >= tickDistance) {
                            view.performHapticFeedback(dragTick)
                            lastTickX = event.rawX
                            lastTickY = event.rawY
                        }
                        params.x = startX + dx.toInt()
                        params.y = startY + dy.toInt()
                        windowManager.updateViewLayout(bubble, params)
                    }
                }
                MotionEvent.ACTION_UP -> {
                    view.removeCallbacks(longPress)
                    when {
                        dragging -> snapToEdge(haptic = true)
                        !longPressed -> view.performClick()
                    }
                }
                MotionEvent.ACTION_CANCEL -> view.removeCallbacks(longPress)
            }
            return true
        }
    }

    /**
     * Glides to the nearer side edge, kept clear of the status and navigation
     * bars, and lands with a tap when [haptic] (a drop, as opposed to a refold).
     */
    private fun snapToEdge(haptic: Boolean) {
        val metrics = windowManager.currentWindowMetrics
        val bounds = metrics.bounds
        val bars = metrics.windowInsets.getInsets(WindowInsets.Type.systemBars())
        val left = edgeMarginPx
        val right = bounds.width() - bubble.sizePx - edgeMarginPx
        val targetX = if (params.x + bubble.sizePx / 2 < bounds.width() / 2) left else right
        val targetY = params.y.coerceIn(
            bars.top + edgeMarginPx,
            (bounds.height() - bars.bottom - bubble.sizePx - edgeMarginPx).coerceAtLeast(bars.top),
        )
        val fromX = params.x
        val fromY = params.y
        snap?.cancel()
        snap = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 260
            interpolator = OvershootInterpolator(1.1f)
            addUpdateListener {
                val t = it.animatedValue as Float
                params.x = (fromX + (targetX - fromX) * t).toInt()
                params.y = (fromY + (targetY - fromY) * t).toInt()
                if (bubble.isAttachedToWindow) windowManager.updateViewLayout(bubble, params)
            }
            if (haptic) {
                addListener(object : AnimatorListenerAdapter() {
                    override fun onAnimationEnd(animation: Animator) {
                        bubble.performHapticFeedback(HapticFeedbackConstants.GESTURE_END)
                    }
                })
            }
            start()
        }
    }

    // Folding or unfolding changes the screen under the bubble; put it back on an edge.
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (::bubble.isInitialized) bubble.post { snapToEdge(haptic = false) }
    }

    private val dragTick =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            HapticFeedbackConstants.SEGMENT_FREQUENT_TICK
        } else {
            HapticFeedbackConstants.CLOCK_TICK
        }

    // plumbing

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Bubble", NotificationManager.IMPORTANCE_LOW),
        )
        val stop = PendingIntent.getService(
            this, 0,
            Intent(this, BubbleService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Blurt is ready")
            .setContentText("Tap the bubble to dictate")
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Turn off", stop).build())
            .setOngoing(true)
            .build()
    }

    private fun openApp() {
        startActivity(
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "bubble"
        private const val ACTION_STOP = "com.assemblyai.blurt.android.STOP"

        private val _running = MutableStateFlow(false)
        val running: StateFlow<Boolean> = _running

        /** Call from the app while it is in front; see the manifest for why. */
        fun start(context: Context) {
            context.startForegroundService(Intent(context, BubbleService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, BubbleService::class.java))
        }
    }
}
