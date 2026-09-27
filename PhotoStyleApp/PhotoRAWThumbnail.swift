import Foundation
import CoreGraphics
import ImageIO

/// Reads only TIFF directories and a camera JPEG. Unsupported RAW layouts use ImageIO.
/// Never follows MakerNote offsets or interprets sensor strips as display pixels.
enum PhotoRAWThumbnail {
    static func make(from url: URL, maxPixel: Int = 256) -> CGImage? {
        guard ["nef", "nrw", "arw", "sr2", "srf", "dng", "cr2", "cr3", "raf", "rw2", "rwl", "orf", "pef", "srw", "3fr", "fff", "erf", "mef"].contains(url.pathExtension.lowercased()),
              let reader = try? Reader(url) else { return nil }
        return make(reader: reader, maxPixel: maxPixel)
    }

    /// Decode the coordinated snapshot, never reopen the source URL during recovery.
    static func make(from data: Data, maxPixel: Int) -> CGImage? {
        guard let reader = try? Reader(data: data) else { return nil }
        return make(reader: reader, maxPixel: maxPixel)
    }

    private static func make(reader: Reader, maxPixel: Int) -> CGImage? {
        guard maxPixel > 0, let preview = try? reader.preview(maxPixel: maxPixel),
              let data = try? reader.read(preview.offset, preview.length),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let jpegProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = preview.orientation ?? (jpegProperties?[kCGImagePropertyOrientation] as? Int) ?? 1
        return oriented(image, orientation: orientation)
    }

    private struct Preview {
        let offset: Int
        let length: Int
        let width: Int
        let height: Int
        let orientation: Int?
    }

    private final class Reader {
        let file: FileHandle?
        let snapshot: Data?
        let size: Int
        let little: Bool
        let firstIFD: Int
        enum Container { case tiff, raf, cr3 }
        let container: Container
        enum Invalid: Error { case data }

        convenience init(_ url: URL) throws {
            let file = try FileHandle(forReadingFrom: url)
            do {
                let length = try file.seekToEnd()
                guard length <= UInt64(Int.max), length >= 16 else { throw Invalid.data }
                try file.seek(toOffset: 0)
                guard let header = try file.read(upToCount: 16), header.count == 16 else { throw Invalid.data }
                try self.init(header: header, size: Int(length), file: file, snapshot: nil)
            } catch {
                try? file.close()
                throw error
            }
        }
        convenience init(data: Data) throws {
            guard data.count >= 16 else { throw Invalid.data }
            try self.init(header: Data(data.prefix(16)), size: data.count, file: nil, snapshot: data)
        }
        private init(header: Data, size: Int, file: FileHandle?, snapshot: Data?) throws {
            self.file = file
            self.snapshot = snapshot
            self.size = size
            if header.starts(with: Data("FUJIFILMCCD-RAW ".utf8)) {
                container = .raf; little = false; firstIFD = 0; return
            }
            if header.subdata(in: 4..<8) == Data("ftyp".utf8),
               header.subdata(in: 8..<12) == Data("crx ".utf8) {
                container = .cr3; little = false; firstIFD = 0; return
            }
            guard header.prefix(2) == Data([0x49, 0x49]) || header.prefix(2) == Data([0x4d, 0x4d]) else { throw Invalid.data }
            container = .tiff
            little = header[0] == 0x49
            func value(_ start: Int, _ count: Int) -> Int {
                (0..<count).reduce(0) { $0 | (Int(header[start + $1]) << ((header[0] == 0x49 ? $1 : count - 1 - $1) * 8)) }
            }
            guard [42, 85, 0x4f52, 0x5352].contains(value(2, 2)) else { throw Invalid.data } // TIFF, Panasonic, Olympus. BigTIFF falls back.
            firstIFD = value(4, 4)
        }
        deinit { try? file?.close() }

