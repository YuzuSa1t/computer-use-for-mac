import Foundation

/// Version metadata.
enum CUACore {
    static let version = "0.1.0"
    static let protocolVersion = "1"
    static let socketPath = NSString(string: "~/.opencua/helper.sock").expandingTildeInPath
    static let lockPath = NSString(string: "~/.opencua/helper.lock").expandingTildeInPath
    static let configPath = NSString(string: "~/.opencua/config.json").expandingTildeInPath
    static var helperBundleID = "com.opencua.helper"
}

func log(_ tag: String, _ msg: String) {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    FileHandle.standardError.write(Data("[\(df.string(from: Date()))] [\(tag)] \(msg)\n".utf8))
}

/// Simple JSON value helper over JSONSerialization.
enum JSON {
    static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func parse(_ s: String) -> [String: Any]? {
        parse(Data(s.utf8))
    }
    static func encode(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
    static func encodeLine(_ obj: Any) -> Data {
        var d = encode(obj)
        d.append(0x0A)
        return d
    }
}

func runOnMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.sync(execute: block) }
}

extension Dictionary {
    subscript(key: String) -> Any? where Key == String {
        get { self[key] }
    }
}
