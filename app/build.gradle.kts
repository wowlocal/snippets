plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.khm.snippets.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.khm.snippets.android"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        val oauthCallbackHost = providers.gradleProperty("SNIPPETS_OAUTH_CALLBACK_HOST")
            .orElse("invalid.invalid")
            .get()
            .lowercase()
        require(oauthCallbackHost.length <= 253 &&
            Regex("^[a-z0-9.-]+$").matches(oauthCallbackHost)) {
            "SNIPPETS_OAUTH_CALLBACK_HOST must be an ASCII DNS host"
        }
        manifestPlaceholders["snippetsOAuthCallbackHost"] = oauthCallbackHost
        // Satisfies AppAuth's lower-priority library manifest; the activity is
        // replaced below with a verified HTTPS App Link, so this scheme is not exported.
        manifestPlaceholders["appAuthRedirectScheme"] = "snippets-oauth-disabled"
        val snippetsCloudURL = providers.gradleProperty("SNIPPETS_CLOUD_URL")
            .orElse("")
            .get()
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
        buildConfigField("String", "SNIPPETS_CLOUD_URL", "\"$snippetsCloudURL\"")
        buildConfigField(
            "String",
            "SNIPPETS_OAUTH_REDIRECT_URI",
            "\"https://$oauthCallbackHost/oauth2redirect/android\"",
        )
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    implementation(project(":swiftcore"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.core.splashscreen)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.appauth)
    implementation(libs.google.code.scanner)
    implementation(libs.zxing.core)
    testImplementation(libs.junit)
    testImplementation(libs.json)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}