        func read(_ offset: Int, _ count: Int) throws -> Data {
            guard offset >= 0, count > 0, count <= 16 * 1024 * 1024,
                  offset <= size, count <= size - offset else { throw Invalid.data }
            if let snapshot { return snapshot.subdata(in: offset..<(offset + count)) }
            guard let file else { throw Invalid.data }
            try file.seek(toOffset: UInt64(offset))
            guard let data = try file.read(upToCount: count), data.count == count else { throw Invalid.data }
            return data
        }
        func number(_ data: Data, _ start: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | (Int(data[start + $1]) << ((little ? $1 : count - 1 - $1) * 8)) }
        }
        func preview(maxPixel: Int) throws -> Preview? {
            if container == .raf {
                let header = try read(84, 8)
                return try candidate(number(header, 0, 4), number(header, 4, 4), orientation: nil)
            }
            if container == .cr3 { return try canonPreview(maxPixel: maxPixel) }
            var pending = [firstIFD], seen = Set<Int>(), candidates: [Preview] = []
            var orientation: Int?
            while !pending.isEmpty, seen.count < 32 {
                let offset = pending.removeFirst()
                guard offset > 0, seen.insert(offset).inserted else { continue }
                let count = number(try read(offset, 2), 0, 2)
                guard count <= 512 else { throw Invalid.data }
                let table = try read(offset + 2, count * 12 + 4)
                var tags: [Int: Int] = [:]
                for index in 0..<count {
                    let p = index * 12, tag = number(table, p, 2), type = number(table, p + 2, 2)
                    let n = number(table, p + 4, 4)
                    if n == 1, type == 3 || type == 4 {
                        tags[tag] = number(table, p + 8, type == 3 ? 2 : 4)
                    }
                    // Panasonic stores a complete EXIF JPEG as UNDEFINED tag 0x2e.
                    if tag == 46, type == 7, n > 4,
                       let preview = try candidate(number(table, p + 8, 4), n, orientation: orientation) {
                        candidates.append(preview)
                    }
                    if tag == 330, type == 4, n > 0, n <= 32 {
                        if n == 1 { pending.append(number(table, p + 8, 4)) }
                        else {
                            let offsets = try read(number(table, p + 8, 4), n * 4)
                            pending += (0..<n).map { number(offsets, $0 * 4, 4) }
                        }
                    }
                }
                if offset == firstIFD, let value = tags[274], (1...8).contains(value) { orientation = value }
                let next = number(table, count * 12, 4)
                if next > 0 { pending.append(next) }
                // JPEGInterchangeFormat, or one explicitly JPEG-compressed strip.
                let displayStrip = [6, 7].contains(tags[259] ?? 0) && [2, 6].contains(tags[262] ?? 0)
                let jpegOffset = tags[513] ?? (displayStrip ? tags[273] : nil)
                let jpegLength = tags[514] ?? (displayStrip ? tags[279] : nil)
                if let start = jpegOffset, let length = jpegLength,
                   let preview = try candidate(start, length, orientation: orientation) { candidates.append(preview) }
            }
            return preferred(candidates, maxPixel: maxPixel)
        }
        private func candidate(_ start: Int, _ length: Int, orientation: Int?) throws -> Preview? {
            guard length > 4, length <= 16 * 1024 * 1024, start >= 0, start <= size, length <= size - start,
                  let dimensions = try jpegDimensions(start, length) else { return nil }
            return .init(offset: start, length: length, width: dimensions.0, height: dimensions.1, orientation: orientation)
        }
        private func preferred(_ candidates: [Preview], maxPixel: Int) -> Preview? {
            // Avoid an undersized EXIF thumbnail when a larger camera preview is available.
            return candidates.sorted {
                let a = max($0.width, $0.height), b = max($1.width, $1.height)
                if (a >= maxPixel) != (b >= maxPixel) { return a >= maxPixel }
                return a >= maxPixel ? a < b : a > b
            }.first
        }
        /// Walk bounded ISO-BMFF boxes, skipping mdat instead of reading sensor payloads.
        private func canonPreview(maxPixel: Int) throws -> Preview? {
            let metadataUUID = Data([0x85,0xc0,0xb6,0x87,0x82,0x0f,0x11,0xe0,0x81,0x11,0xf4,0xce,0x46,0x2b,0x6a,0x48])
            let previewUUID = Data([0xea,0xf4,0x2b,0x5e,0x1c,0x98,0x4b,0x88,0xb9,0xfb,0xb7,0xdc,0x40,0x6e,0x4d,0x16])
            var ranges = [(0, size, 0)], visited = 0, candidates: [Preview] = []
            var orientation: Int?
            while let (start, end, depth) = ranges.popLast(), depth <= 8 {
                var offset = start
                while offset <= end - 8, visited < 1024 {
                    visited += 1
                    let header = try read(offset, 8)
                    var length = number(header, 0, 4), headerSize = 8
                    let type = String(data: header.subdata(in: 4..<8), encoding: .ascii) ?? ""
                    if length == 1 {
                        let extended = try read(offset + 8, 8)
                        // Bound the UInt64 before converting to Int.
                        let high = number(extended, 0, 4), low = number(extended, 4, 4)
                        guard high <= Int.max >> 32 else { throw Invalid.data }
                        length = (high << 32) | low; headerSize = 16
                    } else if length == 0 { length = end - offset }
                    guard length >= headerSize, length <= end - offset else { throw Invalid.data }
                    let payload = offset + headerSize, count = length - headerSize
                    if type == "moov" { ranges.append((payload, offset + length, depth + 1)) }
                    if type == "uuid", count >= 16 {
                        let uuid = try read(payload, 16)
                        if uuid == metadataUUID { ranges.append((payload + 16, offset + length, depth + 1)) }
                        if uuid == previewUUID, count > 48,
                           let preview = try candidate(payload + 48, count - 48, orientation: nil) { candidates.append(preview) }
                    }
                    if type == "THMB", count > 16,
                       let preview = try candidate(payload + 16, count - 16, orientation: nil) { candidates.append(preview) }
                    if type == "CMT1", count >= 8, count <= 1024 * 1024 {
                        orientation = tiffOrientation(try read(payload, count)) ?? orientation
                    }
                    offset += length
                }
            }
            guard let chosen = preferred(candidates, maxPixel: maxPixel) else { return nil }
            return .init(offset: chosen.offset, length: chosen.length, width: chosen.width,
                         height: chosen.height, orientation: orientation)
        }
        private func tiffOrientation(_ data: Data) -> Int? {
            guard data.count >= 8, data.prefix(2) == Data([73,73]) || data.prefix(2) == Data([77,77]) else { return nil }
            let le = data[0] == 73
            func value(_ p: Int, _ n: Int) -> Int {
                (0..<n).reduce(0) { $0 | (Int(data[p + $1]) << ((le ? $1 : n - 1 - $1) * 8)) }
            }
            guard value(2, 2) == 42 else { return nil }
            let start = value(4, 4)
            guard start <= data.count - 2 else { return nil }
            let count = value(start, 2)
            guard count <= 512, count <= (data.count - start - 2) / 12 else { return nil }
            for i in 0..<count {
                let p = start + 2 + i * 12
                if value(p, 2) == 274, value(p + 2, 2) == 3, value(p + 4, 4) == 1 {
                    let orientation = value(p + 8, 2)
                    return (1...8).contains(orientation) ? orientation : nil
                }
            }
            return nil
        }
        private func jpegDimensions(_ offset: Int, _ length: Int) throws -> (Int, Int)? {
            // JPEG marker lengths let us skip EXIF/ICC without reading those payloads.
            guard try read(offset, 2) == Data([0xff, 0xd8]) else { return nil }
            var p = 2
            for _ in 0..<128 {
                guard p <= length - 4 else { return nil }
                let marker = try read(offset + p, 4)
                guard marker[0] == 0xff else { return nil }
                if marker[1] == 0xff { p += 1; continue }
                let n = Int(marker[2]) * 256 + Int(marker[3])
                guard n >= 2, n <= length - p - 2 else { return nil }
                if [0xc0, 0xc1, 0xc2].contains(marker[1]), n >= 8 {
                    let sof = try read(offset + p + 4, 5)
                    let h = Int(sof[1]) * 256 + Int(sof[2]), w = Int(sof[3]) * 256 + Int(sof[4])
                    guard w > 0, h > 0, w <= 32_768, h <= 32_768 else { return nil }
                    return (w, h)
                }
                if marker[1] == 0xda || marker[1] == 0xd9 { return nil }
                p += n + 2
            }
            return nil
        }
    }

    private static func oriented(_ image: CGImage, orientation: Int) -> CGImage? {
        guard orientation != 1 else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height), swap = orientation >= 5
        guard let context = CGContext(data: nil, width: swap ? image.height : image.width,
                                      height: swap ? image.width : image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = .init(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: transform = .init(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: transform = .init(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: transform = .init(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: transform = .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: transform = .init(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        default: transform = .init(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
