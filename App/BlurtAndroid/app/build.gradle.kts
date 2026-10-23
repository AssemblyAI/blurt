import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.assemblyai.blurt.android"
    compileSdk = 36

    // Release signing with the upload key (Play App Signing re-signs for
    // users). Its path is in the gitignored local.properties; its password
    // comes from BLURT_UPLOAD_PASSWORD or, on a Mac, the Keychain item
    // `blurt-android-upload`, so it's never in a file. Without the path, a
    // release build is simply unsigned.
    val local = Properties().apply {
        rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
    }
    val uploadStore = local.getProperty("blurt.upload.storeFile")?.let(::file)?.takeIf { it.exists() }
    val uploadPassword: Provider<String> = providers.environmentVariable("BLURT_UPLOAD_PASSWORD").orElse(
        providers.exec {
            commandLine("security", "find-generic-password", "-s", "blurt-android-upload", "-w")
            isIgnoreExitValue = true
        }.standardOutput.asText.map { it.trim() },
    )
    signingConfigs {
        if (uploadStore != null) {
            create("upload") {
                storeFile = uploadStore
                storePassword = uploadPassword.get()
                keyAlias = "upload"
                keyPassword = uploadPassword.get()
            }
        }
    }

    defaultConfig {
        applicationId = "com.assemblyai.blurt.android"
        minSdk = 30
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"

        // Sign in with AssemblyAI, from the gitignored local.properties (see the
        // README). Any value left out turns sign-in off and the app offers only
        // the paste-a-key path, the way the Mac's SignIn.xcconfig does.
        fun signIn(name: String) = "\"${local.getProperty("blurt.oauth.$name", "")}\""
        buildConfigField("String", "OAUTH_CLIENT_ID", signIn("clientId"))
        buildConfigField("String", "OAUTH_AUTHORIZE_URL", signIn("authorizeUrl"))
        buildConfigField("String", "OAUTH_TOKEN_URL", signIn("tokenUrl"))
        buildConfigField("String", "OAUTH_API_ORIGIN", signIn("apiOrigin"))
        buildConfigField("String", "OAUTH_DICTATION_ORIGIN", signIn("dictationOrigin"))
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("upload")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.browser:browser:1.8.0")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
