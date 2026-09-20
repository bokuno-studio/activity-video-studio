# ActivityVideoStudio

`.FIT` アクティビティデータ（GPS スマートウォッチで記録）とアクションカメラの動画を時刻同期して、心拍・距離・ペース・標高プロファイル・GPSトラックを動画にオーバーレイ合成する macOS ネイティブアプリ。

トレイルランニング、スパルタンレース、ロードレースなどの動画を、アクティビティデータ入りの「計測ログ付き」動画として書き出せる。

## 特徴

- **ネイティブ macOS アプリ**: Swift / SwiftUI / AVFoundation で実装、外部サーバー不要
- **大容量動画対応**: AVAssetExportSession ベースで、10GB超の 4K 動画もストリーミング処理
- **複数動画の自動結合**: アクションカメラが分割した `.MP4` を 1 本にまとめて書き出し
- **FIT 自動同期**: アクションカメラの撮影開始メタデータと FIT の record タイムスタンプを突き合わせる
- **リッチなオーバーレイ**:
  - 心拍数（ゾーン別カラー、FIT の HR Zone 設定を自動反映）
  - ペース / ケイデンス / CORE 体温（Developer Field）
  - 距離 / 経過時間 / 累計獲得標高 / 現在標高
  - 標高プロファイルグラフ（進行度インジケーター付き）
  - 右上にミニマップ（GPS トラックと現在位置）
  - 任意のテキストオーバーレイ（複数 + フェード）
  - `.avstheme` JSON によるオーバーレイテーマの読み込み・書き出し
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

### カメラのGPSで同期する

同期欄の「カメラのGPSで合わせる」で、GoPro MP4（LRVを含む）の GPS5 / GPSU
記録から撮影日時のずれを補正します。「−41.3秒 / 軌跡の一致 2.6m」のように表示し、
「GPS補正を取り消す」で直前の値に戻せます。補正値は通常の同期オフセットとして
プロジェクトに保存され、手入力でも変更できます。

アプリの動画一覧の順序で結合したチャプターの時間軸に対して同じ補正を適用し、複数のFITも
結合済みの記録で比較します。GPSは5秒間隔で比較し、FIT座標を線形補間した距離の
中央値を表示します。記録範囲外や記録の空白は比較に含めません。中央値が50mを超える、
または比較可能なGPSの重なりがない場合は、確認後に適用します。
GPS5の有効なUTC・座標がない動画では日本語で通知し、オフセットを変更しません。
GPS9や断片化MP4のテレメトリには対応していません。

Debugビルドのヘッドレス実行例:

```bash
ActivityVideoStudio.app/Contents/MacOS/ActivityVideoStudio --headless-export \
  --fit activity-1.fit --fit activity-2.fit \
  --video chapter-1.MP4 --video chapter-2.MP4 \
  --align-gps --export-to output.mp4
```

同期引数の優先順位は **`--align-gps` > `--align-fit-start` > `--offset 秒` > 0秒**。
GPSがない場合は下位の引数で決めた値を保持します（加算はしません）。読み取り失敗時は
出力前に中断します。一致度が悪い・確認できない場合も出力前に中断するため、表示を
確認し、適用を選ぶ場合に `--accept-gps-mismatch` を追加して再実行してください。

## アーキテクチャ

`.avstheme` の JSON 仕様は [docs/avstheme-format.md](docs/avstheme-format.md) を参照。

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

## リンク

- [プライバシーポリシー](https://bokuno-studio.github.io/activity-video-studio/privacy.html)
- [Releases](https://github.com/bokuno-studio/activity-video-studio/releases)

## 謝辞

- 地図タイル: [Esri World Imagery](https://www.arcgis.com/home/item.html?id=10df2279f9684e4a9f6a7f08febac2a9)
- FIT Protocol: [FIT SDK](https://developer.garmin.com/fit/protocol/)
