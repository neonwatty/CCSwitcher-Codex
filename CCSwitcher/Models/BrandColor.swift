import SwiftUI
import AppKit

extension Color {
    /// CCSwitcher brand color.
    // static let brand = Color(red: 0x7C / 255.0, green: 0x3A / 255.0, blue: 0xED / 255.0) // #7C3AED
    static let brand = Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0) // #d97757

    /// Creates a color that automatically adapts between light and dark appearance.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        }))
    }

    // MARK: - Card Fills

    /// Active/brand card background.
    static let cardFill = adaptive(light: brand.opacity(0.22), dark: brand.opacity(0.38))
    /// Stronger active card background (e.g. active account row).
    static let cardFillStrong = adaptive(light: brand.opacity(0.28), dark: brand.opacity(0.45))
    /// Neutral/inactive card background.
    static let cardFillNeutral = adaptive(light: Color.gray.opacity(0.18), dark: Color.gray.opacity(0.35))
    /// Green-tinted card background (cost cards).
    static let cardFillGreen = adaptive(light: Color.green.opacity(0.18), dark: Color.green.opacity(0.35))

    // MARK: - Card Borders

    /// Brand-colored card border.
    static let cardBorderBrand = adaptive(light: brand.opacity(0.55), dark: brand.opacity(0.75))
    /// Neutral card border.
    static let cardBorderNeutral = adaptive(light: Color.gray.opacity(0.45), dark: Color.gray.opacity(0.65))
    /// Green card border (cost cards).
    static let cardBorderGreen = adaptive(light: Color.green.opacity(0.55), dark: Color.green.opacity(0.75))

    // MARK: - Subtle Backgrounds

    /// Subtle brand tint for banners and badges.
    static let subtleBrand = adaptive(light: brand.opacity(0.25), dark: brand.opacity(0.42))
    /// Tab bar outer background.
    static let tabBackground = adaptive(light: brand.opacity(0.20), dark: brand.opacity(0.38))
    /// Tab bar selected indicator.
    static let tabSelected = adaptive(light: brand.opacity(0.32), dark: brand.opacity(0.52))
    /// Progress bar track.
    static let progressTrack = adaptive(light: Color.gray.opacity(0.35), dark: Color.gray.opacity(0.55))
}

extension ShapeStyle where Self == Color {
    static var brand: Color { .brand }
    static var cardFill: Color { .cardFill }
    static var cardFillStrong: Color { .cardFillStrong }
    static var cardFillNeutral: Color { .cardFillNeutral }
    static var cardFillGreen: Color { .cardFillGreen }
    static var cardBorderBrand: Color { .cardBorderBrand }
    static var cardBorderNeutral: Color { .cardBorderNeutral }
    static var cardBorderGreen: Color { .cardBorderGreen }
    static var subtleBrand: Color { .subtleBrand }
    static var tabBackground: Color { .tabBackground }
    static var tabSelected: Color { .tabSelected }
    static var progressTrack: Color { .progressTrack }
}
