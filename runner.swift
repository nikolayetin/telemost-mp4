// Telemost MP4 - программа-запускалка (~/Applications/Telemost MP4.app), её собирает install.sh.
// Записи Телемоста лежат в «Документах», а их macOS даёт читать только программе с правом, не агенту launchd
// с /bin/zsh. Программа запускает convert.sh дочерним процессом и ждёт его: право программы действует и на него,
// и на ffmpeg. С `--trash <файл>` кладёт файл в корзину - так convert.sh убирает webm после перекодирования.
import Foundation

let args = CommandLine.arguments
if args.count == 3 && args[1] == "--trash" {
    do {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: args[2]), resultingItemURL: nil)
        exit(0)
    } catch {
        FileHandle.standardError.write("не убрал в корзину \(args[2]): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let script = NSString(string: "~/Library/Application Support/telemost-mp4/convert.sh").expandingTildeInPath
let p = Process()
p.executableURL = URL(fileURLWithPath: "/bin/zsh")
p.arguments = [script]
var env = ProcessInfo.processInfo.environment
env["TELEMOST_MP4_APP"] = Bundle.main.executablePath ?? args[0]
p.environment = env
do {
    try p.run()
} catch {
    FileHandle.standardError.write("не запустил \(script): \(error)\n".data(using: .utf8)!)
    exit(1)
}
p.waitUntilExit()
exit(p.terminationStatus)
