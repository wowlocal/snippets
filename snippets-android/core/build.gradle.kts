import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.animalsniffer)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
        // Compile against the JDK 17 API whichever JDK runs Gradle.
        freeCompilerArgs.add("-Xjdk-release=17")
    }
}

// :core also runs on Android, so main code may only use JDK APIs that exist on API 28.
// `./gradlew :core:animalsnifferMain` (part of `check`) fails on anything else.
animalsniffer {
    sourceSets = listOf(project.sourceSets.main.get())
}

dependencies {
    signature(variantOf(libs.android.api28.signature) { artifactType("signature") })

    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)

    testImplementation(libs.junit)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
