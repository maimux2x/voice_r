# voice_r

Linux (Wayland/GNOME) 向けの個人用音声入力ツール。Git コマンドやよく使う Linux コマンドを音声で入力し、
登録した略語（トリガーフレーズ）を発話すると対応するコマンド文字列に展開して入力する。

設計の背景・全体像は `/home/maimu/.claude/plans/mac-aqua-voice-linux-git-linux-linux-rub-woolly-glade.md` を参照。

## 安全性についての重要な方針

voice_r は認識結果・展開結果のテキストを**入力（キー入力シミュレーション）するだけ**で、
シェルコマンドとして直接実行することは一切しない。誤認識・誤マッチで意図しないコマンドが
勝手に実行されるリスクを避けるため。`rake safety_check` で、シェル文字列経由のプロセス起動
（`` `cmd` ``、`system("...")`、`IO.popen(true, ...)` 等）が紛れ込んでいないかを機械的にチェックする。

## 現在の実装状況（マイルストーンM3: daemon+ソケット+状態遷移+テキスト注入。ydotoolのシステム側セットアップは未実施）

- `bin/voice_r record` — マイクから録音し、Enterキーで停止してWAVパスを表示する
- `bin/voice_r transcribe PATH.wav [LANG]` — 指定したWAVをwhisper-serverに送って認識結果を表示する。
  `LANG`（`ja`/`en`/`auto`等）省略時は`config.yml`の`whisper.language`（デフォルト`ja`）を使う
- `bin/voice_r daemon` — 常駐プロセスを起動（`$XDG_RUNTIME_DIR/voice_r.sock`でソケット待受）
- `bin/voice_r toggle [LANG]` — daemonに録音開始/停止をトグルさせる。停止時はバックグラウンドで
  認識処理が走り、`OK STOPPED`はすぐ返る（認識完了を待たない）
- `bin/voice_r status` — 現在の状態(`idle`/`recording`/`transcribing`)と直近の認識結果をJSONで表示
- `bin/voice_r reload` — `config.yml`を再読込

認識結果は自動でカーソル位置に入力される（`ydotool type`、`lib/voice_r/injector.rb`）。
略語辞書はまだ未実装（M4以降）。GNOMEのカスタムショートカットは`<Ctrl><Super>V`で設定済み。

## セットアップ（このマシンでの実績値）

このマシン(Gentoo, Wayland+GNOME, 24コア/38GB RAM, GPU無し/APU)での実測に基づく手順。

### 1. Rubyの依存関係

```
bundle install
```

### 2. whisper.cpp のビルド（このマシンでは `~/src/whisper.cpp` に構築済み）

```
git clone --depth 1 https://github.com/ggml-org/whisper.cpp ~/src/whisper.cpp
cd ~/src/whisper.cpp
cmake -B build -DGGML_NATIVE=ON -DWHISPER_SDL2=OFF
cmake --build build --config Release -j$(nproc)
```

サーバーバイナリは `build/bin/whisper-server`（バージョンにより名称が変わりうるので `ls build/bin/` で確認）。

### 3. モデルのダウンロード

CPUが強力（24コア/38GB RAM、GPU無し）なため `medium` から開始:

```
cd ~/src/whisper.cpp
sh ./models/download-ggml-model.sh medium
```

精度・速度を見て `medium-q5_0`（量子化・高速）や `large-v3-turbo` への変更を検討する。

### 4. whisper-server の起動（常駐させる）

```
~/src/whisper.cpp/build/bin/whisper-server -m ~/src/whisper.cpp/models/ggml-medium.bin --host 127.0.0.1 --port 8081 -t $(nproc)
```

将来的に `systemd --user` サービス化する（`systemd/whisper-server.service.example` を参照、M6で追加予定）。

### 5. 音声録音コマンド

このマシンには `pw-record` は無く `parecord` のみ存在するため、`config.yml` のデフォルトは `parecord`。
`pw-record` がある環境ではそちらに変更可（`config/config.yml.example` 参照）。

### 6. ydotool（M3で使用）

Gentooのパッケージ名は `x11-misc/ydotool`（確認済み、1.0.4-r4）:

```
sudo emerge --ask x11-misc/ydotool
```

uinputへのアクセス権限が必要:

```
# /etc/udev/rules.d/60-ydotool.rules
KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
```
```
sudo gpasswd -a maimu input
sudo udevadm control --reload && sudo udevadm trigger   # またはreboot
```

グループ反映のため一度ログアウト/ログインが必要な場合がある。その後 `ydotoold` を起動
（一般ユーザーで可、root不要）:

```
ydotoold &
```

組み込む前に手動で動作確認:

```
ydotool type "hello"
```

任意のテキストフィールドにカーソルを置いた状態で実行し、実際に入力されるか確認してください。

