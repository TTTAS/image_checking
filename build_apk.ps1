<#
  build_apk.ps1  —  一鍵：安裝工具鏈 → 產生 Android 專案 → 編譯 APK → 打包 zip
  用法（在本檔所在資料夾開 PowerShell）：
      powershell -ExecutionPolicy Bypass -File .\build_apk.ps1

  這支腳本會安裝（若尚未安裝）：Git、Microsoft OpenJDK 17、Flutter(stable)、Android SDK。
  下載量約 4~6 GB，第一次跑會比較久。可重複執行，已裝好的步驟會自動略過。
#>

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
$SrcDir      = Join-Path $ProjectRoot 'flutter_src'
$FlutterDir  = 'C:\src\flutter'
$AndroidSdk  = Join-Path $env:LOCALAPPDATA 'Android\Sdk'

function Info($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Update-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User')  + ';' +
              "$FlutterDir\bin;$AndroidSdk\cmdline-tools\latest\bin;$AndroidSdk\platform-tools"
}
Update-Path

# ---------------------------------------------------------------------------
Info '0. 前置檢查'
if (-not (Test-Path $SrcDir)) { throw "找不到原始碼資料夾：$SrcDir" }
$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
if (-not $hasWinget) {
  Write-Warning "找不到 winget。若 Git / JDK 未安裝，請先從 Microsoft Store 安裝『應用程式安裝程式(App Installer)』，或手動安裝 Git 與 JDK17 後再跑一次。"
}

# ---------------------------------------------------------------------------
Info '1. Git'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  if ($hasWinget) { winget install --id Git.Git -e --source winget --accept-source-agreements --accept-package-agreements }
  Update-Path
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw '需要 Git，請手動安裝後重跑。' }
git --version

# ---------------------------------------------------------------------------
Info '2. JDK 17 (Microsoft OpenJDK)'
$jdk = Get-ChildItem 'C:\Program Files\Microsoft\jdk-17*' -Directory -ErrorAction SilentlyContinue |
       Sort-Object Name | Select-Object -Last 1
if (-not $jdk) {
  if ($hasWinget) { winget install --id Microsoft.OpenJDK.17 -e --accept-source-agreements --accept-package-agreements }
  $jdk = Get-ChildItem 'C:\Program Files\Microsoft\jdk-17*' -Directory -ErrorAction SilentlyContinue |
         Sort-Object Name | Select-Object -Last 1
}
if (-not $jdk) { throw 'JDK17 安裝失敗，請手動安裝 Microsoft OpenJDK 17 後重跑。' }
$env:JAVA_HOME = $jdk.FullName
$env:Path = "$($jdk.FullName)\bin;$env:Path"
Write-Host "JAVA_HOME = $env:JAVA_HOME"
java -version

# ---------------------------------------------------------------------------
Info '3. Flutter (stable)'
if (-not (Test-Path "$FlutterDir\bin\flutter.bat")) {
  New-Item -ItemType Directory -Force -Path (Split-Path $FlutterDir) | Out-Null
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git $FlutterDir
}
Update-Path
$env:Path = "$($jdk.FullName)\bin;$env:Path"
flutter --version
flutter config --no-analytics | Out-Null
flutter config --jdk-dir "$($jdk.FullName)" | Out-Null

# ---------------------------------------------------------------------------
Info '4. Android SDK (cmdline-tools + platform + build-tools)'
$cmdlineBin = "$AndroidSdk\cmdline-tools\latest\bin"
if (-not (Test-Path "$cmdlineBin\sdkmanager.bat")) {
  $zip = Join-Path $env:TEMP 'android-cmdline-tools.zip'
  $url = 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip'
  Write-Host "下載 Android command-line tools ..."
  Invoke-WebRequest -Uri $url -OutFile $zip
  $tmp = Join-Path $env:TEMP 'cmdline-tools-extract'
  if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
  Expand-Archive $zip -DestinationPath $tmp -Force
  New-Item -ItemType Directory -Force -Path "$AndroidSdk\cmdline-tools\latest" | Out-Null
  Copy-Item "$tmp\cmdline-tools\*" "$AndroidSdk\cmdline-tools\latest\" -Recurse -Force
}
Update-Path
$env:Path = "$($jdk.FullName)\bin;$env:Path"
$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_SDK_ROOT = $AndroidSdk

