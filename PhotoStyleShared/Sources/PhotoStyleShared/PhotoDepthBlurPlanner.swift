import Foundation

public struct PhotoDepthBlurPlan: Equatable, Sendable {
    public let minDepth: Double
    public let maxDepth: Double
    public let focusDepth: Double
    public let backgroundDirection: Double

    public init(
        minDepth: Double,
        maxDepth: Double,
        focusDepth: Double,
        backgroundDirection: Double
    ) {
        self.minDepth = minDepth
        self.maxDepth = maxDepth
        self.focusDepth = focusDepth
        self.backgroundDirection = backgroundDirection
    }
}

public enum PhotoDepthBlurPlanner {
    public static func makePlan(
        depthPixels: [Float],
        maskPixels: [Float],
        width: Int,
        height: Int
    ) -> PhotoDepthBlurPlan? {
        guard width > 0, height > 0 else { return nil }
        let (pixelCount, overflows) = width.multipliedReportingOverflow(by: height)
        guard !overflows, pixelCount <= min(depthPixels.count, maskPixels.count) / 4 else {
            return nil
        }

        var depthValues: [Double] = []
        depthValues.reserveCapacity(pixelCount)
        for index in stride(from: 0, to: pixelCount * 4, by: 4) {
            let depth = Double(depthPixels[index])
            if depth.isFinite {
                depthValues.append(depth)
            }
        }
        guard depthValues.count >= 16 else { return nil }
        depthValues.sort()

        let minDepth = percentile(0.02, values: depthValues)
        let maxDepth = percentile(0.98, values: depthValues)
        guard maxDepth - minDepth > 0.0001 else { return nil }

        var focusSum = 0.0
        var focusWeight = 0.0
        var backgroundSum = 0.0
        var backgroundWeight = 0.0
        let centerX = Double(width - 1) * 0.5
        let centerY = Double(height - 1) * 0.5
        let centerSigma = max(Double(min(width, height)) * 0.24, 1.0)

        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let rawDepth = Double(depthPixels[index])
                guard rawDepth.isFinite else { continue }
                let depth = min(max(rawDepth, minDepth), maxDepth)
                let subjectWeight = min(max(Double(maskPixels[index]), 0), 1)

                if subjectWeight >= 0.15 {
                    let dx = (Double(x) - centerX) / centerSigma
                    let dy = (Double(y) - centerY) / centerSigma
                    let centerWeight = exp(-0.5 * (dx * dx + dy * dy))
                    let weight = subjectWeight * (0.45 + centerWeight * 0.55)
                    focusSum += depth * weight
                    focusWeight += weight
                } else if subjectWeight <= 0.05 {
                    let edgeDistance = min(min(x, width - 1 - x), min(y, height - 1 - y))
                    let edgeWeight = 1.0 / (1.0 + Double(edgeDistance) * 0.12)
                    let weight = (1.0 - subjectWeight) * edgeWeight
                    backgroundSum += depth * weight
                    backgroundWeight += weight
                }
            }
        }

        guard focusWeight > 0.01 else { return nil }
        let focusDepth = focusSum / focusWeight
        let fallbackBackgroundDepth = abs(maxDepth - focusDepth) >= abs(focusDepth - minDepth)
            ? maxDepth
            : minDepth
        let backgroundDepth = backgroundWeight > 0.01
            ? backgroundSum / backgroundWeight
            : fallbackBackgroundDepth
        return .init(
            minDepth: minDepth,
            maxDepth: maxDepth,
            focusDepth: focusDepth,
            backgroundDirection: backgroundDepth >= focusDepth ? 1 : -1
        )
    }

    private static func percentile(_ percentile: Double, values: [Double]) -> Double {
        let position = min(max(percentile, 0), 1) * Double(values.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        guard lower != upper else { return values[lower] }
        let fraction = position - Double(lower)
        return values[lower] * (1 - fraction) + values[upper] * fraction
    }
}
