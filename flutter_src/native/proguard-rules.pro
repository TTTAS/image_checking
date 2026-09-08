# Keep WorkManager's reflectively-loaded Room database (WorkDatabase_Impl) and
# its impl package, plus any Worker classes, so release R8 minify does not
# strip/rename them. Without these, WorkManager fails to create WorkDatabase and
# the default startup initializer crashes the whole app on launch.
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
-keep class androidx.work.impl.** { *; }
-keep class * extends androidx.work.Worker
-keep class * extends androidx.work.ListenableWorker
-keep class * extends androidx.room.RoomDatabase
-dontwarn androidx.work.**
