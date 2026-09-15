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
import java.nio.FloatBuffer

/** The only producer of the wallpaper Surface is EGL, for ALL playlist items.
 * Images are uploaded as textures; MediaPlayer writes to a separate SurfaceTexture.
 * Never lock a Canvas on the wallpaper Surface: that permanently connects a CPU
 * producer and prevents MediaPlayer/EGL from connecting until Surface destruction.
 * All methods and frame callbacks run on the Engine's main thread. Each operation
 * makes its context current since preview/home/lock Engines can coexist.
 */
class WallpaperRenderer(surface: Surface) {
    companion object {
        // EGL_DEFAULT_DISPLAY is shared by all Engines in this process. Calling
        // eglTerminate from one Engine would invalidate the other Engines.
        private var users = 0
        @Synchronized private fun acquire() { users++ }
        @Synchronized private fun relinquish(): Boolean { users--; return users == 0 }
    }
    private var counted = false
    private var released = false
    private val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    private var context = EGL14.EGL_NO_CONTEXT
    private var window = EGL14.EGL_NO_SURFACE
    private var imageProgram = 0
    private var videoProgram = 0
    private var imageTexture = 0
    private var videoTexture = 0
    private var videoFrames: SurfaceTexture? = null
    private var videoSurface: Surface? = null
    private var uploadedW = 0
    private var uploadedH = 0
    private val identity = FloatArray(16).also { Matrix.setIdentityM(it, 0) }
    private val textureMatrix = FloatArray(16)
    private val vertices = buffer(FloatArray(8))
    private val imageUV = buffer(floatArrayOf(0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f))
    private val videoUV = buffer(floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f))

    init {
        try {
            check(EGL14.eglInitialize(display, IntArray(2), 0, IntArray(2), 0)) { "EGL initialize" }
            acquire()
            counted = true
            val configs = arrayOfNulls<EGLConfig>(1)
            val count = IntArray(1)
            check(EGL14.eglChooseConfig(display, intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_NONE,
            ), 0, configs, 0, 1, count, 0) && count[0] > 0) { "EGL config" }
            context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
            check(context != EGL14.EGL_NO_CONTEXT) { "EGL context" }
            window = EGL14.eglCreateWindowSurface(display, configs[0], surface,
                intArrayOf(EGL14.EGL_NONE), 0)
            check(window != EGL14.EGL_NO_SURFACE) { "EGL window: ${EGL14.eglGetError()}" }
            current()
            imageProgram = program(false)
            videoProgram = program(true)
            imageTexture = texture(GLES20.GL_TEXTURE_2D)
        } catch (e: Exception) {
            release()
            throw e
        }
    }

    private fun current() {
        check(EGL14.eglMakeCurrent(display, window, window, context)) {
            "EGL makeCurrent: ${EGL14.eglGetError()}"
        }
    }

    fun clear(width: Int, height: Int) {
        current()
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        swap()
    }

    fun drawBitmap(bitmap: Bitmap, width: Int, height: Int) {
        current()
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, imageTexture)
        if (uploadedW == bitmap.width && uploadedH == bitmap.height) {
            GLUtils.texSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, bitmap)
        } else {
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
            uploadedW = bitmap.width
            uploadedH = bitmap.height
        }
        draw(imageProgram, GLES20.GL_TEXTURE_2D, imageTexture, imageUV, identity,
            width, height, 0f, 0f, width.toFloat(), height.toFloat())
    }

    fun createVideoSurface(handler: Handler, onFrame: () -> Unit): Surface {
        releaseVideo()
        current()
        videoTexture = texture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES)
        val frames = SurfaceTexture(videoTexture)
        videoFrames = frames
        frames.setOnFrameAvailableListener({
            if (videoFrames === it) onFrame()
        }, handler)
        return Surface(frames).also { videoSurface = it }
    }

    fun drawVideo(width: Int, height: Int, left: Float, top: Float,
                  contentW: Float, contentH: Float) {
        current()
        val frames = videoFrames ?: return
        frames.updateTexImage()
        frames.getTransformMatrix(textureMatrix)
        draw(videoProgram, GLES11Ext.GL_TEXTURE_EXTERNAL_OES, videoTexture,
            videoUV, textureMatrix, width, height, left, top, contentW, contentH)
    }

    private fun draw(program: Int, target: Int, texture: Int, uv: FloatBuffer,
                     matrix: FloatArray, width: Int, height: Int,
                     left: Float, top: Float, contentW: Float, contentH: Float) {
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        val x0 = 2f * left / width - 1f
        val x1 = 2f * (left + contentW) / width - 1f
        val y0 = 1f - 2f * (top + contentH) / height
        val y1 = 1f - 2f * top / height
        vertices.clear()
        vertices.put(floatArrayOf(x0, y0, x1, y0, x0, y1, x1, y1)).position(0)
        GLES20.glUseProgram(program)
        val position = GLES20.glGetAttribLocation(program, "aPosition")
        val texCoord = GLES20.glGetAttribLocation(program, "aTexCoord")
        GLES20.glEnableVertexAttribArray(position)
        GLES20.glEnableVertexAttribArray(texCoord)
        GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 0, vertices)
        uv.position(0)
        GLES20.glVertexAttribPointer(texCoord, 2, GLES20.GL_FLOAT, false, 0, uv)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uTransform"), 1, false, matrix, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(target, texture)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uTexture"), 0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(position)
        GLES20.glDisableVertexAttribArray(texCoord)
        val error = GLES20.glGetError()
        check(error == GLES20.GL_NO_ERROR) { "GL draw: $error" }
        swap()
    }

    private fun swap() {
        check(EGL14.eglSwapBuffers(display, window)) { "EGL swap: ${EGL14.eglGetError()}" }
    }

    fun releaseVideo() {
        videoFrames?.setOnFrameAvailableListener(null)
        videoSurface?.release()
        videoSurface = null
        videoFrames?.release()
        videoFrames = null
        if (videoTexture != 0) {
            current()
            GLES20.glDeleteTextures(1, intArrayOf(videoTexture), 0)
            videoTexture = 0
        }
    }

    fun release() {
        if (released) return
        released = true
        if (context != EGL14.EGL_NO_CONTEXT && window != EGL14.EGL_NO_SURFACE) {
            try {
                current()
                releaseVideo()
                GLES20.glDeleteTextures(1, intArrayOf(imageTexture), 0)
                GLES20.glDeleteProgram(imageProgram)
                GLES20.glDeleteProgram(videoProgram)
            } catch (_: Exception) { }
        }
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        if (window != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, window)
        if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
        if (counted && relinquish()) EGL14.eglTerminate(display)
        counted = false
        window = EGL14.EGL_NO_SURFACE
        context = EGL14.EGL_NO_CONTEXT
    }

    private fun texture(target: Int): Int {
        val id = IntArray(1)
        GLES20.glGenTextures(1, id, 0)
        GLES20.glBindTexture(target, id[0])
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        return id[0]
    }

    private fun program(external: Boolean): Int {
        val vertex = shader(GLES20.GL_VERTEX_SHADER, """
            attribute vec4 aPosition;
            attribute vec2 aTexCoord;
            uniform mat4 uTransform;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = (uTransform * vec4(aTexCoord, 0.0, 1.0)).xy;
            }
        """.trimIndent())
        val fragment = shader(GLES20.GL_FRAGMENT_SHADER,
            (if (external) "#extension GL_OES_EGL_image_external : require\n" else "") +
                "precision mediump float;\n" +
                "uniform ${if (external) "samplerExternalOES" else "sampler2D"} uTexture;\n" +
                "varying vec2 vTexCoord;\n" +
                "void main() { gl_FragColor = texture2D(uTexture, vTexCoord); }\n")
        val result = GLES20.glCreateProgram()
        GLES20.glAttachShader(result, vertex)
        GLES20.glAttachShader(result, fragment)
        GLES20.glLinkProgram(result)
        GLES20.glDeleteShader(vertex)
        GLES20.glDeleteShader(fragment)
        val status = IntArray(1)
        GLES20.glGetProgramiv(result, GLES20.GL_LINK_STATUS, status, 0)
        check(status[0] != 0) { "GL link: ${GLES20.glGetProgramInfoLog(result)}" }
        return result
    }

    private fun shader(type: Int, source: String): Int {
        val result = GLES20.glCreateShader(type)
        GLES20.glShaderSource(result, source)
        GLES20.glCompileShader(result)
        val status = IntArray(1)
        GLES20.glGetShaderiv(result, GLES20.GL_COMPILE_STATUS, status, 0)
        check(status[0] != 0) { "GL shader: ${GLES20.glGetShaderInfoLog(result)}" }
        return result
    }

    private fun buffer(values: FloatArray): FloatBuffer =
        ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder())
            .asFloatBuffer().apply { put(values); position(0) }
}
