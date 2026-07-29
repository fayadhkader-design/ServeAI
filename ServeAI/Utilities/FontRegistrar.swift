import CoreText
import Foundation

enum FontRegistrar {
    private static let fontFiles = [
        "ArchivoBlack-Regular",
        "JetBrainsMono-Regular",
        "JetBrainsMono-Bold",
        "SpaceGrotesk-Regular",
        "SpaceGrotesk-Medium",
        "SpaceGrotesk-SemiBold",
        "SpaceGrotesk-Bold"
    ]

    static func registerFonts() {
        fontFiles.forEach { name in
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { return }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
