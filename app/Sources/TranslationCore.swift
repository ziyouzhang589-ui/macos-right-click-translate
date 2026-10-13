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
    /// 按中英文的比重判断方向，而不是「出现汉字就算中文」。
    ///
    /// 一整段英文里混进一两个中文词（菜单名、人名等）是常见情况，
    /// 若据此判成中译英，系统会把英文原样返回，看上去像没有翻译。
    /// 这里用汉字个数与英文单词个数相比：汉字多算中文，否则算英文。
    static func direction(for text: String) -> TranslationDirection {
        let hanCount = hanCharacterCount(text)
        guard hanCount > 0 else { return .englishToChinese }
        return hanCount > latinWordCount(text) ? .chineseToEnglish : .englishToChinese
    }

    static func hanCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if isHan(scalar.value) { count += 1 }
        }
    }

    /// 连续的拉丁字母算作一个单词，用来和汉字个数作比较。
    static func latinWordCount(_ text: String) -> Int {
        var count = 0
        var insideWord = false
        for scalar in text.unicodeScalars {
            let isLetter = scalar.properties.isAlphabetic && !isHan(scalar.value)
            if isLetter {
                if !insideWord {
                    count += 1
                    insideWord = true
                }
            } else {
                insideWord = false
            }
        }
        return count
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
