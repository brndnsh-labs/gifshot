import AppKit
import UniformTypeIdentifiers

/// Where finished GIFs go, and what happens to them there.
enum Output {
    static var folder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// Scratch file a recording is encoded into before it's finished.
    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "gifshot-\(UUID().uuidString).gif")
    }

    /// Moves a finished GIF into the output folder and puts it on the clipboard.
    static func deliver(_ temporary: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let destination = folder.appending(path: "gifshot-\(formatter.string(from: Date())).gif")
        try FileManager.default.moveItem(at: temporary, to: destination)
        copyToClipboard(destination)
        lastGIF = destination
        return destination
    }

    /// File URL (Finder, Slack upload) plus the GIF bytes (apps that paste images). The bytes are
    /// read from disk only when an app asks for them, so a large GIF isn't held in memory.
    static func copyToClipboard(_ url: URL, pasteboard: NSPasteboard = .general) {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        let provider = FileDataProvider(url: url)
        item.setDataProvider(provider, forTypes: [NSPasteboard.PasteboardType(UTType.gif.identifier)])
        clipboardProvider = provider  // kept alive while it's on the clipboard
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    private static var clipboardProvider: FileDataProvider?

    static var lastGIF: URL? {
        get {
            guard let url = UserDefaults.standard.url(forKey: "lastGIF"),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        set { UserDefaults.standard.set(newValue, forKey: "lastGIF") }
    }

    static func openLast() {
        if let url = lastGIF { NSWorkspace.shared.open(url) }
    }

    static func revealFolder() {
        if let url = lastGIF {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }
}

private nonisolated final class FileDataProvider: NSObject, NSPasteboardItemDataProvider {
    let url: URL
    init(url: URL) { self.url = url }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        if let data = try? Data(contentsOf: url) { item.setData(data, forType: type) }
    }
}
