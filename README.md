# voice_r

Linux (Wayland/GNOME) 向けの個人用音声入力ツール。Git コマンドやよく使う Linux コマンドを音声で入力し、
登録した略語（トリガーフレーズ）を発話すると対応するコマンド文字列に展開して入力する。

設計の背景・全体像は `/home/maimu/.claude/plans/mac-aqua-voice-linux-git-linux-linux-rub-woolly-glade.md` を参照。

## 安全性についての重要な方針

voice_r は認識結果・展開結果のテキストを**入力（キー入力シミュレーション）するだけ**で、
シェルコマンドとして直接実行することは一切しない。誤認識・誤マッチで意図しないコマンドが
勝手に実行されるリスクを避けるため。`rake safety_check` で、シェル文字列経由のプロセス起動
（`` `cmd` ``、`system("...")`、`IO.popen(true, ...)` 等）が紛れ込んでいないかを機械的にチェックする。

## 現在の実装状況（マイルストーンM3: daemon+ソケット+状態遷移+テキスト注入。ydotool/wl-clipboardの
システム側セットアップ・実機確認済み）

- `bin/voice_r record` — マイクから録音し、Enterキーで停止してWAVパスを表示する
- `bin/voice_r transcribe PATH.wav [LANG]` — 指定したWAVをwhisper-serverに送って認識結果を表示する。
  `LANG`（`ja`/`en`/`auto`等）省略時は`config.yml`の`whisper.language`（デフォルト`ja`）を使う
- `bin/voice_r daemon` — 常駐プロセスを起動（`$XDG_RUNTIME_DIR/voice_r.sock`でソケット待受）
- `bin/voice_r toggle [LANG]` — daemonに録音開始/停止をトグルさせる。停止時はバックグラウンドで
  認識処理が走り、`OK STOPPED`はすぐ返る（認識完了を待たない）
- `bin/voice_r status` — 現在の状態(`idle`/`recording`/`transcribing`)と直近の認識結果をJSONで表示
- `bin/voice_r reload` — `config.yml`を再読込

認識結果は自動でカーソル位置に入力される（ASCIIは`ydotool type`、非ASCII(日本語自由文)は
`wl-copy`+`ydotool key`によるクリップボード貼り付け、`lib/voice_r/injector.rb`）。
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

### 7. wl-clipboard（日本語入力の貼り付け経路で使用）

Gentooのパッケージ名は `gui-apps/wl-clipboard`（確認済み、2.3.0）:

```
sudo emerge --ask gui-apps/wl-clipboard
```

`wl_data_device_manager`（コアのWaylandプロトコル）のみに依存しwlroots固有のプロトコルは不要なため、
sway等だけでなくGNOME(Mutter)でも動作することを実機確認済み。

組み込む前に手動で動作確認:

```
echo -n "test" | wl-copy
wl-paste
wl-paste --no-newline   # 末尾に改行を付与しない版。復元時の余分な改行を避けるため使用
```

`wl-paste`が`test`を返せばOK。空クリップボードに対しては`wl-paste`は非ゼロ終了することを実機確認済み
（`wl-copy --clear`で試すと`Nothing is copied`と表示され終了ステータスが失敗になる）。`Injector`は
どちらの挙動でも正しく動くように設計されている（空なら復元自体をスキップする）。

**日本語（非ASCII）テキストの入力方式:** `ydotool type`はuinput経由のキーコード合成でIMEを介さない
ため、そもそも日本語（かな漢字）に対応するキーコードが存在せず直接入力できない（IMEの状態に関係なく
不可能。ローマ字がかな変換される`ime_direct_engine`の問題とは別種の制約）。そのため`text.ascii_only?`
が偽の認識結果は、`wl-copy`でクリップボードに載せてから`ydotool key`でCtrl+Vキーストロークを送る
方式で入力する。

