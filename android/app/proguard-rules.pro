#Flutter Wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-keep class de.prosiebensat1digital.** { *; }

-dontwarn com.google.android.play.core.**

# SnakeYAML 的 Java Beans 反射分支仅适用于 JVM；Android 不提供 java.beans。
# 配置解析不调用该分支，允许 R8 在压缩 Release 时安全忽略相关可选类型。
-dontwarn java.beans.**
