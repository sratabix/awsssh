import AwssshIcon
import Foundation

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: IconExport <output.iconset>\n".utf8))
    exit(2)
}

let target = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

for variant in variants {
    guard let png = AppIcon.png(size: variant.size) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try png.write(to: target.appendingPathComponent("\(variant.name).png"))
}

print("wrote \(variants.count) icon sizes from SF Symbol \(AppIcon.symbolName)")
