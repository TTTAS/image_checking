package com.tttas.wallpapertest

import android.app.Activity
import android.os.Bundle
import android.view.SurfaceHolder
import android.view.SurfaceView

class SurfaceActivity : Activity(), SurfaceHolder.Callback {
    lateinit var view: SurfaceView
    lateinit var playback: WallpaperPlayback
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        playback = WallpaperPlayback(this)
        view = SurfaceView(this)
        view.holder.addCallback(this)
        setContentView(view)
    }
    override fun surfaceCreated(holder: SurfaceHolder) {}
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        playback.attach(holder.surface, width, height)
        playback.setVisible(true)
    }
    override fun surfaceDestroyed(holder: SurfaceHolder) { playback.detach() }
    override fun onDestroy() { playback.detach(); super.onDestroy() }
}
