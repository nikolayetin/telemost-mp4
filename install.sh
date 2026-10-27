#!/bin/zsh -f
# Telemost MP4 - установка. Собирает программу «Telemost MP4» (runner.swift + convert.sh + настройки, всё вшито)
# и ставит launchd-агент local.telemost-mp4: он будит программу, когда в папке записей Телемоста что-то появилось
# или переименовалось, и один раз при входе в систему.
#   zsh install.sh                - поставить или обновить
#   zsh install.sh --dir <папка>  - папка записей вручную (по умолчанию - из журнала Телемоста)
#   zsh install.sh --keep-webm    - после перекодирования оставлять webm рядом с mp4 (по умолчанию - в корзину)
#   zsh install.sh --trash-webm   - снова убирать webm в корзину
#   zsh install.sh --all          - перекодировать и старые записи (и те, от которых раньше отказались), без вопроса
#   zsh install.sh --rebuild      - пересобрать программу (доступ к папке записей придётся дать заново)
#   zsh install.sh uninstall      - снять всё (в корзину) и отозвать доступ; записи не трогаются
setopt null_glob
zmodload -F zsh/stat b:zstat
R="${0:A:h}"
L=local.telemost-mp4
APP="$HOME/Applications/Telemost MP4.app"
EXE="$APP/Contents/MacOS/telemost-mp4"
PL="$HOME/Library/LaunchAgents/$L.plist"
ST="$HOME/Library/Application Support/telemost-mp4"
LOG="$HOME/Library/Logs/telemost-mp4.log"
TL="$HOME/Library/Application Support/Yandex.Telemost/log"   # журнал программы Телемоста
# строка журнала, с которой Телемост начинает запись: время, уровень, служба - имена участников её не подделают
RX='^[0-9-]+\.[0-9]+ \[[^]]*\]\[I\] LocalRecordService record started: /.*\.webm$'

say() { print -r -- "$*" }
die() { print -r -- "✗ $*" >&2; exit 1 }
ask() { [[ -t 0 ]] || return 1; read -q "?$1 [y/N] "; local r=$?; print; return $r }
xml() { local s=${1//&/&amp;}; s=${s//</&lt;}; print -r -- "${s//>/&gt;}" }
swiftstr() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; print -r -- "\"${s//$'\r'/\\r}\"" }
trash() { [[ -e "$1" ]] && mv -- "$1" "$HOME/.Trash/${1:t:r} $(date +%Y%m%d-%H%M%S)${${1:e}:+.${1:e}}" }
# launchd гасит программу, она передаёт сигнал скрипту, тот - ffmpeg; ждём, пока выйдут все
stop_agent() {
  launchctl bootout "gui/$UID" "$PL" 2>/dev/null
  for i in {1..40}; do pgrep -f telemost-mp4-worker >/dev/null || return 0; sleep 0.25; done
  pkill -f telemost-mp4-worker; sleep 1
}
uninstall() {
  stop_agent
  local d=$(cat "$ST/dir.txt" 2>/dev/null) x
  [[ -n "$d" ]] && for x in "$d"/.*.part; do trash "$x"; done
  trash "$PL"; trash "$APP"; trash "$ST"; trash "$LOG"
  tccutil reset All "$L" >/dev/null 2>&1
  say "✓ Telemost MP4 снят, всё в корзине, доступ к папке записей отозван. Записи на месте."
  say "  ffmpeg остался на месте (ставил его ради Telemost MP4 через Homebrew - brew uninstall ffmpeg)"
  exit 0
}

[[ "$OSTYPE" == darwin* ]] || die "Telemost MP4 работает только на macOS"
keep=; all=0; rebuild=0; dir=
while (( $# )); do
  case "$1" in
    --dir) [[ -n "$2" ]] || die "после --dir нужна папка"; dir=$2; shift ;;
    --keep-webm) keep=1 ;;
    --trash-webm) keep=0 ;;
    --all) all=1 ;;
    --rebuild) rebuild=1 ;;
    uninstall) uninstall ;;
    *) die "не знаю ключ $1 (есть --dir, --keep-webm, --trash-webm, --all, --rebuild, uninstall)" ;;
  esac
  shift
done

[[ -d /Applications/Yandex.Telemost.app || -d "$HOME/Applications/Yandex.Telemost.app" ]] || say "! Не нашёл программу Телемоста в /Applications. Telemost MP4 работает с записями программы для компьютера: https://yandex.ru/support/telemost-desktop/"

