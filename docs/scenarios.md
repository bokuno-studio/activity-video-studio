# QA シナリオ — ActivityVideoStudio

macOS native SwiftUI app (Garmin .FIT × GoPro .MP4 overlay)。
テスト資産:
- FIT: `/Volumes/Extreme SSD/SDcard/DCIM/100GOPRO/21933178412_ACTIVITY.fit`
- MP4: `/Volumes/Extreme SSD/SDcard/GX010047.MP4` (11GB) / `GX020047.MP4` (9GB)

CLI引数で自動化可能（`--fit`, `--video`, `--trim-start`, `--trim-end`, `--text`, `--export-to`）。ログは `/tmp/avs_export.log`。

## シナリオ: ビルド
- 前提: Xcodeプロジェクトがコンパイル可能
- 操作: `xcodebuild -project ActivityVideoStudio.xcodeproj -scheme ActivityVideoStudio -configuration Debug build`
- 期待結果: BUILD SUCCEEDED、警告/エラーなし

## シナリオ: CLI ヘッドレスエクスポート（短尺）
- 前提: ビルド成功、FIT/MP4 テスト資産あり
- 操作: Debug バイナリを `--fit <path> --video <path> --trim-start 0 --trim-end 29 --text "QA Test" --export-to /tmp/qa_export.mp4` で起動
- 期待結果: 数分以内に /tmp/qa_export.mp4 が生成される、サイズ > 0、`/tmp/avs_export.log` にエラーなし、VideoExporter の progress が 1.0 で完了

## シナリオ: エクスポート出力の妥当性
- 前提: 上記エクスポート成功
- 操作: `ffprobe` / `avformat` / 単純に `ls -la` + `file` で出力を確認
- 期待結果: H.264/HEVC の mp4、再生可能な durationメタデータを持つ、0バイトファイルでない

## シナリオ: VideoExporter 新アーキテクチャの回帰確認
- 前提: メモリに記録された修正方針（`AVVideoComposition(asset:applyingCIFiltersWithHandler:)` + `AVAssetExportSession`）が維持されている
- 操作: `VideoExporter.swift` のソースを grep
- 期待結果: `customVideoCompositorClass` が使われていない、`applyingCIFiltersWithHandler` または同等のクロージャAPIが使われている

## シナリオ: チャプターマーカー / テキストオーバーレイの出力反映（非自動・コード確認）
- 前提: 直近コミット `464791e` で "per-segment overlay + textOverlays in export" を修正
- 操作: VideoExporter のエクスポートパスで textOverlays / chapterMarkers が考慮されているか grep
- 期待結果: exporter 側で両方のデータが受け取られ、フレームレンダリングに反映されている
