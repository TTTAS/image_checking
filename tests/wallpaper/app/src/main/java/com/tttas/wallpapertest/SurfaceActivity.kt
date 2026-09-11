package com.tttas.wallpapertest

import android.app.Activity
import android.os.Bundle
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.FrameLayout

class SurfaceActivity : Activity(), SurfaceHolder.Callback {
    lateinit var view: SurfaceView
    lateinit var playback: WallpaperPlayback
    var preview: WallpaperPlayback? = null
    private lateinit var layout: FrameLayout
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        playback = WallpaperPlayback(this)
        view = SurfaceView(this)
        view.holder.addCallback(this)
        layout = FrameLayout(this)
        layout.addView(view, FrameLayout.LayoutParams(-1, -1))
        setContentView(layout)
    }
    override fun surfaceCreated(holder: SurfaceHolder) {}
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        playback.attach(holder.surface, width, height)
        playback.setVisible(true)
    }
    override fun surfaceDestroyed(holder: SurfaceHolder) { playback.detach() }
    fun addPreview() {
        val second = SurfaceView(this)
        val engine = WallpaperPlayback(this)
        preview = engine
        second.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(h: SurfaceHolder) {}
            override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, height: Int) {
                engine.attach(h.surface, w, height)
                engine.setVisible(true)
            }
            override fun surfaceDestroyed(h: SurfaceHolder) { engine.detach() }
        })
        // Overlay a second Surface without resizing/recreating the first one.
        layout.addView(second, FrameLayout.LayoutParams(160, 160))
    }
    fun closePreview() {
        preview?.detach()
        preview = null
        layout.removeViewAt(1)
    }
    override fun onDestroy() { preview?.detach(); playback.detach(); super.onDestroy() }
}