Write-Host "安裝 SDK 套件（platform-tools / android-34 / build-tools 34）..."
$yes = ("y`n" * 50)
$yes | & "$cmdlineBin\sdkmanager.bat" --sdk_root="$AndroidSdk" "platform-tools" "platforms;android-34" "build-tools;34.0.0"

Info '5. 接受 Android 授權條款'
flutter config --android-sdk "$AndroidSdk" | Out-Null
$yes | & "$cmdlineBin\sdkmanager.bat" --sdk_root="$AndroidSdk" --licenses
flutter doctor -v

# ---------------------------------------------------------------------------
Info '6. 產生 Android 專案骨架並套用我們的原始碼'
Push-Location $ProjectRoot
if (-not (Test-Path (Join-Path $ProjectRoot 'android'))) {
  flutter create --platforms=android --project-name photo_album --org com.example.photoalbum .
}
# 覆蓋為我們的程式碼
Copy-Item (Join-Path $SrcDir 'pubspec.yaml') (Join-Path $ProjectRoot 'pubspec.yaml') -Force
if (Test-Path (Join-Path $ProjectRoot 'lib')) { Remove-Item (Join-Path $ProjectRoot 'lib') -Recurse -Force }
Copy-Item (Join-Path $SrcDir 'lib') (Join-Path $ProjectRoot 'lib') -Recurse -Force

# 注入相片庫權限
$manifest = Join-Path $ProjectRoot 'android\app\src\main\AndroidManifest.xml'
$xml = Get-Content $manifest -Raw
if ($xml -notmatch 'READ_MEDIA_IMAGES') {
  $perm = @"
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
    <uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />
    <uses-permission android:name="android.permission.ACCESS_MEDIA_LOCATION" />
    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" />
    <uses-permission android:name="android.permission.SET_WALLPAPER" />
"@
  $xml = $xml -replace '(<manifest[^>]*>)', "`$1`r`n$perm"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($manifest, $xml, $utf8NoBom)
  Write-Host '已注入相片庫權限。'
}
elseif ($xml -notmatch 'READ_MEDIA_VIDEO') {
  # 舊的 android 骨架已有相片權限，但缺影片權限：補上 READ_MEDIA_VIDEO。
  $xml = $xml -replace '(<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />)',
    "`$1`r`n    <uses-permission android:name=`"android.permission.READ_MEDIA_VIDEO`" />"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($manifest, $xml, $utf8NoBom)
  Write-Host '已補上影片讀取權限。'
}

# WorkManager on-demand init：改用自訂 Application 並移除預設啟動初始化器，
# 讓 WorkManager 離開 App 啟動路徑（避免它的自動初始化在某些機型導致一開就閃退）。
$xml2 = Get-Content $manifest -Raw
if ($xml2 -notmatch 'xmlns:tools') {
  $xml2 = $xml2.Replace('<manifest ', '<manifest xmlns:tools="http://schemas.android.com/tools" ')
}
$xml2 = $xml2.Replace('${applicationName}', '.PhotoApplication')
if ($xml2 -notmatch 'WorkManagerInitializer') {
  $prov = @"
        <provider
            android:name="androidx.startup.InitializationProvider"
            android:authorities="`${applicationId}.androidx-startup"
            android:exported="false"
            tools:node="merge">
            <meta-data
                android:name="androidx.work.WorkManagerInitializer"
                tools:node="remove" />
        </provider>

"@
  $xml2 = $xml2.Replace('</application>', $prov + '    </application>')
}
# 註冊 Live Wallpaper service（動態模式 B）
if ($xml2 -notmatch 'PlaylistWallpaperService') {
  $svc = @"
        <service
            android:name=".PlaylistWallpaperService"
            android:exported="true"
            android:label="@string/playlist_wallpaper_label"
            android:permission="android.permission.BIND_WALLPAPER">
            <intent-filter>
                <action android:name="android.service.wallpaper.WallpaperService" />
            </intent-filter>
            <meta-data
                android:name="android.service.wallpaper"
                android:resource="@xml/playlist_wallpaper" />
        </service>

"@
  $xml2 = $xml2.Replace('</application>', $svc + '    </application>')
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifest, $xml2, $utf8NoBom)
Write-Host '已設定 WorkManager on-demand 初始化與 Live Wallpaper service。'

# 注入原生 Kotlin（MainActivity + 桌布輪播）到產生的 package 目錄
$genMain = Get-ChildItem (Join-Path $ProjectRoot 'android\app\src\main') -Recurse -Filter MainActivity.kt |
           Select-Object -First 1
