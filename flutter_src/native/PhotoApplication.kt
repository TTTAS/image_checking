package __PACKAGE__

import android.app.Application
import androidx.work.Configuration

/// Custom Application enabling WorkManager's **on-demand initialization**.
///
/// By default WorkManager initializes itself at process start via an
/// androidx.startup ContentProvider. On some devices / dependency combinations
/// that startup init can crash the whole app before any of our code runs.
///
/// Providing this [Configuration.Provider] (together with removing the default
/// initializer in the manifest) moves WorkManager off the launch critical path:
/// it initializes lazily the first time it's actually used — in the UI process
/// when the user taps "apply", and in the worker's own process when the periodic
/// job fires. A WorkManager problem can then no longer crash app startup.
class PhotoApplication : Application(), Configuration.Provider {
    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder().build()
}
