"""Register both playlist components in generated Android manifests."""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

ANDROID = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", ANDROID)
ET.register_namespace("tools", "http://schemas.android.com/tools")

def inject(path):
    tree = ET.parse(path)
    app = tree.getroot().find("application")
    if app is None:
        raise ValueError("No application in Android manifest")
    for name, label in [
        (".PlaylistWallpaperService", "@string/playlist_wallpaper_label"),
        (".LockPlaylistWallpaperService", "@string/lock_playlist_wallpaper_label"),
    ]:
        if any(s.get(f"{{{ANDROID}}}name") == name for s in app.findall("service")):
            continue
        service = ET.SubElement(app, "service", {
            f"{{{ANDROID}}}name": name, f"{{{ANDROID}}}exported": "true",
            f"{{{ANDROID}}}label": label,
            f"{{{ANDROID}}}permission": "android.permission.BIND_WALLPAPER",
        })
        intent = ET.SubElement(service, "intent-filter")
        ET.SubElement(intent, "action", {f"{{{ANDROID}}}name": "android.service.wallpaper.WallpaperService"})
        ET.SubElement(service, "meta-data", {
            f"{{{ANDROID}}}name": "android.service.wallpaper",
            f"{{{ANDROID}}}resource": "@xml/playlist_wallpaper",
        })
    tree.write(path, encoding="utf-8", xml_declaration=True)

if __name__ == "__main__":
    inject(Path(sys.argv[1]))
