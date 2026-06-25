# App Store 再提出ガイド（ActivityVideoStudio）

- **対象**: Mac App Store 再提出（前回 Guideline 2.1(a) でリジェクト＝レビュー用サンプル不足）
- **更新**: 2026-06-24
- **現在のバージョン/ビルド**: `0.1.0 (2)`
- **判定**: ✅ **提出可能**（ブロッカー0／検出した警告2件は修正済み・push済み commit `68135e8`）

---

## 0. 結論（まず読む）

提出に必要な**技術準備はすべて完了**している。残るは **App Store Connect / Xcode 上のあなたの手作業**だけ：

1. Xcode で Archive → Upload
2. App Store Connect で新ビルドを紐付け
3. Resolution Center に返信を貼る（下に文面）
4. 再審査に提出

---

## 1. 事前レビュー結果（提出前チェック済み）

| 項目 | 状態 |
|---|---|
| アプリアイコン | ✅ 完整（16〜1024 全サイズ） |
| Privacy manifest | ✅ 空配列で正しい（Required Reason API 未使用・トラッキング無し） |
| エンタイトルメント | ✅ サンドボックス＋ユーザー選択ファイル読み書き（最小・十分） |
| ドキュメント型 `.avsproj` | ✅ 成果物に正しく反映 |
| DEBUG専用コード | ✅ `#if DEBUG`＝Releaseに含まれない |
| Hardened Runtime | ✅ 復元済み（欠落していた→ commit `68135e8`。成果物に runtime フラグ確認） |
| 暗号化申告 | ✅ `ITSAppUsesNonExemptEncryption=false`（完全オフライン＝免除。提出時の質問を自動回避） |
| ビルド番号 | ✅ 2 に更新（新規アップロードに必須） |
| Release ビルド | ✅ BUILD SUCCEEDED |

---

## 2. 審査員用サンプル（検証済み・そのまま使える）

既存リリース `app-review-samples-v1` の2ファイルを**現行版アプリで実機検証済み**：

- ドロップするだけで **creationDate 自動同期** → オーバーレイが即表示
- 確認フレーム（活動20:29地点）: 146bpm Z3 / 2.8km / 標高385m / GPS地図 すべて正常同期

→ **作り直し不要**。リリース URL: <https://github.com/bokuno-studio/activity-video-studio/releases/tag/app-review-samples-v1>

---

## 3. 手順（あなたの作業）

### Step 1 — Xcode で Archive & Upload
1. Xcode で本プロジェクトを開く
2. 上部のスキーム横の実機/シミュレータ選択を **「My Mac」** に
3. メニュー **Product → Archive**（構成が **Release** であること。Scheme の Archive が Release を使う設定か確認）
4. 完了すると **Organizer** が開く → 対象アーカイブを選択
5. **Distribute App** → **App Store Connect** → **Upload** → 画面に従う（署名は自動／チーム `J92UU2UFBH`）
6. アップロード完了

> うまくいかない場合のよくある原因: Archive が Debug 構成になっている／Distribution 証明書が無い（自動署名なら Xcode が作成）。

### Step 2 — App Store Connect でビルドを紐付け
1. <https://appstoreconnect.apple.com> → My Apps → **ActivityVideoStudio**
2. 処理完了後（数分〜十数分）、バージョン `0.1.0` の **ビルド** に `0.1.0 (2)` を選択
3. （必要なら）スクリーンショット等のメタデータを確認

### Step 3 — Resolution Center に返信（2.1(a) への回答）
1. 同アプリの該当 Submission（ID `177d864b-f963-4cf2-975b-4f1d046ef5a6`）の **Resolution Center** スレッドを開く
2. 下の文面を貼って送信

```
Hello App Review Team,

Thank you for the feedback regarding sample files needed to review ActivityVideoStudio. We've prepared a .FIT activity file and an action-camera .MP4 clip that you can use to verify all core features. They are hosted in a permanent location and will remain available for future reviews.

Sample files (GitHub Releases):
https://github.com/bokuno-studio/activity-video-studio/releases/tag/app-review-samples-v1

Direct downloads:
- sample_activity.fit (≈400 KB) — activity record in .FIT format from a GPS smartwatch
- sample_clip.mp4 (≈148 MB) — action-camera footage (60 s, 1080p H.264)

How to test the app:
1. Launch ActivityVideoStudio.
2. Drag both files into the main window.
3. The app automatically aligns the video and activity using the MP4's creation timestamp. Overlays (heart rate, pace, distance, elevation, mini-map) appear immediately.
4. Press Play to preview the synchronized overlay.
5. Use the Export button to render a final MP4 with overlays burned in.

The 60-second clip was selected from a segment with notable heart-rate variation (≈125 → 157 bpm) so the overlay clearly demonstrates the app's behavior. Please let us know if you need additional samples or longer footage.

Best regards,
Naoki
```

> 小さな注意: 元の文面の「(or use File ▸ Open)」は外した。File ▸ Open は今は **プロジェクト(.avsproj)** を開く操作で、FIT/MP4 は**ドラッグ&ドロップ**で読み込む（上の手順2が正）。誤誘導を避けるための調整。

### Step 4 — 再審査に提出
1. バージョンページで **Add for Review / Submit for Review**
2. ステータスが **Waiting for Review** に戻ることを確認 → 完了

---

## 4. 完了条件
- [ ] `0.1.0 (2)` を Upload した
- [ ] App Store Connect でビルドを紐付けた
- [ ] Resolution Center に返信を投稿した
- [ ] 再審査キューに戻った（Waiting for Review）

---

## 補足
- リリースの律速はこの再提出のみ（GitHub Issue #40）。
- 審査でさらにサンプルや長尺を求められたら、本リポジトリの素材から追加で用意できる。
