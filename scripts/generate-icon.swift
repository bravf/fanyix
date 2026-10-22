import AppKit

@main
enum GenerateIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "GenerateIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "需要输出 iconset 目录"])
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_" + String(size) + "x" + String(size) + (scale == 2 ? "@2x" : "") + ".png"
                guard let data = FanyiXIcon.bitmap(pixels: size * scale, appIcon: true).representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "GenerateIcon", code: 2)
                }
                try data.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
