pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenLocal()
        google()
        mavenCentral()
    }
}

rootProject.name = "Snippets Android"
include(":app")
include(":baselineprofile")
include(":swiftcore")
project(":swiftcore").projectDir = file("AndroidCorePackage")
