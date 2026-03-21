# Garmin × GoPro Overlay App

## プロジェクト概要

GoPro で撮影したトレイルランニング・スパルタンレース等の動画に、Garmin Fenix 8 のアクティビティデータ（.FIT ファイル）をオーバーレイ合成する Mac ネイティブアプリを開発する。

### ゴール
1. Garmin .FIT ファイルと GoPro MP4 動画を時刻同期する
2. 動画上にリアルタイムのアクティビティデータをオーバーレイ描画する
3. 複数動画を結合し、1本のオーバーレイ付き動画として書き出す
4. 合計 1〜15 時間の大容量動画を安定して処理できること

---

## 技術スタック

- **言語**: Swift
- **UI**: SwiftUI
- **動画処理**: AVFoundation（AVComposition, AVVideoComposition, AVAssetExportSession）
- **描画**: Core Graphics / Core Animation（オーバーレイ描画）
- **地図**: MapKit（ミニマップ表示用）
- **FIT パーサー**: FIT SDK（Swift ラッパー）または自前パーサー
- **プラットフォーム**: macOS（将来的に iOS 対応も視野）
- **最小対応**: macOS 14 (Sonoma) 以上

---

## オーバーレイ要素（優先順位順）

### 必須
1. **地図（ミニマップ）** — GPS トラックを表示し、現在位置をリアルタイムで示す。最優先
2. **累計距離** — km 表示
3. **経過時間** — HH:MM:SS
4. **心拍数** — bpm、ゾーン別に色を変える（Z1〜Z5）

### あると良い
5. **ペース** — min/km
6. **傾斜（勾配）** — %、登り/下りで色分け
7. **標高** — m、ミニ標高プロファイルグラフ
8. **ケイデンス** — spm（ランニングの場合）

### 配置
- ユーザーが参考画像を提供予定。それを元にレイアウトを決定する
- デフォルトは画面下部にダッシュボード風バー + 右下にミニマップ

---

## Garmin Fenix 8 の .FIT ファイル

### 主要フィールド
- `timestamp` — UTC タイムスタンプ
- `position_lat` / `position_long` — 半円単位の緯度経度（semicircles → degrees 変換必要）
- `heart_rate` — bpm
- `enhanced_speed` / `speed` — m/s
- `enhanced_altitude` / `altitude` — m
- `cadence` — spm（ランニング）
- `distance` — 累計距離 m
- `grade` — 勾配 %（フィールドがない場合は altitude から計算）

### 注意点
- FIT ファイルのタイムスタンプは Garmin エポック（1989-12-31 00:00:00 UTC 起点）
- semicircles → degrees: `degrees = semicircles * (180 / 2^31)`
- `record` メッセージが主データソース（通常 1 秒間隔）

---

## GoPro 動画

### メタデータ
- GoPro MP4 には `creationDate` がメタデータに含まれる
- 一部モデルは GPMF（GoPro Metadata Format）で GPS を記録
- 動画のタイムスタンプと Garmin のタイムスタンプを照合して同期

### 大容量対応（最重要設計要件）
- 動画は 1 ファイルで数 GB〜数十 GB になることがある
- **絶対に動画全体をメモリに載せない**
- AVAssetReader / AVAssetWriter でストリーミング処理
- チャンク単位での処理・プログレス表示
- エクスポートはバックグラウンドスレッドで実行
- 中間ファイルの一時ディレクトリ管理と自動クリーンアップ

---

## 同期ロジック

### 自動同期
1. GoPro MP4 の `creationDate`（撮影開始時刻）を取得
2. Garmin .FIT の `record` メッセージの `timestamp` と照合
3. 動画の再生位置（秒）に対応する Garmin データポイントを補間で取得

### 手動補正
- UI でオフセット（秒）を ±調整できるスライダー
- プレビューで同期状態を確認できること

---

## アプリの画面構成（案）

### 1. プロジェクト画面
- .FIT ファイルと複数の MP4 ファイルをドラッグ&ドロップで追加
- 各動画の開始時刻・長さを一覧表示
- 動画の並び順をドラッグで変更

### 2. 同期 & プレビュー画面
- 動画プレビュー + オーバーレイのリアルタイム表示
- タイムラインバー（動画位置 + Garmin データグラフ）
- 同期オフセット調整スライダー

### 3. オーバーレイ設定画面
- 表示する要素の ON/OFF
- 配置位置の調整
- フォント・色・透明度の設定

### 4. エクスポート画面
- 出力解像度・品質の選択
- 複数動画の結合オプション
- プログレスバー（推定残り時間付き）

---

## 開発フェーズ

### Phase 1: 基盤（MVP）
- [ ] プロジェクト作成（Xcode, SwiftUI）
- [ ] .FIT ファイルパーサー（record メッセージの読み取り）
- [ ] GoPro MP4 メタデータ読み取り（creationDate）
- [ ] 時刻同期ロジック
- [ ] 基本オーバーレイ描画（距離・時間・心拍をテキスト表示）
- [ ] 動画プレビュー with オーバーレイ

### Phase 2: 地図 & UI
- [ ] ミニマップ（MapKit + GPS トラック + 現在位置マーカー）
- [ ] ペース・傾斜の表示
- [ ] オーバーレイのレイアウト調整 UI
- [ ] 同期オフセットの手動調整 UI

### Phase 3: エクスポート & 結合
- [ ] AVAssetWriter によるオーバーレイ付き動画書き出し
- [ ] 複数動画の結合（AVMutableComposition）
- [ ] プログレス表示
- [ ] 大容量動画の安定処理（メモリ管理、チャンク処理）

### Phase 4: 仕上げ
- [ ] 心拍ゾーン色分け
- [ ] 標高プロファイルグラフ
- [ ] デザイン調整（ユーザーの参考画像を反映）
- [ ] エラーハンドリング・エッジケース対応

---

## コーディング規約

- Swift の命名規則に従う（camelCase、型名は PascalCase）
- SwiftUI のビューは小さく分割する（1ビュー = 1ファイル目安）
- 動画処理は必ずバックグラウンドスレッドで実行
- ユーザー向けエラーメッセージは日本語
- コメントは英語（Swift 標準に合わせる）

---

## 参考情報

- Garmin FIT SDK: https://developer.garmin.com/fit/protocol/
- AVFoundation プログラミングガイド: Apple Developer Documentation
- GoPro GPMF: https://github.com/gopro/gpmf-parser
- 類似 OSS: https://github.com/AThomsen/telemetry-overlay
