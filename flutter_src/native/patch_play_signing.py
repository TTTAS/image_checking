#!/usr/bin/env python3
from pathlib import Path
import re

PLAY_APPLICATION_ID = "com.tttas.photoalbum"

kts = Path("android/app/build.gradle.kts")
groovy = Path("android/app/build.gradle")

def force_application_id_kts(text: str) -> str:
    if re.search(r'applicationId\s*=', text):
        return re.sub(
            r'applicationId\s*=\s*"[^"]+"',
            f'applicationId = "{PLAY_APPLICATION_ID}"',
            text,
            count=1,
        )
    return text.replace(
        "android {",
        f'android {{\n    defaultConfig {{\n        applicationId = "{PLAY_APPLICATION_ID}"\n    }}\n',
        1,
    )

def force_application_id_groovy(text: str) -> str:
    if re.search(r'applicationId\s+', text):
        return re.sub(
            r'applicationId\s+"[^"]+"',
            f'applicationId "{PLAY_APPLICATION_ID}"',
            text,
            count=1,
        )
    return text

if kts.exists():
    text = kts.read_text()
    text = force_application_id_kts(text)
    if "PLAY_UPLOAD_SIGNING" not in text:
        if "import java.util.Properties" not in text:
            text = (
                "import java.util.Properties\n"
                "import java.io.FileInputStream\n\n"
                + text
            )
        loader = """
// PLAY_UPLOAD_SIGNING
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

"""
        if "android {" not in text:
            raise SystemExit("android { not found in build.gradle.kts")
        text = text.replace("android {", loader + "android {", 1)
        signing = """
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }
"""
        text = text.replace("android {", "android {" + signing, 1)
        text = text.replace(
            'signingConfig = signingConfigs.getByName("debug")',
            'signingConfig = signingConfigs.getByName("release")',
        )
        if "proguardFiles(" not in text:
            text = text.replace(
                'signingConfig = signingConfigs.getByName("release")',
                'signingConfig = signingConfigs.getByName("release")\n'
                '            proguardFiles(\n'
                '                getDefaultProguardFile("proguard-android-optimize.txt"),\n'
                '                "proguard-rules.pro",\n'
                '            )',
                1,
            )
    kts.write_text(text)
    print("patched", kts)
    print(text)
elif groovy.exists():
    text = force_application_id_groovy(groovy.read_text())
    groovy.write_text(text)
    print("patched", groovy)
else:
    raise SystemExit("no app gradle file found")
