#!/bin/zsh -f
# Telemost MP4: записи звонков программы Яндекс Телемоста из webm в mp4.
# Этот текст вшит в программу «Telemost MP4» (install.sh собирает её вместе с runner.swift), она запускает его через
# `zsh -f -c`, когда launchd-агент local.telemost-mp4 видит изменение в папке записей, и один раз при входе в систему.
# Между звонками не работает ничего: ни процесса, ни опроса.
# Записью считается только webm, о котором сам Телемост написал в своём журнале «record started». Файл создаётся
# в момент «Записать на компьютер» и растёт весь звонок; сторож раз в 20 с смотрит размер встроенными zstat и zselect,
# без новых процессов. Конец - строка «record ended ... error: OK duration: <мс>» в журнале Телемоста и размер, который
# больше не меняется. Тогда рядом появляется mp4, а webm уходит в корзину, если mp4 не короче записи и webm за это
# время никто не трогал (файл keep-webm в папке настроек - оставлять webm).
zmodload -F zsh/stat b:zstat && zmodload zsh/zselect && zmodload zsh/system || exit 1
setopt null_glob
DIR=$TM_DIR FFMPEG=$TM_FFMPEG FFPROBE=$TM_FFPROBE   # вшиты в программу, передаёт runner.swift
case "$TM_VIDEO" in
  vt-q) VIDEO=(-c:v h264_videotoolbox -q:v 55) ;;   # видеоблок Apple Silicon, постоянное качество
  vt-b) VIDEO=(-c:v h264_videotoolbox -b:v 2M) ;;   # видеоблок Intel Mac
  *)    VIDEO=(-c:v libx264 -preset veryfast -crf 23) ;;
esac
[[ "$TM_AUDIO" == at ]] && AUDIO=(-c:a aac_at -b:a 128k) || AUDIO=(-c:a aac -b:a 128k)
IN=(-protocol_whitelist file -f matroska)   # только локальный файл и только webm: подложный «.webm» ffmpeg не откроет
# TM_ST, TM_LOG, TM_TLOG - только для проверок в песочнице: программа запускает скрипт с чистым окружением без них
ST="${TM_ST:-$HOME/Library/Application Support/telemost-mp4}"
LOG="${TM_LOG:-$HOME/Library/Logs/telemost-mp4.log}"
TL="${TM_TLOG:-$HOME/Library/Application Support/Yandex.Telemost/log}"   # журнал Телемоста
DONE="$ST/done.txt"   # «номер файла и размер» обработанных: переименовал webm или убрал mp4 - второй раз не делаем
SEEN="$ST/seen.txt"   # «номер файла<TAB>имя из журнала Телемоста», NO - не запись Телемоста, OLD - старая, одобрена
# Строки журнала Телемоста начинаются с времени, уровня и имени службы - имена участников встречи их не подделают
RX='^[0-9-]+\.[0-9]+ \[[^]]*\]\[I\] LocalRecordService record'
mkdir -p "$ST" "${LOG:h}"; touch "$DONE" "$SEEN" "$ST/lock"   # zsystem flock файл замка не создаёт

log() { print -r -- "$(date '+%d.%m %H:%M:%S') $*" >> "$LOG" }
note() { osascript -e 'on run a' -e 'display notification (item 1 of a) with title "Telemost MP4"' -e 'end run' "$1" >/dev/null 2>&1 }
key() { local -A st; zstat -H st -- "$1" 2>/dev/null || return 1; K="$st[inode] $st[size]" }

zsystem flock -f LOCK "$ST/lock" || exit 1   # второй экземпляр ждёт первого: два ffmpeg в один файл портят mp4
FP= TMP=
trap '[[ -n "$FP" ]] && { kill $FP 2>/dev/null; wait $FP }; [[ -n "$TMP" ]] && rm -f -- "$TMP"; log "остановлен"; exit 1' TERM INT HUP

