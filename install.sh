#!/bin/zsh
# Telemost MP4 - установка. Ставит (или обновляет) программу «Telemost MP4» и launchd-агент local.telemost-mp4:
# он будит программу, когда в папке записей Телемоста что-то появилось или переименовалось, и один раз при входе.
#   zsh install.sh               - поставить или обновить
#   zsh install.sh --keep-webm   - после перекодирования оставлять webm рядом с mp4 (по умолчанию - в корзину)
#   zsh install.sh --trash-webm  - снова убирать webm в корзину
#   zsh install.sh --all         - перекодировать и старые записи, без вопроса
#   zsh install.sh --rebuild     - пересобрать программу (доступ к «Документам» придётся дать заново)
#   zsh install.sh uninstall     - снять всё (в корзину); записи не трогаются
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

say() { print -r -- "$*" }
die() { print -r -- "✗ $*" >&2; exit 1 }
ask() { [[ -t 0 ]] || return 1; read -q "?$1 [y/N] "; local r=$?; print; return $r }
xml() { local s=${1//&/&amp;}; s=${s//</&lt;}; print -r -- "${s//>/&gt;}" }
trash() { [[ -e "$1" ]] && mv "$1" "$HOME/.Trash/${1:t:r} $(date +%Y%m%d-%H%M%S)${${1:e}:+.${1:e}}" }

[[ "$OSTYPE" == darwin* ]] || die "Telemost MP4 работает только на macOS"
keep=$([[ -f "$ST/config" ]] && source "$ST/config" && print -r -- "$KEEP_WEBM"); keep=${keep:-0}   # прошлый выбор
all=0; rebuild=0
for a in "$@"; do
  case "$a" in
    --keep-webm) keep=1 ;;
    --trash-webm) keep=0 ;;
    --all) all=1 ;;
    --rebuild) rebuild=1 ;;
    uninstall)
      launchctl bootout "gui/$UID" "$PL" 2>/dev/null
      trash "$PL"; trash "$APP"; trash "$ST"; trash "$LOG"
      say "✓ Telemost MP4 снят, всё в корзине. Записи на месте."; exit 0 ;;
    *) die "не знаю ключ $a (есть --keep-webm, --trash-webm, --all, --rebuild, uninstall)" ;;
  esac
done

[[ -d /Applications/Yandex.Telemost.app ]] || say "! Не нашёл программу Телемоста в /Applications. Telemost MP4 работает с записями программы для компьютера: https://yandex.ru/support/telemost-desktop/"

# ffmpeg: свой, из Homebrew или поставим через Homebrew
find_ff() {
  local c
  for c in "$(command -v ffmpeg)" /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg "$HOME/.local/bin/ffmpeg"; do
    [[ -n "$c" && -x "$c" && -x "${c:h}/ffprobe" ]] && { print -r -- "$c"; return 0 }
  done
  return 1
}
if ! FFMPEG=$(find_ff); then
  BREW=$(command -v brew || print -r -- /opt/homebrew/bin/brew(N) /usr/local/bin/brew(N) | cut -d' ' -f1)
  [[ -x "$BREW" ]] || die "Нужен ffmpeg. Проще всего через Homebrew: поставь его с https://brew.sh и запусти установку ещё раз"
  ask "ffmpeg не найден. Поставить через Homebrew (brew install ffmpeg)?" || die "Без ffmpeg не получится: brew install ffmpeg, потом установка ещё раз"
  "$BREW" install ffmpeg || die "brew install ffmpeg не прошёл"
  FFMPEG=$(find_ff) || die "ffmpeg так и не нашёлся"
fi
FFPROBE="${FFMPEG:h}/ffprobe"
enc=$("$FFMPEG" -hide_banner -encoders 2>/dev/null)
if [[ "$enc" == *h264_videotoolbox* ]]; then   # видеоблок Mac; постоянное качество -q:v есть только на Apple Silicon
  [[ "$CPUTYPE" == arm64 ]] && VIDEO=(-c:v h264_videotoolbox -q:v 55) || VIDEO=(-c:v h264_videotoolbox -b:v 2M)
