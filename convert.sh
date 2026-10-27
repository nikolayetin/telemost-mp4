#!/bin/zsh
# Telemost MP4: записи звонков Яндекс Телемоста из webm в mp4.
# Запускает программа «Telemost MP4» (runner.swift), её будит launchd-агент local.telemost-mp4 (ставит install.sh),
# когда в папке записей что-то появилось или переименовалось, и один раз при входе в систему.
# Между звонками не работает ничего: ни процесса, ни опроса.
# Телемост создаёт файл записи в момент «Записать на компьютер» сразу под окончательным именем и дописывает его весь
# звонок. Сторож раз в 20 с смотрит размер встроенными zstat и zselect, без новых процессов. Размер встал и Телемост
# файл не держит - звонок кончился: рядом mp4, webm в корзину (если при установке не выбрано --keep-webm).
zmodload -F zsh/stat b:zstat
zmodload zsh/zselect
setopt null_glob
ST="$HOME/Library/Application Support/telemost-mp4"
LOG="$HOME/Library/Logs/telemost-mp4.log"
DONE="$ST/done.txt"   # «номер файла и размер» обработанных: переименовал webm или убрал mp4 - второй раз не делаем
source "$ST/config"   # DIR, FFMPEG, FFPROBE, VIDEO, AUDIO, KEEP_WEBM - пишет install.sh
touch "$DONE"

log() { print -r -- "$(date '+%d.%m %H:%M:%S') $*" >> "$LOG" }
note() { osascript -e 'on run a' -e 'display notification (item 1 of a) with title "Telemost MP4"' -e 'end run' "$1" >/dev/null 2>&1 }
key() { local -A st; zstat -H st -- "$1" 2>/dev/null || return 1; K="$st[inode] $st[size]" }

# Ждёт конца записи. Размер не менялся 20 с - спрашиваем lsof, держит ли файл сам Телемост (пауза записи);
# чужие программы, которые его открыли, не мешают. Файл пропал (переименовали, удалили) - 1.
wait_done() {
  local prev=
  while true; do
    key "$1" || return 1
    [[ "$K" == "$prev" ]] && ! lsof -a -c Yandex.Telemost -t -- "$1" >/dev/null 2>&1 && return 0
    prev=$K; zselect -t 2000
  done
}

# Длина файла в секундах. Заголовку webm верить нельзя (у записи из браузера на 15:47 стояло 14:28), поэтому у webm -
# время последнего пакета, у готового mp4 - длительность из заголовка.
last_packet() { "$FFPROBE" -v error -show_entries packet=pts_time -of csv=p=0 "$1" | awk -F, '$1>m{m=$1} END{print m+0}' }
duration() { "$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$1" | awk '{print $1+0}' }

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
    key "$f" || continue
    grep -qxF -- "$K" "$DONE" && continue
    out="${f:r}.mp4"
    if [[ -e "$out" ]]; then print -r -- "$K" >> "$DONE"; continue; fi
    again=1
    log "${f:t}: жду конца записи"
    if ! wait_done "$f"; then log "${f:t} переименован или удалён - смотрю папку заново"; continue; fi
    id=$K; tmp="$DIR/.${out:t}.part"; t0=$SECONDS
    if "$FFMPEG" -hide_banner -loglevel error -nostdin -y -i "$f" "${VIDEO[@]}" -fps_mode passthrough "${AUDIO[@]}" \
         -movflags +faststart -f mp4 "$tmp" 2>> "$LOG"; then
      # пока перекодировали, webm могли переименовать - mp4 называем по нынешнему имени
      src=$f
      for g in "$DIR"/*.webm; do key "$g" && [[ "$K" == "$id" ]] && { src=$g; break }; done
      [[ -e "${src:r}.mp4" ]] || out="${src:r}.mp4"
      mv "$tmp" "$out" && touch -r "$src" "$out"
      msg="готово ${out:t}: $(( $(stat -f %z "$out") / 1048576 )) МБ за $(( SECONDS - t0 )) с"
      if [[ "$KEEP_WEBM" != 1 ]]; then   # webm в корзину - только если mp4 не короче записи
        a=$(last_packet "$src"); b=$(duration "$out")
        if (( b <= 0 || b + 2 < a )); then msg+=", mp4 короче записи ($b из $a с) - webm оставил"
        elif [[ -n "$TELEMOST_MP4_APP" ]] && "$TELEMOST_MP4_APP" --trash "$src" 2>> "$LOG"; then msg+=", webm в корзине"
        else msg+=", webm не убрал в корзину"; fi
      fi
      log "$msg"
      note "Запись готова: ${out:t}"
    else
      rm -f "$tmp"
      log "ОШИБКА ${f:t} - не перекодировал, webm на месте; ещё раз: убрать строку «$id» из $DONE и тронуть папку"
      note "Не получилось перекодировать ${f:t}"
    fi
    print -r -- "$id" >> "$DONE"
  done
done