# Телемост написал в журнале, что начал запись в файл с этим именем
started() {
  local l
  grep -a -h -E "$RX started: /" "$TL"/*.log 2>/dev/null | while IFS= read -r l; do [[ "${l##*/}" == "$1" ]] && return 0; done
  return 1
}
# Последняя строка конца записи для этого имени: «<ошибка> <мс>», например «OK 3862196»
ended() {
  local l rest p r=
  grep -a -h -E "$RX ended: /.* error: [^ ]+ duration: [0-9]+$" "$TL"/*.log 2>/dev/null | while IFS= read -r l; do
    rest=${l#*record ended: }; p=${rest% error: *}
    [[ "${p##*/}" == "$1" ]] && r="${${rest##* error: }%% *} ${rest##* duration: }"
  done
  [[ -n "$r" ]] && print -r -- "$r"
}
# Длина в секундах: у webm - время последнего пакета (заголовку браузерного webm верить нельзя), у mp4 - заголовок
last_packet() { "$FFPROBE" -v error "${IN[@]}" -show_entries packet=pts_time -of csv=p=0 "$1" | awk -F, '$1!="N/A" && $1+0>m {m=$1+0} END {print m+0}' }
duration() { "$FFPROBE" -v error -protocol_whitelist file -show_entries format=duration -of csv=p=0 "$1" | awk '{print $1+0}' }

# Ждёт конца записи: размер не менялся 20 с и Телемост написал «record ended». Телемост закрыт, а строки нет (упал),
# или размер стоит 10 минут - тоже конец, но webm тогда остаётся. Старая запись (OLD) - хватает размера. Пропал - 1.
wait_done() {
  local prev= still=0 e
  EXPECT=0 OKREC=0
  while true; do
    key "$1" || return 1
    if [[ "$K" == "$prev" ]]; then
      (( still++ ))
      [[ "$2" == OLD ]] && { OKREC=1; return 0 }
      e=$(ended "$2")
      if [[ -n "$e" ]]; then [[ "${e%% *}" == OK ]] && OKREC=1; EXPECT=$(( ${e##* } / 1000.0 )); return 0; fi
      pgrep -x Yandex.Telemost >/dev/null || return 0
      (( still >= 30 )) && return 0
    else still=0; fi
    prev=$K; zselect -t 2000
  done
}

[[ -d "$DIR" ]] || { log "нет папки записей $DIR - запусти install.sh ещё раз"; exit 1 }
# без права macOS папка выглядит пустой, поэтому спрашиваем ls: он скажет «Operation not permitted»
if err=$(ls -A "$DIR" 2>&1 >/dev/null) && [[ -z "$err" ]]; then :; else
  log "нет доступа к $DIR ($err): Системные настройки → Конфиденциальность и безопасность → Файлы и папки → Telemost MP4"
  note "Нет доступа к папке записей - разреши Telemost MP4 в настройках macOS"; exit 1
fi

again=1
while [[ -n "$again" ]]; do   # пока ждали и перекодировали, могла появиться новая запись - проходим ещё раз
  again=
  for f in "$DIR"/*.webm; do
    [[ -f "$f" ]] || continue   # только обычные файлы
    key "$f" || continue; ino=${K%% *}
    grep -qxF -- "$K" "$DONE" && continue
    out="${f:r}.mp4"
    if [[ -e "$out" ]]; then print -r -- "$K" >> "$DONE"; continue; fi
    tag=$(grep -m1 "^$ino"$'\t' "$SEEN" | cut -f2)
    if [[ -z "$tag" ]]; then   # новый файл: ждём до минуты, пока Телемост допишет журнал
      for i in {1..12}; do started "${f:t}" && { tag=${f:t}; break }; zselect -t 500; done
      [[ -n "$tag" ]] || { tag=NO; log "${f:t}: Телемост не писал этот файл - не трогаю" }
      print -r -- "$ino"$'\t'"$tag" >> "$SEEN"
    fi
    [[ "$tag" == NO ]] && continue
    again=1
    log "${f:t}: жду конца записи"
    if ! wait_done "$f" "$tag"; then log "${f:t} переименован или удалён - смотрю папку заново"; continue; fi
    id=$K; TMP="$DIR/.${out:t}.$$.part"; t0=$SECONDS
    "$FFMPEG" -hide_banner -loglevel error -nostdin -y "${IN[@]}" -i "$f" "${VIDEO[@]}" -fps_mode passthrough "${AUDIO[@]}" \
      -movflags +faststart -f mp4 "$TMP" 2>> "$LOG" &
    FP=$!; wait $FP; rc=$?; FP=
    if (( rc != 0 )); then
      rm -f -- "$TMP"; TMP=
      log "ОШИБКА ${f:t} - не перекодировал, webm на месте; ещё раз: убрать строку «$id» из $DONE и тронуть папку"
      note "Не получилось перекодировать ${f:t}"; print -r -- "$id" >> "$DONE"; continue
    fi
    # пока перекодировали, webm могли переименовать - mp4 называем по нынешнему имени; подменили или убрали - не трогаем
    src=
    for g in "$DIR"/*.webm; do key "$g" && [[ "$K" == "$id" ]] && { src=$g; break }; done
    [[ -n "$src" ]] && out="${src:r}.mp4"
    if [[ -e "$out" ]] || ! mv -n -- "$TMP" "$out" || [[ -e "$TMP" ]]; then
      rm -f -- "$TMP"; TMP=
      log "ОШИБКА ${out:t} уже есть или не переименовался - webm на месте"; print -r -- "$id" >> "$DONE"; continue
    fi
    TMP=
    [[ -n "$src" ]] && touch -r "$src" "$out"
    msg="готово ${out:t}: $(( $(stat -f %z "$out") / 1048576 )) МБ за $(( SECONDS - t0 )) с"
    if [[ -e "$ST/keep-webm" ]]; then :
    elif [[ -z "$src" ]]; then msg+=", webm подменили или убрали во время перекодирования - в корзину ничего не убираю"
    elif [[ "$OKREC" != 1 ]]; then msg+=", Телемост не подтвердил конец записи - webm оставил"
    else
      (( EXPECT > 0 )) || EXPECT=$(last_packet "$src")
      b=$(duration "$out")
      if ! key "$src" || [[ "$K" != "$id" ]]; then msg+=", webm менялся - оставил"
      elif lsof -t -- "$src" >/dev/null 2>&1; then msg+=", webm открыт в другой программе - оставил"
      elif (( EXPECT <= 0 || b <= 0 || b + 2 < EXPECT )); then msg+=", mp4 короче записи ($b из $EXPECT с) - webm оставил"
      elif "$TELEMOST_MP4_APP" --trash "$src" 2>> "$LOG"; then msg+=", webm в корзине"
      else msg+=", webm не убрал в корзину"; fi
    fi
    log "$msg"
    note "Запись готова: ${out:t}"
    print -r -- "$id" >> "$DONE"
  done
done