実装上の重要な注意（実機で発見・確認済み）: **`wl-copy`はデフォルトでバックグラウンドにforkし、
クリップボードの所有者として存在し続ける**（貼り付けが実際に行われるまで生きている必要があるため）。
このため`Open3.capture3`で`wl-copy`を呼ぶと、forkされた子プロセスがstdout/stderr用のパイプを
継承したまま保持し続け、パイプのEOFを待つ`Open3.capture3`が**永久にハングする**ことを実機で確認した。
回避策として`Injector#write_clipboard`/`restore_clipboard`は`Open3.capture3`ではなく
`Process.spawn`（出力を`File::NULL`に破棄、`Recorder`と同じパターン）+`Process.wait2`
（特定の子プロセスのPIDの終了だけを待つ、パイプの状態に依存しない）を使っている。
一方`wl-paste`はforkしない一回限りのコマンドのため`Open3.capture3`のままで問題ない。

Ctrl+Vキーコードの実装メモ: このydotoolバージョン(1.0.4-r4)の`ydotool key`はシンボリック名
（`ctrl`等）を受け付けず、生のLinux input-eventキーコードのみ対応
（`man ydotool`および同梱READMEに記載のv1.0.0時点の破壊的変更）。Ctrl+Vは
`ydotool key 29:1 47:1 47:0 29:0`（29=KEY_LEFTCTRL, 47=KEY_V;
ctrl押下→v押下→v解放→ctrl解放）。

貼り付け後、貼り付け前のクリップボード内容を`config.yml`の
`injection.clipboard_paste_delay`（デフォルト0.4秒）待ってから復元する。この遅延は、
貼り付け先アプリが実際にクリップボードを読み取るまで待つためのもの（早すぎると
復元後の内容を読んでしまうレースコンディションになる）。実測に基づくチューニングが
必要になる可能性がある（`parecord`のSIGTERM/SIGINTタイミングの件と同様、このマシン固有の
値になりうる）。

**別途の既知の課題（本機能のスコープには含めない）:** `ydotoold`が systemd --user / OpenRC で
自動起動・永続化されておらず、手動起動（`ydotoold &`）に依存している。既存の`ydotool type`経路
も含めた全体の運用上の穴であり、M6ストレッチ課題候補として記録するのみ
（`/etc/init.d/ydotool`(OpenRC, supervise-daemon使用)が存在するが無効化状態）。

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

### 日本語貼り付け経路（クリップボード貼り付け機能）

1. `wl-clipboard`がインストール済みか確認（`which wl-copy wl-paste`）。未installなら
   上記セットアップ節「7. wl-clipboard」の手順でインストール
2. `ydotoold`が起動しているか確認（`pgrep -x ydotoold`）。起動していなければ`ydotoold &`
   （前述の通り、現状は手動起動が必要）
3. クリップボードに重要な内容が入っていないか確認（このテストで一時的に上書き・復元されるため）
4. `whisper-server`と`bundle exec bin/voice_r daemon`を起動
5. ブラウザ（Firefox等）の任意のテキストフィールド（検索窓等）にカーソルを置く
6. `bundle exec bin/voice_r toggle`で録音開始、日本語の文章を発話、もう一度toggleで停止
7. 認識結果が貼り付けとして反映されることを確認（`ydotool type`のような文字化けではなく、
   正しい日本語として入力されること）— 実機確認済み
8. 貼り付け前にクリップボードに入っていた内容が、貼り付け後しばらくして正しく
   復元されていることを確認（`wl-paste`で確認、または別の場所へのCtrl+Vで確認）— 実機確認済み
9. 英語（ASCIIのみ）の発話も試し、従来通り`ydotool type`経路（IME切替込み）が
   引き続き動作することを確認（回帰確認）
10. `bundle exec rake test` / `bundle exec rake safety_check`を実行

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

- `ydotool type` はuinput経由のキーコード合成でIMEを介さないため、そもそも日本語（かな漢字）に
  対応するキーコードが存在せず直接入力できない（IME状態に関係なく不可能）。この制約を回避するため、
  認識結果が`text.ascii_only?`でない場合はクリップボード経由（`wl-copy`/`wl-paste` +
  `ydotool key`によるCtrl+Vシミュレーション）で貼り付ける方式にフォールバックする
  （`lib/voice_r/injector.rb`の`inject_via_paste`）。詳細はセットアップ節の
  「7. wl-clipboard」を参照。
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
