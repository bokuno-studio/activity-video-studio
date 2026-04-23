# ActivityVideoStudio

Garmin の `.FIT` アクティビティデータと GoPro の動画を時刻同期して、心拍・距離・ペース・標高プロファイル・GPSトラックを動画にオーバーレイ合成する macOS ネイティブアプリ。

トレイルランニング、スパルタンレース、ロードレースなどの動画を、アクティビティデータ入りの「計測ログ付き」動画として書き出せる。

## 特徴

- **ネイティブ macOS アプリ**: Swift / SwiftUI / AVFoundation で実装、外部サーバー不要
- **大容量動画対応**: AVAssetExportSession ベースで、10GB超の 4K 動画もストリーミング処理
- **複数動画の自動結合**: GoPro が分割した `.MP4` を 1 本にまとめて書き出し
- **FIT 自動同期**: GoPro の撮影開始メタデータと FIT の record タイムスタンプを突き合わせる
- **リッチなオーバーレイ**:
  - 心拍数（ゾーン別カラー、FIT の HR Zone 設定を自動反映）
  - ペース / ケイデンス / CORE 体温（Developer Field）
  - 距離 / 経過時間 / 累計獲得標高 / 現在標高
  - 標高プロファイルグラフ（進行度インジケーター付き）
  - 右上にミニマップ（GPS トラックと現在位置）
  - 任意のテキストオーバーレイ（複数 + フェード）
- **チャプターマーカー**: 再生中に任意時刻を記録 → YouTube 概要欄用タイムコードを自動生成
- **トリミング**: 先頭・末尾カット（同期はトリム後時刻で維持）

## 動作環境

- macOS 14 (Sonoma) 以上
- Xcode 15 以上でビルド
- Apple Silicon / Intel 両対応

## ビルド

```bash
git clone https://github.com/bokuno-studio/activity-video-studio.git
cd activity-video-studio
open ActivityVideoStudio.xcodeproj
```

Xcode で Run するか、CLI で:

```bash
xcodebuild -project ActivityVideoStudio.xcodeproj \
           -scheme ActivityVideoStudio \
           -configuration Debug \
           -destination 'platform=macOS' \
           build
```

## 使い方

1. アプリを起動
2. 左サイドバーに `.FIT` ファイルと `.MP4` 動画を**ドラッグ＆ドロップ**
3. プレビュー画面で同期ずれがあればオフセットを調整
4. 右パネルでトリミング / テキスト / チャプターを編集
5. 「エクスポート」→ 解像度（720p / 1080p / 4K）・品質を選択
6. **外付けSSD等の空きが豊富なドライブに保存**すると安全（中間 temp ファイルが同ボリューム上に作られる）

### CLI（デバッグ用）

`Debug` ビルドには、`NSSavePanel` をバイパスしたヘッドレスエクスポート機能がある:

```bash
APP=".../ActivityVideoStudio.app/Contents/MacOS/ActivityVideoStudio"
"$APP" \
  --fit /path/to/activity.fit \
  --video /path/to/GX010001.MP4 \
  --video /path/to/GX020001.MP4 \
  --trim-start-0 570 --trim-end-0 0 \
  --trim-start-1 0   --trim-end-1 120 \
  --width 3840 --height 2160 \
  --text "Title" --text-pos topCenter --text-size 120 \
  --export-to /path/to/output.mp4
```

進捗・結果は `/tmp/avs_export.log` に追記される（`[AutoExport] DONE ✓` で完了）。

## アーキテクチャ

```
ActivityVideoStudio/Sources/
├── App/                     エントリポイント
├── Models/                  FITDataPoint, TrimSettings, OverlaySettings, ...
├── Services/
│   ├── FITParser.swift          FIT パーサー
│   ├── VideoMetadataReader.swift    MP4 メタデータ読み取り（創作日時など）
│   ├── TimeSync.swift           FIT × Video 時刻同期
│   ├── OverlayRenderer.swift    Core Graphics でのオーバーレイ合成
│   ├── VideoExporter.swift      AVAssetExportSession + AVVideoComposition
│   └── YouTubeDescriptionGenerator.swift
└── Views/                   SwiftUI ビュー群
```

### エクスポートパイプライン

> macOS 26 (Tahoe) では `AVMutableVideoComposition.customVideoCompositorClass` がサイレントにバイパスされるため、**クロージャベースの `AVVideoComposition(asset:applyingCIFiltersWithHandler:)`** を採用している。

1. `AVMutableComposition` で各セグメントを連結
2. `AVVideoComposition(asset:applyingCIFiltersWithHandler:)` で毎フレームに OverlayRenderer の CGImage を CIImage 合成
3. 中間 mp4 は **出力先と同じボリュームの temp ファイル**に書き、最後に passthrough concat
4. FIT のデータ点は `TimeSync` が segment / playbackTime / offset を考慮して返す

## ライセンス

MIT License — 詳細は [LICENSE](./LICENSE) を参照。

## 謝辞

- 地図タイル: [Esri World Imagery](https://www.arcgis.com/home/item.html?id=10df2279f9684e4a9f6a7f08febac2a9)
- FIT Protocol: [Garmin FIT SDK](https://developer.garmin.com/fit/protocol/)
