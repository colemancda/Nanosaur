// TGAFile.swift - Parser for the .tga image files under Data/Images and
// Data/Sprites, replacing the FSRead-based loader in src/System/TGA.c with a
// pure, tested, standalone decoder - same approach as Sources/ResourceFile.
//
// Supports the TGA variants the game actually ships: uncompressed and
// RLE-compressed, in color-mapped, true-color (BGR/BGRA), and grayscale
// flavors (image types 1/2/3/9/10/11), at 8/16/24/32 bits per pixel. The
// decoded result is always normalized to 32-bit ARGB with a top-left origin,
// matching src/System/TGA.c's `forceARGB` path (the form the game uploads as
// textures).
//
// The TGA header is little-endian (18 bytes):
//   idFieldLength(1) colorMapType(1) imageType(1)
//   paletteOriginLo(1) paletteOriginHi(1)
//   paletteColorCountLo(1) paletteColorCountHi(1) paletteBitsPerColor(1)
//   xOrigin(2) yOrigin(2) width(2) height(2) bpp(1) imageDescriptor(1)
#if canImport(BinaryParsing)
import BinaryParsing
#endif

public enum TGAParsingError: Error, Sendable, Equatable {
    case unsupportedImageType(UInt8)
    case unsupportedColorDepth(UInt8)
    case malformedRLE
    case truncatedPixelData
}

// See ResourceFile.swift's resourceFileThrow: ThrownParsingError aliases the
// concrete ParsingError type (no user-error payload) under Embedded Swift, so
// TGAParsingError's specific cases can't be carried through there - they
// downgrade to a plain `.invalidValue` status.
#if $Embedded
private func tgaThrow(_ error: TGAParsingError) -> ParsingError {
    ParsingError(statusOnly: .invalidValue)
}
#else
private func tgaThrow(_ error: TGAParsingError) -> TGAParsingError {
    error
}
#endif

/// A decoded TGA image, normalized to 32-bit ARGB with a top-left origin.
public struct TGAImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Row-major, top-left origin. Four bytes per pixel in A, R, G, B order
    /// (`pixelsARGB[i*4+0]` is alpha), matching src/System/TGA.c's
    /// TGA_IMAGETYPE_CONVERTED_ARGB layout.
    public var pixelsARGB: [UInt8]
}

