import CoreImage
import CryptoKit
import Foundation

/// 正規化逆向位移網格；預覽與全尺寸匯出共用，不保存低解析度成品。
struct PhotoLiquifyMesh: Codable {
    let version: Int
    let referenceWidth: Int
    let referenceHeight: Int
    let spacing: Int
    let columns: Int
    let rows: Int
    let dx: [Float]
    let dy: [Float]
    private(set) var isIdentity = true
    private var map: CIImage?
    private var maxX: Float = 0
    private var maxY: Float = 0
    var identifier: String {
        SHA256.hash(data: (try? JSONEncoder().encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    enum CodingKeys: String, CodingKey { case version, referenceWidth, referenceHeight, spacing, columns, rows, dx, dy }
    enum Failure: Error { case invalidMesh, unavailableKernel }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        referenceWidth = try c.decode(Int.self, forKey: .referenceWidth)
        referenceHeight = try c.decode(Int.self, forKey: .referenceHeight)
        spacing = try c.decode(Int.self, forKey: .spacing)
        columns = try c.decode(Int.self, forKey: .columns)
        rows = try c.decode(Int.self, forKey: .rows)
        dx = try c.decode([Float].self, forKey: .dx)
        dy = try c.decode([Float].self, forKey: .dy)
        guard version == 1, (2...1024).contains(referenceWidth), (2...1024).contains(referenceHeight),
              (2...16).contains(spacing), columns == (referenceWidth-2)/spacing+2,
              rows == (referenceHeight-2)/spacing+2, dx.count == columns*rows, dy.count == dx.count else { throw Failure.invalidMesh }
        for i in dx.indices {
            let x = Double(dx[i]), y = Double(dy[i]), ix = i % columns, iy = i / columns
            let px = Double(min(ix*spacing,referenceWidth-1))/Double(referenceWidth-1)
            let py = Double(min(iy*spacing,referenceHeight-1))/Double(referenceHeight-1)
            guard x.isFinite, y.isFinite, abs(x) <= 1, abs(y) <= 1,
                  px+x >= -1e-6, px+x <= 1+1e-6, py+y >= -1e-6, py+y <= 1+1e-6 else { throw Failure.invalidMesh }
            isIdentity = isIdentity && dx[i] == 0 && dy[i] == 0
            maxX = max(maxX,abs(dx[i])); maxY = max(maxY,abs(dy[i]))
            if ix == 0 || iy == 0 || ix == columns-1 || iy == rows-1 {
                guard abs(x) <= 1e-6, abs(y) <= 1e-6 else { throw Failure.invalidMesh }
            }
        }
        // 全零網格的 Jacobian 恆為一；不建立 GPU 資料影像。
        if isIdentity { return }
        func point(_ x: Int, _ y: Int) -> SIMD2<Double> {
            let i = y*columns+x
            return SIMD2(Double(min(x*spacing,referenceWidth-1))+Double(dx[i])*Double(referenceWidth-1),
                         Double(min(y*spacing,referenceHeight-1))+Double(dy[i])*Double(referenceHeight-1))
        }
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x*b.y-a.y*b.x }
        for y in 0..<(rows-1) { for x in 0..<(columns-1) {
            let a=point(x,y), b=point(x+1,y), c=point(x,y+1), d=point(x+1,y+1)
            let hx=min((x+1)*spacing,referenceWidth-1)-x*spacing
            let hy=min((y+1)*spacing,referenceHeight-1)-y*spacing
            let threshold=0.049*Double(hx*hy)
            guard cross(b-a,c-a) >= threshold, cross(b-a,d-b) >= threshold,
                  cross(d-c,c-a) >= threshold, cross(d-c,d-b) >= threshold else { throw Failure.invalidMesh }
        } }
        // 位移驗證後不可變；直接建立 Data，讓多次 applying 共用同一份 GPU map。
        // bitmap 資料列向下，kernel 的節點取樣座標向上，所以資料列在此反轉一次。
        var data = Data(count: columns*rows*16)
        data.withUnsafeMutableBytes { raw in
            let pixels = raw.bindMemory(to: Float.self)
            for y in 0..<rows { for x in 0..<columns {
                let index=y*columns+x, offset=((rows-1-y)*columns+x)*4
                pixels[offset]=dx[index]; pixels[offset+1]=dy[index]; pixels[offset+3]=1

            } }
        }
        // 不設定色域，保留正負位移；來源像素仍維持線性預乘 RGBA。
        map = CIImage(bitmapData: data, bytesPerRow: columns*16,
                      size: CGSize(width: columns,height: rows), format: .RGBAf, colorSpace: nil)
    }
    func applying(to image: CIImage) throws -> CIImage {
        guard !isIdentity, image.extent.width >= 2, image.extent.height >= 2 else { return image }
        guard let kernel = Self.kernel, let map else { throw Failure.unavailableKernel }
        let extent=image.extent, padX=CGFloat(maxX)*(extent.width-1)+2, padY=CGFloat(maxY)*(extent.height-1)+2
        guard let result = kernel.apply(extent: extent, roiCallback: { input, area in
            input == 1 ? map.extent : area.insetBy(dx: -padX,dy: -padY).intersection(extent)
        }, arguments: [image, map, CIVector(cgRect: extent),
                       CIVector(x: CGFloat(referenceWidth-1),y: CGFloat(referenceHeight-1),z: CGFloat(spacing),w: 0),
                       CIVector(x: CGFloat(columns),y: CGFloat(rows))]) else { throw Failure.unavailableKernel }
        return result
    }
    private static let kernel: CIKernel? = try? CIKernel.kernels(withMetalString: """
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal; using namespace coreimage;
    [[ stitchable ]] float4 photoLiquify(coreimage::sampler src, coreimage::sampler grid, float4 extent, float4 layout, float2 counts, destination dest) {
        float2 size=extent.zw-1.0f;
        float2 uv=float2((dest.coord().x-extent.x-0.5f)/size.x,(extent.y+extent.w-0.5f-dest.coord().y)/size.y);
        uv=clamp(uv,float2(0.0f),float2(1.0f));
        float2 ref=uv*layout.xy;
        float2 cell=min(floor(ref/layout.z),counts-2.0f);
        float2 f=(ref-cell*layout.z)/(min((cell+1.0f)*layout.z,layout.xy)-cell*layout.z);
        float2 a=grid.sample(grid.transform(cell+float2(0.5f,0.5f))).rg;
        float2 b=grid.sample(grid.transform(cell+float2(1.5f,0.5f))).rg;
        float2 c=grid.sample(grid.transform(cell+float2(0.5f,1.5f))).rg;
        float2 d=grid.sample(grid.transform(cell+float2(1.5f,1.5f))).rg;
        float2 delta=mix(mix(a,b,f.x),mix(c,d,f.x),f.y);
        if(all(delta==float2(0.0f)))return src.sample(src.transform(dest.coord()));
        float2 warped=clamp(uv+delta,float2(0.0f),float2(1.0f));
        float2 p=float2(warped.x,1.0f-warped.y)*size;
        float2 base=floor(p), blend=p-base, high=min(base+1.0f,size);
        float2 origin=extent.xy+0.5f;
        // 明確內插四個像素中心，避免 Metal 線性 sampler 的 8-bit 權重差異。
        float4 s0=src.sample(src.transform(origin+base));
        float4 s1=src.sample(src.transform(origin+float2(high.x,base.y)));
        float4 s2=src.sample(src.transform(origin+float2(base.x,high.y)));
        float4 s3=src.sample(src.transform(origin+high));
        return mix(mix(s0,s1,blend.x),mix(s2,s3,blend.x),blend.y);
    }
    """).first
}
