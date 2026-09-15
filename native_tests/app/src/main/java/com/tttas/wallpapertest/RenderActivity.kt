package com.tttas.wallpapertest

import android.app.Activity
import android.os.Bundle
import android.view.SurfaceView
import android.view.SurfaceHolder
import android.widget.LinearLayout
import java.util.concurrent.CountDownLatch

class RenderActivity : Activity() {
    val ready = CountDownLatch(2)
    lateinit var primary: SurfaceView
    lateinit var secondary: SurfaceView
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val layout = LinearLayout(this)
        primary = SurfaceView(this)
        secondary = SurfaceView(this)
        for (view in listOf(primary, secondary)) {
            view.holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {}
                override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) { ready.countDown() }
                override fun surfaceDestroyed(holder: SurfaceHolder) {}
            })
            layout.addView(view, LinearLayout.LayoutParams(320, 480))
        }
        setContentView(layout)
    }
}
