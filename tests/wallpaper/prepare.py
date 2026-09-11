"""Copy the production playback code; fixtures are generated, no personal media."""
from pathlib import Path
import subprocess
import json

repo = Path(__file__).resolve().parents[2]
app = Path(__file__).resolve().parent / "app"
dest = app / "src/main/java/com/tttas/wallpapertest"
for name in ("WallpaperRenderer.kt", "WallpaperPlayback.kt", "WallpaperWorker.kt"):
    source = (repo / "flutter_src/native" / name).read_text(encoding="utf-8")
    (dest / name).write_text(source.replace("__PACKAGE__", "com.tttas.wallpapertest"), encoding="utf-8")
assets = app / "src/main/assets"
assets.mkdir(parents=True, exist_ok=True)
# Distinct quadrants expose vertical inversion, aspect-ratio and crop mistakes.
filtergraph = ("color=red:s=320x240:r=15:d=2,"
               "drawbox=x=160:y=0:w=160:h=120:color=lime:t=fill,"
               "drawbox=x=0:y=120:w=160:h=120:color=blue:t=fill,"
               "drawbox=x=160:y=120:w=160:h=120:color=yellow:t=fill")
def ff(*args):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *args], check=True)
ff("-f", "lavfi", "-i", filtergraph, "-c:v", "libx264", "-pix_fmt", "yuv420p", str(assets / "quadrants.mp4"))
ff("-display_rotation", "90", "-i", str(assets / "quadrants.mp4"), "-c", "copy", str(assets / "rotated.mp4"))
probe = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-show_streams", "-of", "json", str(assets / "rotated.mp4")
]))
assert any(abs(side.get("rotation", 0)) == 90
           for stream in probe["streams"] for side in stream.get("side_data_list", [])), "Rotation fixture has no display matrix"
ff("-f", "lavfi", "-i", "color=magenta:s=160x120:r=10:d=2",
   "-vf", "drawbox=x=0:y=0:w=iw:h=ih:color=yellow:t=fill:enable='gte(t,1)'",
   str(assets / "motion.gif"))
ff("-f", "lavfi", "-i", "color=cyan:s=160x120:r=5:d=1", "-c:v", "libvpx-vp9", str(assets / "sample.webm"))
