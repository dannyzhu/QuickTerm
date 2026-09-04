import AppKit

/// 浏览器 pane（占位：Phase C 实现 WKWebView 承载、工具条、存档）
final class BrowserPaneView: PaneView {
    override class var kind: PaneKind { .browser }

    static func decode(from decoder: Decoder) throws -> BrowserPaneView {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "browser pane restore not implemented yet"))
    }
}
