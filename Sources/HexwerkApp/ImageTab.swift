import AppKit
import Combine
import HexwerkCore
import SwiftUI

/// Bytes as pixels.
@MainActor
final class ImageModel: ObservableObject {
    @Published var format = PixelFormat(rawValue: Settings.shared.string(forKey: "imageFormat") ?? "") ?? .gray8 {
        didSet { Settings.shared.set(format.rawValue, forKey: "imageFormat") }
    }
    @Published var width = Settings.shared.object(forKey: "imageWidth") as? Int ?? 64 {
        didSet { Settings.shared.set(width, forKey: "imageWidth") }
    }
    @Published var zoom = 2
    /// Follow the cursor, or stay at a fixed start offset.
    @Published var follow = true
    /// First byte shown. With `follow` it only moves when the cursor leaves
    /// the shown range, so clicking a pixel does not shift the picture.
    var start: UInt64 = 0
    /// Separate object, so hovering redraws only the offset label and not
    /// the whole tab (which would render the picture again).
    let hover = ImageHover()

    /// Enough rows to fill the panel, capped so a render stays cheap.
    static let maxBytes = 4 << 20
    static let rows = 512

    /// What the last picture was made from; the tab body runs on every
    /// cursor move and model change, rendering only when this changes.
    private struct Key: Equatable {
        let start: UInt64, format: PixelFormat, width: Int, revision: Int
    }
    private var cached: (key: Key, image: (NSImage, Int, Int)?)?

    func image(_ doc: HexwerkCore.Document, cursor: UInt64, revision: Int) -> (NSImage, Int, Int)? {
        let n = min(Self.maxBytes, format.bytes(forPixels: width * Self.rows))
        if follow, cursor < start || cursor >= start + UInt64(n) { start = cursor }
        let key = Key(start: start, format: format, width: width, revision: revision)
        if let cached, cached.key == key { return cached.image }
        let image = render(doc, bytes: n)
        cached = (key, image)
        return image
    }

    private func render(_ doc: HexwerkCore.Document, bytes n: Int) -> (NSImage, Int, Int)? {
        let origin = start
        let data = doc.read(origin ..< origin + UInt64(n))
        guard !data.isEmpty else { return nil }
        let r = format.rgba(data, width: width)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(r.pixels) as CFData),
            let cg = CGImage(
                width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.width * 4,
                space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return (NSImage(cgImage: cg, size: NSSize(width: r.width, height: r.height)), r.width, r.height)
    }

    /// File offset of the pixel at (x, y) in image coordinates.
    func offset(x: Int, y: Int) -> UInt64 {
        start + UInt64(format.byteOffset(ofPixel: y * width + x))
    }
}

/// File offset under the mouse in the image tab.
@MainActor
final class ImageHover: ObservableObject {
    @Published var offset: UInt64?
}

private struct HoverOffsetLabel: View {
    @ObservedObject var hover: ImageHover
    var body: some View {
        if let h = hover.offset { Text(hex(h)).monospaced().foregroundStyle(.secondary) }
    }
}

struct ImageTab: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var image: ImageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("", selection: $image.format) {
                        ForEach(PixelFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Spacer()
                    Picker("Zoom", selection: $image.zoom) {
                        ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)×").tag($0) }
                    }
                    .pickerStyle(.menu).fixedSize()
                }
                HStack {
                    Text(L("Width")).foregroundStyle(.secondary)
                    TextField("", value: $image.width, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 56).monospacedDigit()
                    Stepper("", value: $image.width, in: 1 ... 4096).labelsHidden()
                    Button("÷2") { image.width = max(1, image.width / 2) }.help(L("Halve"))
                    Button("×2") { image.width = min(4096, image.width * 2) }.help(L("Double"))
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                HStack {
                    Toggle(L("Follows the Cursor"), isOn: $image.follow).toggleStyle(.checkbox)
                    Spacer()
                    HoverOffsetLabel(hover: image.hover)
                }
                .font(.caption)
            }
            .padding(10)
            Divider()
            // Cached: renders again only for a new start, format, width or edit.
            if let (img, w, h) = image.image(model.doc, cursor: model.cursor, revision: model.revision) {
                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: CGFloat(w * image.zoom), height: CGFloat(h * image.zoom))
                        .onContinuousHover { phase in
                            if case .active(let p) = phase {
                                image.hover.offset = image.offset(x: Int(p.x) / image.zoom, y: Int(p.y) / image.zoom)
                            } else {
                                image.hover.offset = nil
                            }
                        }
                        .onTapGesture { p in
                            let off = image.offset(x: Int(p.x) / image.zoom, y: Int(p.y) / image.zoom)
                            model.jump?(min(off, model.doc.count), nil)
                        }
                        .padding(8)
                }
                .id(model.revision)
            } else {
                Text(L("No data at the cursor")).foregroundStyle(.secondary).padding(10)
                Spacer()
            }
        }
    }
}
