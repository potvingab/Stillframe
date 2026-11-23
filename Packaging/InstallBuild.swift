import CoreServices
import Foundation

let staged = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let files = FileManager.default
if files.fileExists(atPath: destination.path) {
    _ = try files.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
} else {
    try files.moveItem(at: staged, to: destination)
}
let status = LSRegisterURL(destination as CFURL, true)
guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
print("Built \(destination.path)")
