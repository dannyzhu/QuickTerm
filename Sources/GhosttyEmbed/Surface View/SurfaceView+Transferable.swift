#if canImport(AppKit)
import AppKit
#endif
import CoreTransferable
import UniformTypeIdentifiers

/// Conformance to `Transferable` enables drag-and-drop.
extension PaneView: Transferable {   // QuickTerm: every pane type is draggable
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .quickTermPaneId) { surface in
            withUnsafeBytes(of: surface.id.uuid) { Data($0) }
        } importing: { data in
            guard data.count == 16 else {
                throw TransferError.invalidData
            }

            let uuid = data.withUnsafeBytes {
                $0.load(as: UUID.self)
            }

            guard let imported = await Self.find(uuid: uuid) else {
                throw TransferError.invalidData
            }

            return imported
        }
    }

    enum TransferError: Error {
        case invalidData
    }

    @MainActor
    static func find(uuid: UUID) -> Self? {
        #if canImport(AppKit)
        guard let del = NSApp.delegate as? Ghostty.Delegate else { return nil }
        return del.ghosttySurface(id: uuid) as? Self
        #elseif canImport(UIKit)
        // We should be able to use UIApplication here.
        return nil
        #else
        return nil
        #endif
    }
}

extension UTType {
    /// A format that encodes the bare UUID only for the pane. This can be used if you have a way
    /// to look up a pane by ID.
    ///
    /// QuickTerm: its own identifier, declared in the app's Info.plist (`UTExportedTypeDeclarations`
    /// in project.yml). The port kept Ghostty's `com.mitchellh.ghosttySurfaceId` without declaring
    /// it, and that only worked on a Mac where Ghostty.app is installed and declares the type for
    /// Launch Services; on a Mac without it the type was unknown, every drop target refused the
    /// drag, and Cmd+drag of a tiled pane did nothing (Mac mini, 2026-09-27).
    static let quickTermPaneId = UTType(exportedAs: "dev.danny.quickterm.pane")
}

#if canImport(AppKit)
extension NSPasteboard.PasteboardType {
    /// Pasteboard type for dragging pane IDs.
    static let quickTermPaneId = NSPasteboard.PasteboardType(UTType.quickTermPaneId.identifier)
}
#endif
