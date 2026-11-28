// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Cover-Art Dominant Color Extraction & Subtle Ambient Mesh Glow

import UIKit

// MARK: - Dominant Color Extractor

public enum MarcoDominantColorExtractor {
    /// Extracts a tasteful, low-saturation Apple Music / Apple TV+ ambient color from any `UIImage`
    /// by downsampling to a 24x24 RGBA8 bitmap, ignoring pure black/white, and clamping vibrancy.
    public static func extractDominantColor(from image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        let dimension = 24
        let bytesPerPixel = 4
        let bytesPerRow = dimension * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: dimension * dimension * bytesPerPixel)

        guard let context = CGContext(
            data: &pixels,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))

        let bucketCount = 18
        var bucketScore = [CGFloat](repeating: 0, count: bucketCount)
        var bucketR = [CGFloat](repeating: 0, count: bucketCount)
        var bucketG = [CGFloat](repeating: 0, count: bucketCount)
        var bucketB = [CGFloat](repeating: 0, count: bucketCount)

        var fallbackR: CGFloat = 0
        var fallbackG: CGFloat = 0
        var fallbackB: CGFloat = 0
        var fallbackWeight: CGFloat = 0

        for idx in stride(from: 0, to: pixels.count, by: 4) {
            let a = CGFloat(pixels[idx + 3]) / 255.0
            if a < 0.5 { continue }

            // Un-premultiply safely.
            let r = min(CGFloat(pixels[idx]) / (255.0 * a), 1.0)
            let g = min(CGFloat(pixels[idx + 1]) / (255.0 * a), 1.0)
            let b = min(CGFloat(pixels[idx + 2]) / (255.0 * a), 1.0)

            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            let delta = maxC - minC
            let brightness = maxC
            let saturation = maxC > 0.0001 ? (delta / maxC) : 0

            // Ignore pure black and washed-out pure white pixels.
            if brightness < 0.12 { continue }
            if brightness > 0.94 && saturation < 0.12 { continue }

            let baseWeight = 0.25 + brightness * 0.75
            fallbackR += r * baseWeight
            fallbackG += g * baseWeight
            fallbackB += b * baseWeight
            fallbackWeight += baseWeight

            // Near-achromatic pixels contribute to fallback only, not chromatic hue buckets.
            if saturation < 0.14 { continue }

            var hue: CGFloat = 0
            if delta > 0.0001 {
                if maxC == r {
                    hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6.0)
                } else if maxC == g {
                    hue = ((b - r) / delta) + 2.0
                } else {
                    hue = ((r - g) / delta) + 4.0
                }
                hue /= 6.0
                if hue < 0 { hue += 1.0 }
            }

            let bucketIndex = min(Int(hue * CGFloat(bucketCount)), bucketCount - 1)
            let midToneBonus = 1.0 - abs(brightness - 0.55)
            let weight = (0.35 + saturation * 1.15) * max(midToneBonus, 0.25)
            bucketScore[bucketIndex] += weight
            bucketR[bucketIndex] += r * weight
            bucketG[bucketIndex] += g * weight
            bucketB[bucketIndex] += b * weight
        }

        var bestBucket = -1
        var bestScore: CGFloat = 0
        for i in 0..<bucketCount where bucketScore[i] > bestScore {
            bestScore = bucketScore[i]
            bestBucket = i
        }

        let rawColor: UIColor
        if bestBucket >= 0 && bestScore > 0.001 {
            rawColor = UIColor(
                red: bucketR[bestBucket] / bestScore,
                green: bucketG[bestBucket] / bestScore,
                blue: bucketB[bestBucket] / bestScore,
                alpha: 1.0
            )
        } else if fallbackWeight > 0.001 {
            rawColor = UIColor(
                red: fallbackR / fallbackWeight,
                green: fallbackG / fallbackWeight,
                blue: fallbackB / fallbackWeight,
                alpha: 1.0
            )
        } else {
            return nil
        }

        return clampForAmbientWarmth(rawColor)
    }

    /// Clamps saturation and brightness into a serene, low-saturation Apple ambient range.
    public static func clampForAmbientWarmth(_ color: UIColor) -> UIColor {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return color
        }
        let clampedSaturation = min(max(s * 0.72, 0.16), 0.46)
        let clampedBrightness = min(max(b, 0.36), 0.70)
        return UIColor(hue: h, saturation: clampedSaturation, brightness: clampedBrightness, alpha: 1.0)
    }

    /// Derives a harmonious companion tint shifted slightly in hue for organic multi-blob mesh depth.
    public static func companionTint(for primary: UIColor) -> UIColor {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        guard primary.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return primary
        }
        let shiftedHue = (h + 0.075).truncatingRemainder(dividingBy: 1.0)
        let shiftedSat = min(max(s * 0.85, 0.14), 0.42)
        let shiftedBright = min(max(b * 0.90, 0.30), 0.64)
        return UIColor(hue: shiftedHue, saturation: shiftedSat, brightness: shiftedBright, alpha: 1.0)
    }
}

// MARK: - Ambient Mesh Glow View

/// Multi-layer radial ambient wash that softly radiates cover-art warmth behind hero shelves
/// and detail pages, seamlessly dissolving into `MarcoColors.canvasBackground`.
public final class AmbientGlowView: UIView {
    private static let defaultCinemaTint = UIColor(red: 0.24, green: 0.31, blue: 0.44, alpha: 1.0)

    private let primaryBlobLayer = CAGradientLayer()
    private let secondaryBlobLayer = CAGradientLayer()
    private let canvasFadeLayer = CAGradientLayer()

