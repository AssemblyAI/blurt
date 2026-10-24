package com.assemblyai.blurt.android

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

/**
 * Setup, in the order the bubble needs it: an account (signed in, or a
 * pasted API key), the microphone,
 * drawing over other apps, and (optional) typing into them. Then one switch
 * turns the bubble on.
 */
class MainActivity : ComponentActivity() {

    // Bumped on every resume so the checklist re-reads permissions the user
    // just granted in Settings.
    private val resumes = mutableIntStateOf(0)
    private val keyChanges = mutableIntStateOf(0)
    private val accountBusy = mutableStateOf(false)
    private val accountError = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { BlurtTheme { SetupScreen(resumes.intValue) } }
        handleSignInRedirect(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleSignInRedirect(intent)
    }

    override fun onResume() {
        super.onResume()
        resumes.intValue++
        Account.refreshStatus(this)
        lifecycleScope.launch {
            Account.renewIfDue(applicationContext)
            keyChanges.intValue++
        }
    }

    /** Opens AssemblyAI's consent page in a browser tab; the redirect comes back to [onNewIntent]. */
    private fun signIn() {
        val url = Account.beginSignIn(this) ?: return
        accountError.value = null
        CustomTabsIntent.Builder().build().launchUrl(this, url)
    }

    private fun handleSignInRedirect(intent: Intent?) {
        val callback = intent?.data ?: return
        if (!callback.toString().startsWith(OAuthConfig.REDIRECT_URI)) return
        // Consumed, so a recreated activity doesn't replay it.
        intent.data = null
        accountBusy.value = true
        accountError.value = null
        lifecycleScope.launch {
            when (val outcome = Account.completeSignIn(applicationContext, callback)) {
                is Account.Outcome.Failed -> accountError.value = outcome.message
                Account.Outcome.Cancelled, Account.Outcome.SignedIn -> Unit
            }
            accountBusy.value = false
            keyChanges.intValue++
        }
    }

    private fun signOut() {
        accountBusy.value = true
        accountError.value = null
        lifecycleScope.launch {
            accountError.value = Account.signOut(applicationContext)
            accountBusy.value = false
            keyChanges.intValue++
        }
    }

