plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.compose.compiler)
}

val releaseStoreFilePath = providers.gradleProperty("STACKCHAN_ANDROID_KEYSTORE")
    .orElse(providers.environmentVariable("STACKCHAN_ANDROID_KEYSTORE"))
    .orNull
val releaseStorePassword = providers.gradleProperty("STACKCHAN_ANDROID_KEYSTORE_PASSWORD")
    .orElse(providers.environmentVariable("STACKCHAN_ANDROID_KEYSTORE_PASSWORD"))
    .orNull
val releaseKeyAlias = providers.gradleProperty("STACKCHAN_ANDROID_KEY_ALIAS")
    .orElse(providers.environmentVariable("STACKCHAN_ANDROID_KEY_ALIAS"))
    .orNull
val releaseKeyPassword = providers.gradleProperty("STACKCHAN_ANDROID_KEY_PASSWORD")
    .orElse(providers.environmentVariable("STACKCHAN_ANDROID_KEY_PASSWORD"))
    .orNull
val hasPlayReleaseSigning = listOf(
    releaseStoreFilePath,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }

android {
    namespace = "dev.stackchan.companion.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.stackchan.companion"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
    }

    signingConfigs {
        if (hasPlayReleaseSigning) {
            create("playRelease") {
                storeFile = file(releaseStoreFilePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isDebuggable = false
            signingConfig = signingConfigs.getByName(if (hasPlayReleaseSigning) "playRelease" else "debug")
        }
    }
}

dependencies {
    implementation(project(":core"))
    implementation(project(":ui"))
    implementation(libs.androidx.activity.compose)
    implementation(libs.kotlinx.serialization.json)
    testImplementation(libs.junit)
    testImplementation(libs.kotlin.test)
}
