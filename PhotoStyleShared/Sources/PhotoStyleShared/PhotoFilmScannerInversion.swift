import Foundation
import simd

extension PhotoFilmScanner {
    /// Invert the existing Beer–Lambert scanner model in log-transmission space.
    /// Independently derived bounded Newton solve, not copied from a third-party
    /// implementation. The forward model remains our synthetic 13-band model.
    /// Research and limitations: docs/research/SCANNER_INVERSION_2026-09-25.md.
    static func unmix(_ optical: SIMD3<Double>, profile p: PhotoFilmSpectralProfile,
                      light: [Double], calibration cal: Calibration) -> SIMD3<Double> {
        let middle = p.density(0)
        var estimate = simd_clamp(SIMD3<Double>(repeating: middle) + cal.inverse * (optical - cal.middle),
                                  .zero, .init(repeating: p.maxDensity))
        var best = estimate
        var bestError = Double.infinity
        for iteration in 0...4 {
            var signal = SIMD3<Double>.zero
            var j0 = signal, j1 = signal, j2 = signal
            for k in 0..<13 {
                let dye = p.negativeDyes[k]
                let weight = PhotoFilmSpectralProfile.scanner[k] * light[k]
                    * pow(10, -p.baseDensity[k] - simd_dot(dye, estimate))
                signal += weight
                j0 += weight * dye.x; j1 += weight * dye.y; j2 += weight * dye.z
            }
            signal = simd_max(signal, .init(repeating: 1e-12))
            let residual = SIMD3<Double>((0..<3).map { -log10(signal[$0] / cal.base[$0]) }) - optical
            let error = simd_length_squared(residual)
            if error < bestError { best = estimate; bestError = error }
            if iteration == 4 || error < 1e-12 { break }
            let jacobian = simd_double3x3(columns: (j0 / signal, j1 / signal, j2 / signal))
            let determinant = simd_determinant(jacobian)
            guard determinant.isFinite, abs(determinant) > 1e-8 else { break }
            var step = jacobian.inverse * residual
            let largest = max(abs(step.x), max(abs(step.y), abs(step.z)))
            guard largest.isFinite else { break }
            step *= min(1, 0.75 / max(largest, 1e-12))
            estimate = simd_clamp(estimate - step, .zero, .init(repeating: p.maxDensity))
        }
        return best - SIMD3<Double>(repeating: middle)
    }

    /// Requires the spectral tables defined by PhotoFilmSpectralProcessor.
    static let inversionMetal = """
    float3 spUnmix(float3 optical, int stock, int light, float3 base,
                   float3 middle, float3 row0, float3 row1, float3 row2) {
        float center=spMiddleDensity[stock];
        float3 delta=optical-middle;
        float3 estimate=clamp(center+float3(dot(row0,delta),dot(row1,delta),dot(row2,delta)),
                              float3(0),float3(spCurve[stock].w));
        float3 best=estimate;
        float bestError=1e30f;
        for(int iteration=0;iteration<=4;++iteration) {
            float3 signal=float3(0), j0=float3(0), j1=float3(0), j2=float3(0);
            for(int k=0;k<13;++k) {
                int index=stock*13+k;
                float3 dye=spNegativeDyes[index];
                float3 weight=spScanner[k]*spLights[light+k]
                    *exp(-2.302585093f*(spBase[index]+dot(dye,estimate)));
                signal+=weight;
                j0+=weight*dye.x; j1+=weight*dye.y; j2+=weight*dye.z;
            }
            signal=max(signal,float3(1e-12f));
            float3 residual=-log10(signal/base)-optical;
            float error=dot(residual,residual);
            if(error<bestError) { best=estimate; bestError=error; }
            if(iteration==4 || error<1e-12f) break;
            j0/=signal; j1/=signal; j2/=signal;
            float3 co0=cross(j1,j2), co1=cross(j2,j0), co2=cross(j0,j1);
            float determinant=dot(j0,co0);
            if(!isfinite(determinant) || abs(determinant)<=1e-8f) break;
            float3 step=float3(dot(co0,residual),dot(co1,residual),dot(co2,residual))/determinant;
            float largest=max(abs(step.x),max(abs(step.y),abs(step.z)));
            if(!isfinite(largest)) break;
            step*=min(1.0f,0.75f/max(largest,1e-12f));
            estimate=clamp(estimate-step,float3(0),float3(spCurve[stock].w));
        }
        return best-center;
    }
    """
}