extension TGAImage: ExpressibleByParsing {
    public init(parsing input: inout ParserSpan) throws(ThrownParsingError) {
        let idFieldLength = try Int(UInt8(parsing: &input))
        _ = try UInt8(parsing: &input) // colorMapType
        let imageType = try UInt8(parsing: &input)
        _ = try UInt8(parsing: &input) // paletteOriginLo
        _ = try UInt8(parsing: &input) // paletteOriginHi
        let paletteColorCount = try Int(UInt16(parsingLittleEndian: &input))
        let paletteBitsPerColor = try Int(UInt8(parsing: &input))
        _ = try UInt16(parsingLittleEndian: &input) // xOrigin
        _ = try UInt16(parsingLittleEndian: &input) // yOrigin
        let width = try Int(UInt16(parsingLittleEndian: &input))
        let height = try Int(UInt16(parsingLittleEndian: &input))
        let storedBPP = try Int(UInt8(parsing: &input))
        let imageDescriptor = try UInt8(parsing: &input)

        let isColorMapped = (imageType == 1 || imageType == 9)
        let compressed = (imageType & 8) != 0
        // If bit 5 of the descriptor is clear, rows are stored bottom-up.
        let needFlip = (imageDescriptor & (1 << 5)) == 0

        switch imageType {
        case 1, 2, 3, 9, 10, 11:
            break
        default:
            throw tgaThrow(.unsupportedImageType(imageType))
        }

        // Skip the optional identification field.
        if idFieldLength > 0 {
            input = try input.seeking(toRelativeOffset: idFieldLength)
        }

        // Color-mapped images store a palette of BGR triples before the pixels.
        var palette: [UInt8] = []
        if isColorMapped {
            let paletteBytes = paletteColorCount * (paletteBitsPerColor / 8)
            palette = try [UInt8](parsing: &input, byteCount: paletteBytes)
        }

        // Everything remaining is the (possibly RLE-compressed) pixel data.
        let storedBytesPerPixel = storedBPP / 8
        let pixelCount = width * height
        let pixelDataLength = pixelCount * storedBytesPerPixel
        let raw = try [UInt8](parsing: &input, byteCount: input.count)

        var pixelData: [UInt8]
        if compressed {
            pixelData = []
            pixelData.reserveCapacity(pixelDataLength)
            var i = 0
            var processed = 0
            while processed < pixelCount {
                guard i < raw.count else { throw tgaThrow(.malformedRLE) }
                let packetHeader = raw[i]
                i += 1
                let packetLength = 1 + Int(packetHeader & 0x7F)
                if (packetHeader & 0x80) != 0 { // run-length packet
                    guard i + storedBytesPerPixel <= raw.count else { throw tgaThrow(.malformedRLE) }
                    for _ in 0..<packetLength {
                        pixelData.append(contentsOf: raw[i..<i + storedBytesPerPixel])
                    }
                    i += storedBytesPerPixel
                } else { // raw packet
                    let packetBytes = packetLength * storedBytesPerPixel
                    guard i + packetBytes <= raw.count else { throw tgaThrow(.malformedRLE) }
                    pixelData.append(contentsOf: raw[i..<i + packetBytes])
                    i += packetBytes
                }
                processed += packetLength
            }
        } else {
            guard raw.count >= pixelDataLength else { throw tgaThrow(.truncatedPixelData) }
            pixelData = Array(raw[0..<pixelDataLength])
        }

        // If stored bottom-up, flip rows so the origin is top-left. This uses
        // the stored depth (index bytes for color-mapped images).
        if needFlip {
            let rowBytes = width * storedBytesPerPixel
            for row in 0..<(height / 2) {
                let top = row * rowBytes
                let bottom = (height - 1 - row) * rowBytes
                for b in 0..<rowBytes {
                    pixelData.swapAt(top + b, bottom + b)
                }
            }
        }

        // Expand color-mapped indices into BGR triples so the ARGB conversion
        // below handles them uniformly.
        var effectiveBPP = storedBPP
        if isColorMapped {
            guard storedBPP == 8, paletteBitsPerColor == 24 else {
                throw tgaThrow(.unsupportedColorDepth(UInt8(truncatingIfNeeded: storedBPP)))
            }
            var expanded = [UInt8](repeating: 0, count: pixelCount * 3)
            for p in 0..<pixelCount {
                let index = Int(pixelData[p]) * 3
                expanded[p * 3 + 0] = palette[index + 0]
                expanded[p * 3 + 1] = palette[index + 1]
                expanded[p * 3 + 2] = palette[index + 2]
            }
            pixelData = expanded
            effectiveBPP = 24
        }

        // Convert to 32-bit ARGB (A,R,G,B byte order), mirroring
        // ConvertToARGB() in src/System/TGA.c.
        var argb = [UInt8](repeating: 0, count: pixelCount * 4)
        switch effectiveBPP {
        case 32: // BGRA -> ARGB
            for p in 0..<pixelCount {
                argb[p * 4 + 0] = pixelData[p * 4 + 3]
                argb[p * 4 + 1] = pixelData[p * 4 + 2]
                argb[p * 4 + 2] = pixelData[p * 4 + 1]
                argb[p * 4 + 3] = pixelData[p * 4 + 0]
            }
        case 24: // BGR -> ARGB
            for p in 0..<pixelCount {
                argb[p * 4 + 0] = 0xFF
                argb[p * 4 + 1] = pixelData[p * 3 + 2]
                argb[p * 4 + 2] = pixelData[p * 3 + 1]
                argb[p * 4 + 3] = pixelData[p * 3 + 0]
            }
        case 16: // RGB555 -> ARGB
            for p in 0..<pixelCount {
                let lo = UInt16(pixelData[p * 2 + 0])
                let hi = UInt16(pixelData[p * 2 + 1])
                let rgb = lo | (hi << 8)
                argb[p * 4 + 0] = 0xFF
                argb[p * 4 + 1] = UInt8(((Int((rgb >> 10) & 0x1F)) * 255) / 31)
                argb[p * 4 + 2] = UInt8(((Int((rgb >> 5) & 0x1F)) * 255) / 31)
                argb[p * 4 + 3] = UInt8(((Int((rgb >> 0) & 0x1F)) * 255) / 31)
            }
        case 8: // grayscale -> ARGB
            for p in 0..<pixelCount {
                let gray = pixelData[p]
                argb[p * 4 + 0] = 0xFF
                argb[p * 4 + 1] = gray
                argb[p * 4 + 2] = gray
                argb[p * 4 + 3] = gray
            }
        default:
            throw tgaThrow(.unsupportedColorDepth(UInt8(truncatingIfNeeded: effectiveBPP)))
        }

        self.width = width
        self.height = height
        self.pixelsARGB = argb
    }
}
