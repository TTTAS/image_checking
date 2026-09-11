package __PACKAGE__

import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLUtils
import android.opengl.Matrix
import android.os.Handler
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Sole producer of the wallpaper Surface. Never lockCanvas() that Surface:
 * Android's CPU producer cannot be disconnected to let a video decoder connect.
 * All methods run on the owning playback thread; each engine has its own context.
 */
class WallpaperRenderer(surface: Surface, private val width: Int, private val height: Int) {
    private val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    private var context = EGL14.EGL_NO_CONTEXT
    private var window = EGL14.EGL_NO_SURFACE
    private var bitmapProgram = 0
    private var videoProgram = 0
    private var bitmapTexture = 0
    private var videoTexture = 0
    private var input: SurfaceTexture? = null
    private var videoSurface: Surface? = null
    private val identity = FloatArray(16).also { Matrix.setIdentityM(it, 0) }
    private val textureMatrix = FloatArray(16)
    private val positions = buffer(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
    // Bitmap upload row zero is the top. SurfaceTexture supplies its own flip.
    private val bitmapCoords = buffer(floatArrayOf(0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f))
    private val videoCoords = buffer(floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f))

    init {
        try {
            check(EGL14.eglInitialize(display, IntArray(2), 0, IntArray(2), 0))
            val configs = arrayOfNulls<EGLConfig>(1)
            val count = IntArray(1)
            check(EGL14.eglChooseConfig(display, intArrayOf(
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT, EGL14.EGL_NONE
            ), 0, configs, 0, 1, count, 0) && count[0] > 0)
            context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
            check(context != EGL14.EGL_NO_CONTEXT)
            window = EGL14.eglCreateWindowSurface(display, configs[0], surface,
                intArrayOf(EGL14.EGL_NONE), 0)
            check(window != EGL14.EGL_NO_SURFACE)
            current()
            bitmapProgram = program(false)
            videoProgram = program(true)
            bitmapTexture = texture(GLES20.GL_TEXTURE_2D)
        } catch (e: Exception) {
            release()
            throw e
        }
    }

    private fun current() {
        check(EGL14.eglMakeCurrent(display, window, window, context)) {
            "Cannot bind wallpaper EGL context: ${EGL14.eglGetError()}"
        }
    }