# ffmpeg: свой, из Homebrew или поставим через Homebrew
find_ff() {
  local c
  for c in "$(command -v ffmpeg)" /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg "$HOME/.local/bin/ffmpeg"; do
    [[ -n "$c" && -x "$c" && -x "${c:h}/ffprobe" ]] && { print -r -- "${c:a}"; return 0 }
  done
  return 1
}
if ! FFMPEG=$(find_ff); then
  BREW=; for b in "$(command -v brew)" /opt/homebrew/bin/brew /usr/local/bin/brew; do [[ -n "$b" && -x "$b" ]] && { BREW=$b; break }; done
  [[ -n "$BREW" ]] || die "Нужен ffmpeg. Проще всего через Homebrew: поставь его с https://brew.sh и запусти установку ещё раз"
  ask "ffmpeg не найден. Поставить через Homebrew (brew install ffmpeg)?" || die "Без ffmpeg не получится: brew install ffmpeg, потом установка ещё раз"
  "$BREW" install ffmpeg || die "brew install ffmpeg не прошёл"
  FFMPEG=$(find_ff) || die "ffmpeg так и не нашёлся"
fi
FFPROBE="${FFMPEG:h}/ffprobe"
# какой кодировщик реально работает - проверяем на секундном тестовом ролике (заодно версию: -fps_mode с ffmpeg 5.1)
enc_ok() {
  "$FFMPEG" -hide_banner -loglevel error -nostdin -f lavfi -i "testsrc2=d=1:s=640x360:r=12" \
    -f lavfi -i "sine=d=1:sample_rate=48000" "$@" -fps_mode passthrough -f null - </dev/null >/dev/null 2>&1
}
if [[ "$CPUTYPE" == arm64 ]] && enc_ok -c:v h264_videotoolbox -q:v 55 -an; then V=vt-q
elif enc_ok -c:v h264_videotoolbox -b:v 2M -an; then V=vt-b
elif enc_ok -c:v libx264 -preset veryfast -crf 23 -an; then V=x264
else die "$FFMPEG не перекодирует в H.264 (нужен ffmpeg 5.1 или новее): brew upgrade ffmpeg"; fi
if enc_ok -vn -c:a aac_at -b:a 128k; then A=at
elif enc_ok -vn -c:a aac -b:a 128k; then A=aac
else die "$FFMPEG не перекодирует звук в AAC"; fi

# папка записей: --dir, иначе куда Телемост писал в последний раз (по его журналу), иначе «Документы/Телемост»
if [[ -n "$dir" ]]; then
  DIR=${dir:a}; [[ -d "$DIR" ]] || die "нет папки $DIR"