elif [[ "$enc" == *libx264* ]]; then VIDEO=(-c:v libx264 -preset veryfast -crf 23)
else die "В $FFMPEG нет кодировщика H.264"; fi
[[ "$enc" == *aac_at* ]] && AUDIO=(-c:a aac_at -b:a 128k) || AUDIO=(-c:a aac -b:a 128k)

# папка записей: куда Телемост писал в последний раз (по его журналу), иначе стандартная «Документы/Телемост»
p=
for lf in "$TL"/*.log(om); do p=$(grep -a -o "record started: .*\.webm" "$lf" | tail -1); [[ -n "$p" ]] && break; done
DIR=${${p#record started: }:h}
if [[ -z "$p" || ! -d "$DIR" ]]; then
  DIR="$HOME/Documents/Телемост"
  [[ -d "$HOME/Documents/Telemost" && ! -d "$DIR" ]] && DIR="$HOME/Documents/Telemost"
  mkdir -p "$DIR" || die "Не смог создать $DIR"
fi
DIR=${DIR:A}

# программа-запускалка: собираем при первой установке и когда поменялся runner.swift
sum=$(shasum -a 256 "$R/runner.swift" | cut -d' ' -f1)
if [[ ! -x "$EXE" || "$rebuild" == 1 || "$(cat "$ST/runner.sha256" 2>/dev/null)" != "$sum" ]]; then
  xcrun --find swiftc >/dev/null 2>&1 || die "Нужны инструменты разработчика Apple: xcode-select --install, потом установка ещё раз"
  mkdir -p "$APP/Contents/MacOS" "$ST"
  xcrun swiftc -O -o "$EXE" "$R/runner.swift" || die "Не собралась программа"
  cat > "$APP/Contents/Info.plist" <<PLIST
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
  codesign --force --sign - --identifier "$L" "$APP" 2>/dev/null || die "Не подписалась программа"
  print -r -- "$sum" > "$ST/runner.sha256"
  built=1
fi

mkdir -p "$ST" "${LOG:h}"
cp "$R/convert.sh" "$ST/convert.sh"
{
  print -r -- "DIR=${(q)DIR}"
  print -r -- "FFMPEG=${(q)FFMPEG}"
  print -r -- "FFPROBE=${(q)FFPROBE}"
  print -r -- "VIDEO=(${(q)VIDEO[@]})"
  print -r -- "AUDIO=(${(q)AUDIO[@]})"
  print -r -- "KEEP_WEBM=$keep"
} > "$ST/config"
touch "$ST/done.txt"

# старые записи: перекодировать или отметить готовыми. Запись, которую Телемост пишет прямо сейчас, не трогаем
old=(); bytes=0
for f in "$DIR"/*.webm; do
  [[ -e "${f:r}.mp4" ]] && continue
  zstat -H s -- "$f" || continue
  grep -qxF -- "$s[inode] $s[size]" "$ST/done.txt" && continue
  lsof -a -c Yandex.Telemost -t -- "$f" >/dev/null 2>&1 && continue
  old+=("$f"); (( bytes += ${s[size]} ))
done
if (( $#old )); then
  what="mp4 появится рядом"; [[ "$keep" == 1 ]] || what+=", webm уйдёт в корзину"
  if (( all )) || ask "В папке старых записей: $#old ($(( bytes / 1048576 )) МБ). Перекодировать и их ($what)?"; then
    say "→ старые записи перекодирую в фоне, по одной"
  else
    for f in $old; do zstat -H s -- "$f" && print -r -- "$s[inode] $s[size]" >> "$ST/done.txt"; done
    say "→ старые записи не трогаю, только новые"
  fi
fi

launchctl bootout "gui/$UID" "$PL" 2>/dev/null
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
say "  webm после перекодирования: $([[ "$keep" == 1 ]] && print остаётся рядом || print в корзину)"
say "  журнал: ~/Library/Logs/telemost-mp4.log"
[[ -n "$built" ]] && say "Если macOS спросит, пустить ли «Telemost MP4» к папке с записями, - разреши, иначе он их не увидит."
