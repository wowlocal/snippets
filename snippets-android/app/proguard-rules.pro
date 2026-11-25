# kotlinx.serialization, OkHttp, coroutines and the AndroidX libraries ship their own
# R8 rules. The rules below only cover what the bundled kotlinx.serialization rules
# leave out: serializers reached through a *named* companion object.
-if @kotlinx.serialization.Serializable class **
-keepclassmembers class <1> {
    static <1>$* Companion;
}
-keepnames @kotlinx.serialization.internal.NamedCompanion class *
-if @kotlinx.serialization.internal.NamedCompanion class *
-keepclassmembernames class * {
    static <1> *;
}