    private var currentPrimaryColor: UIColor = AmbientGlowView.defaultCinemaTint
    private var extractionGeneration: UInt64 = 0

    /// Optional multiplier (`0.0...1.5`) for pages wanting an even subtler wash.
    public var intensityMultiplier: CGFloat = 1.0 {
        didSet {
            applyGradientColors(animated: false)
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupLayers() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true

        primaryBlobLayer.type = .radial
        primaryBlobLayer.startPoint = CGPoint(x: 0.28, y: 0.08)
        primaryBlobLayer.endPoint = CGPoint(x: 1.05, y: 0.92)
        primaryBlobLayer.locations = [0.0, 0.48, 1.0]

        secondaryBlobLayer.type = .radial
        secondaryBlobLayer.startPoint = CGPoint(x: 0.82, y: 0.14)
        secondaryBlobLayer.endPoint = CGPoint(x: 0.08, y: 0.96)
        secondaryBlobLayer.locations = [0.0, 0.52, 1.0]

        canvasFadeLayer.type = .axial
        canvasFadeLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        canvasFadeLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        canvasFadeLayer.locations = [0.0, 0.58, 1.0]

        layer.addSublayer(primaryBlobLayer)
        layer.addSublayer(secondaryBlobLayer)
        layer.addSublayer(canvasFadeLayer)

        applyGradientColors(animated: false)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        primaryBlobLayer.frame = bounds
        secondaryBlobLayer.frame = bounds
        canvasFadeLayer.frame = bounds
        CATransaction.commit()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyGradientColors(animated: false)
        }
    }

    /// Sets the dominant color directly and cross-fades the ambient mesh smoothly.
    public func setDominantColor(_ color: UIColor?, animated: Bool = true) {
        extractionGeneration &+= 1
        let target = color.map(MarcoDominantColorExtractor.clampForAmbientWarmth) ?? Self.defaultCinemaTint
        currentPrimaryColor = target
        applyGradientColors(animated: animated)
    }

    /// Extracts the dominant tone off the main thread from cover artwork and cross-fades smoothly.
    public func updateFromImage(_ image: UIImage?, animated: Bool = true) {
        extractionGeneration &+= 1
        let expectedGen = extractionGeneration
        guard let image = image else {
            currentPrimaryColor = Self.defaultCinemaTint
            applyGradientColors(animated: animated)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let extracted = MarcoDominantColorExtractor.extractDominantColor(from: image)
            DispatchQueue.main.async {
                guard let self = self, self.extractionGeneration == expectedGen else { return }
                self.currentPrimaryColor = extracted ?? Self.defaultCinemaTint
                self.applyGradientColors(animated: animated)
            }
        }
    }

    /// Resets back to the calm default cinema slate ambient tint.
    public func resetToDefault(animated: Bool = true) {
        setDominantColor(nil, animated: animated)
    }

    private func applyGradientColors(animated: Bool) {
        let isDark = traitCollection.userInterfaceStyle == .dark
        let multiplier = min(max(intensityMultiplier, 0.0), 1.5)

        let primaryAlpha: CGFloat = (isDark ? 0.42 : 0.17) * multiplier
        let primaryMidAlpha: CGFloat = (isDark ? 0.18 : 0.07) * multiplier
        let secondaryAlpha: CGFloat = (isDark ? 0.30 : 0.12) * multiplier
        let secondaryMidAlpha: CGFloat = (isDark ? 0.12 : 0.05) * multiplier

        let companion = MarcoDominantColorExtractor.companionTint(for: currentPrimaryColor)
        let canvas = MarcoColors.canvasBackground.resolvedColor(with: traitCollection)

        let newPrimaryColors: [CGColor] = [
            currentPrimaryColor.withAlphaComponent(primaryAlpha).cgColor,
            currentPrimaryColor.withAlphaComponent(primaryMidAlpha).cgColor,
            currentPrimaryColor.withAlphaComponent(0.0).cgColor,
        ]
        let newSecondaryColors: [CGColor] = [
            companion.withAlphaComponent(secondaryAlpha).cgColor,
            companion.withAlphaComponent(secondaryMidAlpha).cgColor,
            companion.withAlphaComponent(0.0).cgColor,
        ]
        let newFadeColors: [CGColor] = [
            canvas.withAlphaComponent(0.0).cgColor,
            canvas.withAlphaComponent(isDark ? 0.52 : 0.45).cgColor,
            canvas.withAlphaComponent(1.0).cgColor,
        ]

        let shouldAnimate = animated && !UIAccessibility.isReduceMotionEnabled
        if shouldAnimate {
            let duration: CFTimeInterval = 0.55
            animateColors(on: primaryBlobLayer, to: newPrimaryColors, duration: duration)
            animateColors(on: secondaryBlobLayer, to: newSecondaryColors, duration: duration)
            animateColors(on: canvasFadeLayer, to: newFadeColors, duration: 0.25)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            primaryBlobLayer.colors = newPrimaryColors
            secondaryBlobLayer.colors = newSecondaryColors
            canvasFadeLayer.colors = newFadeColors
            CATransaction.commit()
        }
    }

    private func animateColors(on gradientLayer: CAGradientLayer, to newColors: [CGColor], duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "colors")
        animation.fromValue = gradientLayer.presentation()?.colors ?? gradientLayer.colors
        animation.toValue = newColors
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradientLayer.colors = newColors
        gradientLayer.add(animation, forKey: "marcoAmbientColors")
    }
}
