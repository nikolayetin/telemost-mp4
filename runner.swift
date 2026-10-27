// Telemost MP4 - программа-запускалка (~/Applications/Telemost MP4.app). install.sh собирает её из этого файла
// и сгенерированных констант: текст convert.sh (embeddedScript), папка записей, ffmpeg и кодировщик вшиты в программу.
// Записи Телемоста лежат в «Документах», а их macOS даёт читать только программе с правом, не агенту launchd
// с /bin/zsh. Право привязано к этой сборке: подменить скрипт или папку, не сбросив его, нельзя.
// Без аргументов - запускает скрипт через `zsh -f -c` с чистым окружением и ждёт его; SIGTERM от launchd передаёт
// скрипту, тот гасит ffmpeg и убирает недописанный mp4.
// `--trash <файл>` - кладёт в корзину webm, только если он лежит прямо в папке записей и рядом уже есть непустой mp4.
import Foundation

let args = CommandLine.arguments
let dir = URL(fileURLWithPath: recordingsDir).resolvingSymlinksInPath().path

func fail(_ s: String, _ code: Int32) -> Never {
    FileHandle.standardError.write("\(s)\n".data(using: .utf8)!)
    exit(code)
}

if args.count == 3 && args[1] == "--trash" {
    let f = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath()
    let mp4 = f.deletingPathExtension().appendingPathExtension("mp4")
    let size = ((try? FileManager.default.attributesOfItem(atPath: mp4.path))?[.size] as? NSNumber)?.intValue ?? 0
    guard f.pathExtension.lowercased() == "webm", f.deletingLastPathComponent().path == dir, size > 0 else {
        fail("не убираю \(f.path): не webm из папки записей или рядом нет mp4", 2)
    }
    do {
        try FileManager.default.trashItem(at: f, resultingItemURL: nil)
        exit(0)
    } catch {
        fail("не убрал в корзину \(f.path): \(error)", 1)
    }
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/bin/zsh")
p.arguments = ["-f", "-c", embeddedScript, "telemost-mp4-worker"]
let home = NSHomeDirectory()
p.environment = [
    "HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory(),
    "TM_DIR": recordingsDir, "TM_FFMPEG": ffmpegPath, "TM_FFPROBE": ffprobePath,
    "TM_VIDEO": videoPreset, "TM_AUDIO": audioPreset,
    "TELEMOST_MP4_APP": Bundle.main.executablePath ?? args[0],
]
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue.global())
term.setEventHandler { if p.isRunning { p.terminate() } }
term.resume()
do {
    try p.run()
} catch {
    fail("не запустил скрипт: \(error)", 1)
}
p.waitUntilExit()
exit(p.terminationStatus)
