import Foundation
import Metal

// Noninteractive packaging check: load the bundled shader library without
// microphone access, model downloads, app activation or user data.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift scripts/check-metal.swift path/to/default.metallib")
}
guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal device unavailable") }
let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
guard !library.functionNames.isEmpty else { fatalError("Metal library has no functions") }
print("Metal library loaded: \(library.functionNames.count) functions")
