# App Store 提出の自動化（CLI・GUIなし）

既存の App Store Connect API キーで、**ターミナルから**アーカイブ→アップロード→再提出する。Xcode の GUI も computer use も不要。

## 前提（認証・値は出力しない）
App Store Connect API の3点を環境変数に入れる。run-coach の `.env` に既にあるので source でよい:

```bash
set -a; . ~/dev/run-coach/.env; set +a   # ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH
```

- `.p8`: `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`（Key ID `P29AKGUR92`）
- 同一 Apple アカウント（team `J92UU2UFBH`）なので ActivityVideoStudio に使える
- キーのロールは **App Manager 以上**が必要（提出するため）

## 使い方

### 1) ビルド→アップロード
```bash
scripts/appstore/build_upload.sh           # ビルド番号は自動（最新+1）
scripts/appstore/build_upload.sh 7         # 明示も可
```
Release アーカイブ → App Store 用 export（クラウド署名・API キー認証）→ アップロード。
※ 新しい **App Store バージョン**を出す時は先に `MARKETING_VERSION`（pbxproj）を上げる。番号一致のビルドだけが版に紐付く。

### 2) 処理完了を確認
```bash
python3 scripts/appstore/asc.py builds 6764239734   # version / processingState / date
```
`VALID` になったら次へ（数分〜15分）。

### 3) 紐付け＋審査ノート＋再提出
```bash
scripts/appstore/submit.sh                 # 最新VALIDビルドを版に紐付け→審査ノート設定→提出
```
- 審査ノートにサンプルファイル情報（`review_notes.txt`）を入れる＝Guideline 2.1(a) 対応
- ステータスが審査待ちになる

### 補助（read-only）
```bash
python3 scripts/appstore/asc.py app com.activityvideostudio.app   # app id / name
python3 scripts/appstore/asc.py version 6764239734               # 編集可能な版 / state
python3 scripts/appstore/asc.py get "/v1/..."                    # 任意GET
```

## 自動化できない＝手動が残るもの（Apple が人手を要求）
- **Apple Developer Program 使用許諾契約の同意**（契約更新時。Account Holder が Web でAgree）
- **EU トレーダーステータス**等の法務系
- **Resolution Center の往復メッセージ**（レビュアーとのやり取り）は公開APIに無い。サンプル情報は審査ノートで代替済み。返信が要る場合のみ Web。

## ファイル
- `asc.py` — App Store Connect API クライアント（stdlib + openssl で ES256 JWT、依存ゼロ）
- `build_upload.sh` — アーカイブ→export→アップロード
- `submit.sh` — 紐付け→審査ノート→再提出
- `ExportOptions.plist` — App Store 配布の export 設定
- `review_notes.txt` — 審査ノート（サンプルファイルの案内）

## 検証状況（2026-06-24）
- ✅ JWT 認証・読み取りAPI（app/builds/version）= 実機で疎通確認済み
- ⏳ archive→upload→submit の write 系 = **次回の実提出で初回検証**（今回はアプリが審査中のため未実行）。初回は出力を見ながら実行すること。
