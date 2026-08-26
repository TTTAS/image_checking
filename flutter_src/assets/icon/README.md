# App 圖示放這裡

把你的 logo 命名為 **`logo.png`** 放在這個資料夾:

    flutter_src/assets/icon/logo.png

## 規格建議
- **尺寸**: 1024 × 1024 像素(正方形)
- **格式**: PNG
- **留白**: logo 主體置中,四周留約 **20~25% 的空白**。
  因為 Android(尤其 Pixel)的「自適應圖示」會把圖裁成圓形/圓角方形,
  太貼邊的圖會被切掉。留白才不會被裁到。
- 背景色可在 `pubspec.yaml` 的 `adaptive_icon_background` 調整(預設白色 `#FFFFFF`)。

## 放好之後
commit + push,雲端 build 會自動偵測到這張圖並產生所有尺寸的 App 圖示,
不用你手動處理任何 mipmap。若這個檔案不存在,就會沿用預設的 Flutter 圖示。
