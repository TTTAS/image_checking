package __PACKAGE__
import android.service.wallpaper.WallpaperService
import android.view.SurfaceHolder

open class PlaylistWallpaperService : WallpaperService() {
    protected open val playlistSide: String = "home"
    override fun onCreateEngine(): Engine = PlaylistEngine()
    inner class PlaylistEngine : Engine() {
        private val playback = WallpaperPlayback(this@PlaylistWallpaperService, playlistSide)
        override fun onSurfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            playback.attach(holder.surface, width, height)
        }
        override fun onVisibilityChanged(visible: Boolean) { playback.setVisible(visible) }
        override fun onSurfaceDestroyed(holder: SurfaceHolder) {
            playback.detach()
            super.onSurfaceDestroyed(holder)
        }
        override fun onDestroy() {
            playback.detach()
            super.onDestroy()
        }
    }
}

/** A separate component gives the system picker an unambiguous lock playlist preview. */
class LockPlaylistWallpaperService : PlaylistWallpaperService() {
    override val playlistSide: String = "lock"
}
