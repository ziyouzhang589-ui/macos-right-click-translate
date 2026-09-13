import Foundation

enum TranslationDirection: Equatable {
    case chineseToEnglish
    case englishToChinese

    var sourceDisplayName: String {
        switch self {
        case .chineseToEnglish:
            return "中文"
        case .englishToChinese:
            return "English"
        }
    }

    var targetDisplayName: String {
        switch self {
        case .chineseToEnglish:
            return "English"
        case .englishToChinese:
            return "简体中文"
        }
    }

    var sourceLanguage: Locale.Language {
        switch self {
        case .chineseToEnglish:
            return Locale.Language(identifier: "zh-Hans")
        case .englishToChinese:
            return Locale.Language(identifier: "en")
        }
    }

    var targetLanguage: Locale.Language {
        switch self {
        case .chineseToEnglish:
            return Locale.Language(identifier: "en")
        case .englishToChinese:
            return Locale.Language(identifier: "zh-Hans")
        }
    }

    var reversed: TranslationDirection {
        switch self {
        case .chineseToEnglish:
            return .englishToChinese
        case .englishToChinese:
            return .chineseToEnglish
        }
    }
}

enum TranslationTextClassifier {
    static func direction(for text: String) -> TranslationDirection {
        containsHanCharacter(text) ? .chineseToEnglish : .englishToChinese
    }

    static func hasTranslatableContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic || isHan(scalar.value)
        }
    }

    static func containsHanCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { isHan($0.value) }
    }

    private static func isHan(_ value: UInt32) -> Bool {
        switch value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0x2CEB0...0x2EBEF,
             0x30000...0x3134F:
            return true
        default:
            return false
        }
    }
}