    fun createVideoSurface(handler: Handler, onFrame: () -> Unit): Surface {
        current()
        releaseVideo()
        videoTexture = texture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES)
        val st = SurfaceTexture(videoTexture)
        input = st
        st.setOnFrameAvailableListener({ if (input === it) onFrame() }, handler)
        return Surface(st).also { videoSurface = it }
    }

    fun releaseVideo() {
        input?.setOnFrameAvailableListener(null)
        videoSurface?.release()
        videoSurface = null
        input?.release()
        input = null
        if (videoTexture != 0 && context != EGL14.EGL_NO_CONTEXT) {
            current()
            GLES20.glDeleteTextures(1, intArrayOf(videoTexture), 0)
        }
        videoTexture = 0
    }

    fun drawVideo(w: Int, h: Int, zoom: Float, fx: Float, fy: Float) {
        current()
        val st = input ?: return
        st.updateTexImage()
        st.getTransformMatrix(textureMatrix)
        draw(videoProgram, GLES11Ext.GL_TEXTURE_EXTERNAL_OES, videoTexture,
            videoCoords, textureMatrix, w, h, zoom, fx, fy)
    }

    fun drawBitmap(bitmap: Bitmap, zoom: Float = 0f, fx: Float = .5f, fy: Float = .5f) {
        current()
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, bitmapTexture)
        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
        draw(bitmapProgram, GLES20.GL_TEXTURE_2D, bitmapTexture,
            bitmapCoords, identity, bitmap.width, bitmap.height, zoom, fx, fy)
    }

    private fun draw(program: Int, target: Int, texture: Int,
        coords: java.nio.FloatBuffer, texMatrix: FloatArray,
        w: Int, h: Int, zoom: Float, fx: Float, fy: Float) {
        val iw = w.coerceAtLeast(1).toFloat()
        val ih = h.coerceAtLeast(1).toFloat()
        val fit = minOf(width / iw, height / ih)
        val cover = maxOf(width / iw, height / ih)
        val scale = if (zoom <= 0f) fit else cover * zoom
        val sw = iw * scale
        val sh = ih * scale
        val matrix = FloatArray(16).also { Matrix.setIdentityM(it, 0) }
        matrix[0] = sw / width
        matrix[5] = sh / height
        matrix[12] = (1f - 2f * fx) * sw / width
        matrix[13] = (2f * fy - 1f) * sh / height
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(target, texture)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "image"), 0)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "crop"), 1, false, matrix, 0)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "texMatrix"), 1, false, texMatrix, 0)
        val a = GLES20.glGetAttribLocation(program, "position")
        val b = GLES20.glGetAttribLocation(program, "uv")
        GLES20.glEnableVertexAttribArray(a)
        GLES20.glEnableVertexAttribArray(b)
        positions.position(0)
        coords.position(0)
        GLES20.glVertexAttribPointer(a, 2, GLES20.GL_FLOAT, false, 0, positions)
        GLES20.glVertexAttribPointer(b, 2, GLES20.GL_FLOAT, false, 0, coords)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(a)
        GLES20.glDisableVertexAttribArray(b)
        check(GLES20.glGetError() == GLES20.GL_NO_ERROR) { "Wallpaper drawing failed" }
        check(EGL14.eglSwapBuffers(display, window)) { "Wallpaper Surface lost" }
    }

    fun release() {
        if (context != EGL14.EGL_NO_CONTEXT && window != EGL14.EGL_NO_SURFACE) {
            releaseVideo()
            current()
            GLES20.glDeleteTextures(1, intArrayOf(bitmapTexture), 0)
            GLES20.glDeleteProgram(bitmapProgram)
            GLES20.glDeleteProgram(videoProgram)
        }
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        if (window != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, window)
        if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
        window = EGL14.EGL_NO_SURFACE
        context = EGL14.EGL_NO_CONTEXT
        EGL14.eglTerminate(display)
    }

    private fun texture(target: Int): Int {
        val names = IntArray(1)
        GLES20.glGenTextures(1, names, 0)
        GLES20.glBindTexture(target, names[0])
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        return names[0]
    }

    private fun program(external: Boolean): Int {
        val vertex = shader(GLES20.GL_VERTEX_SHADER, """
            attribute vec4 position;
            attribute vec2 uv;
            uniform mat4 crop;
            uniform mat4 texMatrix;
            varying vec2 coords;
            void main() {
                gl_Position = crop * position;
                coords = (texMatrix * vec4(uv, 0.0, 1.0)).xy;
            }
        """.trimIndent())
        val fragment = shader(GLES20.GL_FRAGMENT_SHADER,
            (if (external) "#extension GL_OES_EGL_image_external : require\n" else "") +
            "precision mediump float; varying vec2 coords; uniform " +
            (if (external) "samplerExternalOES" else "sampler2D") +
            " image; void main() { gl_FragColor = vec4(texture2D(image, coords).rgb, 1.0); }")
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, vertex)
        GLES20.glAttachShader(p, fragment)
        GLES20.glLinkProgram(p)
        val ok = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
        GLES20.glDeleteShader(vertex)
        GLES20.glDeleteShader(fragment)
        check(ok[0] != 0) { GLES20.glGetProgramInfoLog(p) }
        return p
    }

    private fun shader(type: Int, source: String): Int {
        val s = GLES20.glCreateShader(type)
        GLES20.glShaderSource(s, source)
        GLES20.glCompileShader(s)
        val ok = IntArray(1)
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
        check(ok[0] != 0) { GLES20.glGetShaderInfoLog(s) }
        return s
    }

    private fun buffer(values: FloatArray) =
        ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder())
            .asFloatBuffer().apply { put(values); position(0) }
}
