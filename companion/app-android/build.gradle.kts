import org.gradle.api.GradleException

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
val allowLabDebugReleaseSigning = providers.gradleProperty("stackchan.allowLabDebugReleaseSigning")
    .map(String::toBoolean)
    .orElse(false)
    .get()

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
            signingConfig = when {
                hasPlayReleaseSigning -> signingConfigs.getByName("playRelease")
                allowLabDebugReleaseSigning -> signingConfigs.getByName("debug")
                else -> null
            }
        }
    }

    sourceSets {
        getByName("main") {
            assets.srcDir("../../personas")
        }
    }
}

val verifyReleaseSigning = tasks.register("verifyReleaseSigning") {
    group = "verification"
    description = "Fails release builds unless Play upload signing is configured or lab signing is explicitly allowed."

    doLast {
        if (!hasPlayReleaseSigning && !allowLabDebugReleaseSigning) {
            throw GradleException(
                "Android release signing is not configured. Set STACKCHAN_ANDROID_KEYSTORE, " +
                    "STACKCHAN_ANDROID_KEYSTORE_PASSWORD, STACKCHAN_ANDROID_KEY_ALIAS, and " +
                    "STACKCHAN_ANDROID_KEY_PASSWORD. For a non-distributable lab build only, pass " +
                    "-Pstackchan.allowLabDebugReleaseSigning=true."
            )
        }
        logger.lifecycle(
            if (hasPlayReleaseSigning) {
                "Android release signing profile: Play upload key."
            } else {
                "Android release signing profile: LAB ONLY Android debug key."
            }
        )
    }
}

tasks.matching { it.name in setOf("assembleRelease", "bundleRelease") }.configureEach {
    dependsOn(verifyReleaseSigning)
}

dependencies {
    implementation(project(":core"))
    implementation(project(":ui"))
    implementation(libs.androidx.activity.compose)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.litertlm.android)
    testImplementation(libs.junit)
    testImplementation(libs.kotlin.test)
}