GNOME(Mutter)は `wtype` が使う wlr-virtual-keyboard プロトコルに非対応なため `ydotool` を使う。

**ibus/mozc等のIMEが変換モードで有効な場合、`ydotool type`は文字化けする**（実機確認: IME(mozc-jp)が
有効な状態で`ydotool type "hello"`を実行すると`へっぉ`と入力された）。`ydotool`はuinput経由でキーコードを
直接合成しIMEを介さないため、ローマ字入力がかな変換されてしまう。`config.yml`の
`injection.ime_direct_engine`（例: `xkb:us::eng`）を設定すると、`Injector`が注入の前後で自動的に
ibusエンジンを切替・復元する（`lib/voice_r/injector.rb`）。空文字列/未設定なら切替処理自体を行わない。

実装上の注意: `ibus engine <name>`は、エンジン切替自体は成功していても`setxkbmap`（未インストールの場合
あり）呼び出し失敗により非ゼロの終了ステータスを返すことを実機で確認済み。そのため`Injector`は終了
ステータスを信用せず、`ibus engine`（引数無し）で再クエリして実際に切り替わったかを確認する方式にしている。

## 動作確認手順

### CLI単体（M1）

1. `whisper-server` を起動
2. `bundle exec bin/voice_r record` でマイクに向かって話し、Enterで停止 → WAVパスが表示される
3. `bundle exec bin/voice_r transcribe <表示されたパス>` で認識結果が表示されることを確認
4. 日本語フレーズと英語（Git関連）フレーズの両方で試す
5. `bundle exec rake test` でユニットテスト、`bundle exec rake safety_check` で安全性チェックを実行

### daemon経由（M2）

1. `whisper-server` を起動（未起動なら）
2. 別ターミナルで `bundle exec bin/voice_r daemon`（フォアグラウンドで起動、ログは
   `~/.local/state/voice_r/voice_r.log`）
3. さらに別ターミナルから `bundle exec bin/voice_r toggle` → 「録音開始」の通知が出るはず →
   話す → もう一度 `bundle exec bin/voice_r toggle` → 「認識中...」の通知 →
   数秒後に認識結果の通知が出るはず
4. `bundle exec bin/voice_r status` で `state`/`last_transcript` を随時確認できる
5. **通知(notify-send)が実際にデスクトップに表示されるかは目視でしか確認できないため、
   実際に画面を見て確認してください**（このセッションでは配線の疎通のみ機械的に確認済み）

### GNOMEカスタムショートカットの登録（まだ自動化していません。手動で設定してください）

Settings → Keyboard → Custom Shortcuts で以下を追加するか、`gsettings`で:
```
Name: voice_r toggle
Command: ruby /home/maimu/Documents/Source/github.com/maimux2x/voice_r/bin/voice_r toggle
```
キー割り当ては既存ショートカットと衝突しないものを選んでください（例: `<Ctrl><Alt>v`）。
daemonは事前に起動しておく必要がある（今はsystemd化していないので手動起動、または
ターミナルで`bundle exec bin/voice_r daemon &`）。

## 既知の制約

- `ydotool type` はuinput経由のキーコード合成でIMEを介さないため、日本語（かな漢字）の直接入力は
  不安定/不可能な場合がある。MVPでは略語展開後の文字列はASCII前提（Gitコマンド等）としてスコープを絞る。
- **`language: auto`（自動言語判定）は短い発話では実際に誤判定することを確認済み**（日本語の短い発話を
  デンマーク語相当として誤認識した事例あり）。そのためデフォルトは`ja`に固定している。英語で話したい
  場合は `bin/voice_r transcribe PATH.wav en` のように明示的に上書きする。daemon化後（M2）は
  `TOGGLE <lang>` で同様に上書きできるようにする。
- whisper-serverは`--language`未指定で起動した場合、リクエスト側でも`language`パラメータを送らないと
  サーバー内部デフォルトの`en`にフォールバックする（`voice_r`のコードは常に明示的に送るよう実装済み）。
- **`parecord`はSIGTERMで停止させると、録音時間が短い（実測3秒未満）場合に内部バッファが
  フラッシュされずヘッダのみの空WAVになることがある。** SIGINTの方が閾値が短く済むため
  `Recorder`はSIGINTを使う（`lib/voice_r/recorder.rb`）。それでも約2秒未満の録音は
  空になりうるため、`Transcriber`は空WAV(44バイト以下)を検出したら認識をスキップして
  分かりやすいエラーを返す。**トグルしてから発話開始・発話終了からトグルオフまで、
  それぞれ一呼吸置くことを推奨。**
- whisper-serverはリクエストを1件ずつ順番に処理するため、同時に複数リクエストを投げると
  片方が待たされる（daemonの認識中に手動で別のcurl/CLI呼び出しを重ねるとどちらも遅くなる）。
  通常のトグル操作（1回に1発話）では問題にならない。
