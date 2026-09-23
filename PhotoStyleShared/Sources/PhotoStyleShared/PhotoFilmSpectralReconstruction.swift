import CoreImage
import Foundation
import simd

/// Bounded LHTSS reference samples, interpolated in chromaticity rather than
/// quantizing image intensity. Exposure is factored out and remains linear/HDR.
/// A reconstructed spectrum is a smooth metamer, not recovered physical truth.
enum PhotoFilmSpectralReconstruction {
    static let dimension = PhotoFilmSpectralTable.dimension
    static let extent = CGRect(x: 0, y: 0, width: dimension, height: dimension * 3)
    static let planes: [CIImage] = (0..<5).map { plane in
        let count = dimension * dimension * 3 * 16
        return CIImage(bitmapData: PhotoFilmSpectralTable.data.subdata(in: plane*count..<(plane+1)*count),
            bytesPerRow: dimension * 16, size: extent.size, format: .RGBAf, colorSpace: nil)
            .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: extent.height))
    }
    private static let values: [Float] = PhotoFilmSpectralTable.data.withUnsafeBytes { raw in
        (0..<(raw.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
    }
    static func spectrum(_ rgb: SIMD3<Double>) -> [Double] {
        let rgb = simd_max(rgb, .zero)
        let maximum = max(rgb.x, max(rgb.y, rgb.z))
        guard maximum > 0, maximum.isFinite else { return Array(repeating: 0, count: 13) }
        let face = rgb.x >= rgb.y && rgb.x >= rgb.z ? 0 : (rgb.y >= rgb.z ? 1 : 2)
        let u = rgb[(face + 1) % 3] / maximum * Double(dimension - 1)
        let v = rgb[(face + 2) % 3] / maximum * Double(dimension - 1)
        let x = min(dimension-2, Int(u)), y = min(dimension-2, Int(v))
        let fx = u-Double(x), fy = v-Double(y)
        return (0..<13).map { band in
            func at(_ dx: Int, _ dy: Int) -> Double {
                let i = ((band/3 * 3*dimension + face*dimension+y+dy)*dimension+x+dx)*4 + band%3
                return Double(values[i])
            }
            return ((at(0,0)*(1-fx)+at(1,0)*fx)*(1-fy)+(at(0,1)*(1-fx)+at(1,1)*fx)*fy)*maximum
        }
    }
}