if ($genMain) {
  $pkgDir = $genMain.DirectoryName
  $pkgLine = (Select-String -Path $genMain.FullName -Pattern '^package ' | Select-Object -First 1).Line
  $pkg = ($pkgLine -replace '^package\s+', '' -replace '\s*$', '')
  Write-Host "package: $pkg  dir: $pkgDir"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  Get-ChildItem (Join-Path $SrcDir 'native') -Filter *.kt | ForEach-Object {
    $content = (Get-Content $_.FullName -Raw) -replace '__PACKAGE__', $pkg
    [System.IO.File]::WriteAllText((Join-Path $pkgDir $_.Name), $content, $utf8NoBom)
    Write-Host "已注入原生 $($_.Name)"
  }
  # Live Wallpaper res（xml descriptor + strings；wallpaper_strings.xml 不覆蓋 strings.xml）
  $resSrc = Join-Path $SrcDir 'native\res'
  if (Test-Path $resSrc) {
    $resDst = Join-Path $ProjectRoot 'android\app\src\main\res'
    Copy-Item (Join-Path $resSrc '*') $resDst -Recurse -Force
    Write-Host '已注入 Live Wallpaper 資源（res/xml、res/values）。'
  }
}
else {
  Write-Warning '找不到產生的 MainActivity.kt，略過原生注入。'
}

# 注入 WorkManager 依賴 + proguard keep 規則（靜態輪播用）
# keep 規則避免 release R8 把 WorkManager 的 Room 資料庫類別拿掉導致啟動崩潰。
Copy-Item (Join-Path $SrcDir 'native\proguard-rules.pro') `
          (Join-Path $ProjectRoot 'android\app\proguard-rules.pro') -Force
$appGradle = @('android\app\build.gradle.kts', 'android\app\build.gradle') |
             ForEach-Object { Join-Path $ProjectRoot $_ } |
             Where-Object { Test-Path $_ } | Select-Object -First 1
if ($appGradle) {
  $g = Get-Content $appGradle -Raw
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  if ($g -notmatch 'work-runtime') {
    if ($appGradle -like '*.kts') {
      $g += "`r`ndependencies {`r`n    implementation(`"androidx.work:work-runtime-ktx:2.9.1`")`r`n}`r`n"
    }
    else {
      $g += "`r`ndependencies {`r`n    implementation `"androidx.work:work-runtime-ktx:2.9.1`"`r`n}`r`n"
    }
    Write-Host '已注入 WorkManager 依賴。'
  }
  if ($g -notmatch 'WALLPAPER_PROGUARD') {
    if ($appGradle -like '*.kts') {
      $g += "`r`n// WALLPAPER_PROGUARD`r`nandroid {`r`n    buildTypes {`r`n        getByName(`"release`") {`r`n            proguardFiles(getDefaultProguardFile(`"proguard-android-optimize.txt`"), `"proguard-rules.pro`")`r`n        }`r`n    }`r`n}`r`n"
    }
    else {
      $g += "`r`n// WALLPAPER_PROGUARD`r`nandroid {`r`n    buildTypes {`r`n        release {`r`n            proguardFiles getDefaultProguardFile(`"proguard-android-optimize.txt`"), `"proguard-rules.pro`"`r`n        }`r`n    }`r`n}`r`n"
    }
    Write-Host '已注入 proguard keep 規則。'
  }
  [System.IO.File]::WriteAllText($appGradle, $g, $utf8NoBom)
}

# ---------------------------------------------------------------------------
Info '7. 編譯 APK (release，使用預設 debug 簽章，可直接側載)'
flutter pub get
flutter build apk --release
Pop-Location

$apk = Join-Path $ProjectRoot 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $apk)) { throw "編譯完成但找不到 APK：$apk" }

# ---------------------------------------------------------------------------
Info '8. 打包成壓縮包'
$outZip = Join-Path ([Environment]::GetFolderPath('Desktop')) 'photo_album_apk.zip'
if (Test-Path $outZip) { Remove-Item $outZip -Force }
Compress-Archive -Path $apk -DestinationPath $outZip
Write-Host "`n✅ 完成！" -ForegroundColor Green
Write-Host "APK : $apk"
Write-Host "壓縮包: $outZip"
Write-Host "把 photo_album_apk.zip 傳到手機、解壓縮後點 app-release.apk 安裝（需開啟『允許安裝未知來源』）。"
