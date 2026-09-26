import CoreImage
import Metal

/// Compile once in each caller's static property. Stitchable Metal lets Core
/// Image concatenate point operations without a separate full-frame texture.
/// Keep the equivalent CIKL path for devices without dynamic-library support.
enum PhotoGPUColorKernel {
    static let supportsMetal = MTLCreateSystemDefaultDevice()?.supportsDynamicLibraries == true

    static func make(_ name: String, parameters: String, body: String,
                     destination: Bool = false, helpers: String = "") -> CIColorKernel? {
        if supportsMetal, let result = metal(name, parameters: parameters, body: body,
                                              destination: destination, helpers: helpers) {
            return result
        }
        return CIColorKernel(source: "\(helpers)\nkernel vec4 \(name)(\(parameters)) { \(body) }")
    }

    static func metal(_ name: String, parameters: String, body: String,
                      destination: Bool = false, helpers: String = "") -> CIColorKernel? {
        let signature = parameters.replacingOccurrences(of: "__sample", with: "sample_t")
            + (destination ? (parameters.isEmpty ? "" : ", ") + "destination dest" : "")
        let code = """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        using namespace coreimage;
        \(helpers)
        [[ stitchable ]] float4 \(name)(\(signature)) { \(body) }
        """
        let source = code.replacingOccurrences(of: "vec2", with: "float2")
            .replacingOccurrences(of: "vec3", with: "float3")
            .replacingOccurrences(of: "vec4", with: "float4")
            .replacingOccurrences(of: "destCoord()", with: "dest.coord()")
        return (try? CIKernel.kernels(withMetalString: source))?
            .first(where: { $0.name == name }) as? CIColorKernel
    }
}