else
  p=
  for lf in "$TL"/*.log(om); do p=$(grep -a -E "$RX" "$lf" | tail -1); [[ -n "$p" ]] && break; done
  DIR=${${p#*record started: }:h}
  if [[ -z "$p" || ! -d "$DIR" ]]; then
    [[ -n "$p" ]] && say "→ папки, куда Телемост писал в последний раз ($DIR), уже нет" || say "→ Телемост на этом Mac ещё ничего не записывал"
    DIR="$HOME/Documents/Телемост"; [[ -d "$HOME/Documents/Telemost" && ! -d "$DIR" ]] && DIR="$HOME/Documents/Telemost"
    say "  беру стандартную папку $DIR (если в настройках Телемоста стоит другая: zsh install.sh --dir <папка>)"
    mkdir -p "$DIR" || die "Не смог создать $DIR"
  fi
fi
DIR=${DIR:A}
for g in / "$HOME" "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads" "$HOME/Movies" "$HOME/Pictures" "$HOME/Music" "$HOME/Library"; do
  [[ "$DIR" == "${g:A}" ]] && die "Записи идут прямо в $DIR, а Telemost MP4 следит только за отдельной папкой. Выбери в настройках Телемоста отдельную папку для записей (например, «Документы/Телемост») и запусти установку ещё раз"
done
err=$(ls -A "$DIR" 2>&1 >/dev/null)
[[ -z "$err" ]] || die "Терминалу нет доступа к $DIR ($err). Разреши его: Системные настройки → Конфиденциальность и безопасность → Файлы и папки, и запусти установку ещё раз"

# программа собирается во временной папке, пока работает прежняя: упадёт сборка - сторож остаётся как был
mkdir -p "$ST" "${LOG:h}"
sum=$({ cat "$R/runner.swift" "$R/convert.sh"; print -r -- "$DIR|$FFMPEG|$FFPROBE|$V|$A" } | shasum -a 256 | cut -d' ' -f1)
W=
if [[ ! -x "$EXE" || "$rebuild" == 1 || "$(cat "$ST/build.sha256" 2>/dev/null)" != "$sum" ]]; then
  xcrun --find swiftc >/dev/null 2>&1 || die "Нужны инструменты разработчика Apple: xcode-select --install, потом установка ещё раз"
  [[ "$(<"$R/convert.sh")" == *'"""#'* ]] && die "convert.sh нельзя вшить в программу: в нём есть \"\"\"#"
  W=$(mktemp -d "${TMPDIR:-/tmp}/telemost-mp4.XXXXXX") || die "не создал временную папку"
  {
    print -r -- "import Foundation"
    print -r -- "// сгенерировано install.sh: скрипт и настройки вшиты в программу"
    print -r -- "let embeddedScript = #\"\"\""
    cat "$R/convert.sh"
    print -r -- "\"\"\"#"
    print -r -- "let recordingsDir = $(swiftstr "$DIR")"
    print -r -- "let ffmpegPath = $(swiftstr "$FFMPEG")"
    print -r -- "let ffprobePath = $(swiftstr "$FFPROBE")"
    print -r -- "let videoPreset = \"$V\""
    print -r -- "let audioPreset = \"$A\""
    cat "$R/runner.swift"
  } > "$W/main.swift"
  mkdir -p "$W/app/Contents/MacOS"
  xcrun swiftc -O -o "$W/app/Contents/MacOS/telemost-mp4" "$W/main.swift" || die "Не собралась программа"
  cat > "$W/app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$L</string>
  <key>CFBundleName</key><string>Telemost MP4</string>
  <key>CFBundleExecutable</key><string>telemost-mp4</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
  codesign --force --sign - -o runtime --identifier "$L" "$W/app" 2>/dev/null || die "Не подписалась программа"
fi

# дальше меняем установленное - сначала останавливаем агента, чтобы работающий сторож не попал на полуобновлённое
stop_agent
if [[ -n "$W" ]]; then
  trash "$APP"; mkdir -p "${APP:h}"; mv "$W/app" "$APP" || die "Не поставил программу в ${APP:h}"
  rm -f "$W/main.swift"; rmdir "$W"
  print -r -- "$sum" > "$ST/build.sha256"
  built=1
fi
print -r -- "$DIR" > "$ST/dir.txt"   # для uninstall
[[ "$keep" == 1 ]] && touch "$ST/keep-webm"
[[ "$keep" == 0 ]] && rm -f "$ST/keep-webm"
touch "$ST/done.txt" "$ST/seen.txt"

# старые записи: перекодировать или оставить как есть. Запись, которую Телемост пишет прямо сейчас, не трогаем
old=(); bytes=0
for f in "$DIR"/*.webm; do
  [[ -f "$f" && ! -e "${f:r}.mp4" ]] || continue
  zstat -H s -- "$f" || continue
  # от старых записей раньше отказались (они в done.txt) - --all берёт и их; уже у сторожа (seen.txt) - не трогаем
  grep -qxF -- "$s[inode] $s[size]" "$ST/done.txt" && (( ! all )) && continue
  grep -q "^$s[inode]"$'\t' "$ST/seen.txt" && continue
  lsof -a -c Yandex.Telemost -t -- "$f" >/dev/null 2>&1 && continue
  old+=("$f"); (( bytes += ${s[size]} ))
done
if (( $#old )); then
  what="mp4 появится рядом"; [[ -e "$ST/keep-webm" ]] || what+=", webm уйдёт в корзину"
  if (( all )) || ask "В папке старых записей: $#old ($(( bytes / 1048576 )) МБ). Перекодировать и их ($what)?"; then
    keys=(); for f in $old; do zstat -H s -- "$f" && keys+=("$s[inode] $s[size]") && print -r -- "$s[inode]"$'\t'OLD >> "$ST/seen.txt"; done
    grep -vxF -f <(print -rl -- $keys) "$ST/done.txt" > "$ST/done.txt.new"; mv "$ST/done.txt.new" "$ST/done.txt"
    say "→ старые записи ($#old) перекодирую в фоне, по одной"
  else
    for f in $old; do zstat -H s -- "$f" && print -r -- "$s[inode] $s[size]" >> "$ST/done.txt"; done
    say "→ в папке старых записей: $#old ($(( bytes / 1048576 )) МБ), их не трогаю. Перекодировать: zsh install.sh --all"
  fi
fi

cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$L</string>
  <key>ProgramArguments</key><array><string>$(xml "$EXE")</string></array>
  <key>WatchPaths</key><array><string>$(xml "$DIR")</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$(xml "$LOG")</string>
  <key>StandardErrorPath</key><string>$(xml "$LOG")</string>
</dict></plist>
PLIST
plutil -lint -s "$PL" || die "Не получился $PL"
launchctl bootstrap "gui/$UID" "$PL" || die "launchd не принял агента"

say "✓ Telemost MP4 стоит"
say "  папка записей: $DIR"
say "  webm после перекодирования: $([[ -e "$ST/keep-webm" ]] && print остаётся рядом || print в корзину)"
say "  журнал: ~/Library/Logs/telemost-mp4.log"
if [[ -n "$built" ]]; then say "Если macOS спросит, пустить ли «Telemost MP4» к папке с записями, - разреши, иначе он их не увидит."; fi
exit 0
