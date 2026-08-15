-keep class com.khm.snippets.core.** { *; }
-keep class org.swift.swiftkit.** { *; }

# swift-java's thread-safety annotations mirror optional JDK Flight Recorder
# metadata that Android does not ship or execute.
-dontwarn jdk.jfr.Description
-dontwarn jdk.jfr.Label
