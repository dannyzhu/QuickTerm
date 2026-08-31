import Foundation

/// 临时启动诊断（问题定位后移除或闲置）
enum QTCrumb {
    static let path = "/tmp/quickterm-crumb.log"
    static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
