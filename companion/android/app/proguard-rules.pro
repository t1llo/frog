# R8 rules for release builds.
# zxing-android-embedded and kotlinx.serialization's JSON element API (no @Serializable classes)
# need no extra keep rules; their consumer rules ship inside the libraries.

# Keep line numbers so release crash reports stay readable.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
