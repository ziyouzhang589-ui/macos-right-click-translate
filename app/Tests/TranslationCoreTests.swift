import Foundation

@main
private enum TranslationCoreTests {
    static func main() {
        expect(
            TranslationTextClassifier.direction(for: "你好，世界") == .chineseToEnglish,
            "Chinese text should translate to English"
        )
        expect(
            TranslationTextClassifier.direction(for: "Hello, world") == .englishToChinese,
            "English text should translate to Chinese"
        )
        expect(
            TranslationTextClassifier.direction(for: "OpenAI 发布了新功能") == .chineseToEnglish,
            "Mixed text containing Han characters should translate to English"
        )
        expect(
            TranslationTextClassifier.direction(for: "OpenAI 2026") == .englishToChinese,
            "English text with numbers should translate to Chinese"
        )
        expect(
            TranslationTextClassifier.direction(for: "繁體中文") == .chineseToEnglish,
            "Traditional Chinese characters should be recognized as Chinese"
        )
        expect(
            !TranslationTextClassifier.hasTranslatableContent("  123 — !!!  "),
            "Numbers and punctuation should not trigger translation"
        )
        expect(
            TranslationTextClassifier.hasTranslatableContent("word"),
            "Alphabetic text should trigger translation"
        )
        expect(
            TranslationDirection.chineseToEnglish.reversed == .englishToChinese,
            "Direction reversal should work"
        )
        expect(
            TranslationDirection.englishToChinese.reversed == .chineseToEnglish,
            "Reverse direction should be symmetric"
        )

        print("TranslationCoreTests: all tests passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fputs("Test failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
