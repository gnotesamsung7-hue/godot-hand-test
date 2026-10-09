import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

val pluginName = "HandTracker"
val pluginPackageName = "com.markdave.handtracker"

android {
    namespace = pluginPackageName
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        manifestPlaceholders["godotPluginName"] = pluginName
        manifestPlaceholders["godotPluginPackageName"] = pluginPackageName
        setProperty("archivesBaseName", pluginName)
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }
}

dependencies {
    // Provided by the Godot app at runtime.
    compileOnly("org.godotengine:godot:4.5.1.stable")
    // These must also be listed in game/addons/HandTracker/export_plugin.gd so they end up in the APK.
    implementation("com.google.mediapipe:tasks-vision:0.10.14")
    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    implementation("androidx.core:core:1.13.1")
    implementation("androidx.lifecycle:lifecycle-common:2.6.2")
}