    @Composable
    private fun SetupScreen(resumeCount: Int) {
        val signedIn = Account.status.collectAsState().value
        // Re-read whenever a key is saved, cleared, signed in or out.
        val hasKey = (keyChanges.intValue + resumeCount).let { ApiKeyStore.load(this) != null }
        var keyDraft by remember { mutableStateOf("") }
        var micTick by remember { mutableIntStateOf(0) }
        var showTypingDisclosure by remember { mutableStateOf(false) }
        val bubbleOn by BubbleService.running.collectAsState()

        // Re-read on resume and after the permission dialog.
        val hasMic = (resumeCount + micTick).let { granted(Manifest.permission.RECORD_AUDIO) }
        val canOverlay = resumeCount.let { Settings.canDrawOverlays(this) }
        val canType = resumeCount.let { accessibilityEnabled() }

        val askMic = rememberLauncherForActivityResult(
            ActivityResultContracts.RequestMultiplePermissions(),
        ) { micTick++ }

        if (showTypingDisclosure) {
            TypingDisclosure(
                onAgree = {
                    showTypingDisclosure = false
                    open(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                },
                onDecline = { showTypingDisclosure = false },
            )
        }

        Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(
                modifier = Modifier
                    .safeDrawingPadding()
                    .verticalScroll(rememberScrollState())
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Image(
                        painter = painterResource(R.drawable.blurt_logo),
                        contentDescription = null,
                        modifier = Modifier.size(48.dp),
                    )
                    Text("Blurt", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
                }
                Text(
                    "Tap the bubble, speak, tap again. Your words land in whatever you're typing in.",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(4.dp))

                Step(
                    number = 1,
                    title = "Your AssemblyAI account",
                    done = hasKey,
                    detail = when {
                        signedIn is Account.Status.SignedIn ->
                            signedIn.email?.let { "Signed in as $it." } ?: "Signed in."
                        hasKey -> "Your API key is saved on this phone, encrypted."
                        else -> "Blurt sends your voice to AssemblyAI with your own account."
                    },
                ) {
                    when {
                        signedIn is Account.Status.SignedIn -> OutlinedButton(
                            onClick = { signOut() },
                            enabled = !accountBusy.value,
                        ) { Text("Sign out") }
                        hasKey -> TextButton(onClick = {
                            ApiKeyStore.clear(this@MainActivity)
                            keyChanges.intValue++
                        }) { Text("Replace key") }
                        else -> {
                            if (Account.isAvailable) {
                                Button(
                                    onClick = { signIn() },
                                    enabled = !accountBusy.value,
                                    modifier = Modifier.fillMaxWidth(),
                                ) { Text(if (accountBusy.value) "Signing in…" else "Sign in with AssemblyAI") }
                                Text(
                                    "Or paste an API key:",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            OutlinedTextField(
                                value = keyDraft,
                                onValueChange = { keyDraft = it },
                                label = { Text("Paste your key") },
                                singleLine = true,
                                visualTransformation = PasswordVisualTransformation(),
                                modifier = Modifier.fillMaxWidth(),
                            )
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Button(
                                    onClick = {
                                        ApiKeyStore.save(this@MainActivity, keyDraft)
                                        keyDraft = ""
                                        keyChanges.intValue++
                                    },
                                    enabled = keyDraft.isNotBlank(),
                                ) { Text("Save") }
                                TextButton(onClick = {
                                    open(Intent(Intent.ACTION_VIEW, Uri.parse(KEYS_URL)))
                                }) { Text("Get a key") }
                            }
                        }
                    }
                    accountError.value?.let {
                        Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
                    }
                }

                Step(
                    number = 2,
                    title = "Microphone",
                    done = hasMic,
                    detail = "Only while you're dictating.",
                ) {
                    if (!hasMic) {
                        Button(onClick = {
                            // The notification is the bubble's off switch; Android 13 made it a permission.
                            val notifications = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                listOf(Manifest.permission.POST_NOTIFICATIONS)
                            } else {
                                emptyList()
                            }
                            askMic.launch((listOf(Manifest.permission.RECORD_AUDIO) + notifications).toTypedArray())
                        }) { Text("Allow") }
                    }
                }

                Step(
                    number = 3,
                    title = "Display over other apps",
                    done = canOverlay,
                    detail = "So the bubble can float over everything. Find Blurt and turn it on.",
                ) {
                    if (!canOverlay) {
                        Button(onClick = {
                            open(
                                Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName"),
                                ),
                            )
                        }) { Text("Open settings") }
                    }
                }

                Step(
                    number = 4,
                    title = "Type into other apps (recommended)",
                    done = canType,
                    detail = if (canType) "Your words go straight into the field you're in, and the bubble only shows while you're typing." else
                        "Without it, your words are copied and you paste them, and the bubble is always on screen. " +
                        "In Settings › Accessibility › Blurt typing, turn it on. If it's greyed out: " +
                        "App info › ⋮ › Allow restricted settings, then try again.",
                ) {
                    if (!canType) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = { showTypingDisclosure = true }) {
                                Text("Open settings")
                            }
                            OutlinedButton(onClick = {
                                open(
                                    Intent(
                                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                        Uri.parse("package:$packageName"),
                                    ),
                                )
                            }) { Text("App info") }
                        }
                    }
                }

                val ready = hasKey && hasMic && canOverlay
                Card(modifier = Modifier.fillMaxWidth()) {
                    Row(
                        modifier = Modifier.padding(16.dp).fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("Bubble", style = MaterialTheme.typography.titleMedium)
                            Text(
                                if (ready || bubbleOn) {
                                    "Long press the bubble to come back to settings."
                                } else {
                                    "Finish the steps above first."
                                },
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Switch(
                            checked = bubbleOn,
                            enabled = ready || bubbleOn,
                            onCheckedChange = { on ->
                                if (on) BubbleService.start(this@MainActivity) else BubbleService.stop(this@MainActivity)
                            },
                        )
                    }
                }

                StyleCard()
            }
        }
    }

    /**
     * Google Play's prominent disclosure for the Accessibility API: what Blurt
     * typing reads, why, and where it goes, with an explicit agree before the
     * settings open. Dismissing it is a decline. Keep it true to
     * [BlurtAccessibilityService]: change one, change both.
     */
    @Composable
    private fun TypingDisclosure(onAgree: () -> Unit, onDecline: () -> Unit) {
        AlertDialog(
            onDismissRequest = onDecline,
            title = { Text("Let Blurt type for you?") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        "Blurt typing uses Android's Accessibility service to put your dictation into the " +
                            "app you're using.",
                    )
                    Text(
                        "When you start and finish a dictation, Blurt reads the text field you're typing " +
                            "in. Up to 1,000 characters before the cursor are sent to AssemblyAI with your " +
                            "audio, so the transcript continues what you wrote. Password fields are never read.",
                    )
                    Text(
                        "Blurt also checks whether a keyboard is on screen, to show the bubble only while " +
                            "you type. It doesn't read anything else on screen, keep what it reads, or use it " +
                            "for anything else.",
                    )
                }
            },
            confirmButton = { TextButton(onClick = onAgree) { Text("Agree and continue") } },
            dismissButton = { TextButton(onClick = onDecline) { Text("Not now") } },
        )
    }

    /** How the cleanup rewrite should sound: one of the presets, or the user's own words. */
    @Composable
    private fun StyleCard() {
        var style by remember { mutableStateOf(StyleStore.selected(this)) }
        var custom by remember { mutableStateOf(StyleStore.custom(this)) }
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(vertical = 12.dp)) {
                Text(
                    "Style",
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
                Text(
                    "How your words come out. Applies from your next dictation.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                )
                Style.entries.forEach { option ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(selected = style == option, role = Role.RadioButton) {
                                style = option
                                StyleStore.select(this@MainActivity, option)
                            }
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        RadioButton(selected = style == option, onClick = null, modifier = Modifier.padding(12.dp))
                        Column(Modifier.padding(top = 10.dp, end = 8.dp)) {
                            Text(option.label, style = MaterialTheme.typography.bodyLarge)
                            val detail = when (option) {
                                Style.None -> "Just cleaned up, in your own words."
                                Style.Custom -> "Your own instructions."
                                else -> option.instructions.orEmpty()
                            }
                            Text(
                                detail,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                if (style == Style.Custom) {
                    OutlinedTextField(
                        value = custom,
                        onValueChange = {
                            custom = it.take(CleanupInstruction.STYLE_BUDGET)
                            StyleStore.setCustom(this@MainActivity, custom)
                        },
                        label = { Text("Describe your style") },
                        placeholder = { Text("e.g. Short sentences, British spelling, no exclamation marks.") },
                        supportingText = { Text("${custom.length} / ${CleanupInstruction.STYLE_BUDGET}") },
                        minLines = 3,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    )
                }
            }
        }
    }

    @Composable
    private fun Step(number: Int, title: String, done: Boolean, detail: String, actions: @Composable () -> Unit) {
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    (if (done) "✓  " else "$number.  ") + title,
                    style = MaterialTheme.typography.titleMedium,
                    color = if (done) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                )
                Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                actions()
            }
        }
    }

    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    private fun accessibilityEnabled(): Boolean {
        val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            ?: return false
        val ours = ComponentName(this, BlurtAccessibilityService::class.java)
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == ours }
    }

    private fun open(intent: Intent) {
        startActivity(intent)
    }

    private companion object {
        const val KEYS_URL = "https://www.assemblyai.com/dashboard/api-keys"
    }
}

@Composable
private fun BlurtTheme(content: @Composable () -> Unit) {
    // Blurt green: `app/accent-light` and `app/accent-dark` in App/BlurtiOS/DESIGN.md.
    val colors = if (isSystemInDarkTheme()) {
        darkColorScheme(primary = Color(0xFF67AD82))
    } else {
        lightColorScheme(primary = Color(0xFF01762F))
    }
    MaterialTheme(colorScheme = colors, content = content)
}
