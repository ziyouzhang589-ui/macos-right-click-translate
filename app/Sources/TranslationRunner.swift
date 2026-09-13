import Foundation
import Translation

/// 主窗口与就地浮层共用的翻译管线。
enum TranslationRunner {
    /// 为一次请求刷新 `TranslationSession` 配置。
    ///
    /// 语言组合未变时改为让现有配置失效，从而在同一语言对下重复触发翻译。
    static func refresh(
        _ configuration: inout TranslationSession.Configuration?,
        for request: TranslationRequest
    ) {
        // Build against the macOS 15 SDK so Translation uses its traditional,
        // low-latency on-device model on every supported OS version.
        let newConfiguration = TranslationSession.Configuration(
            source: request.direction.sourceLanguage,
            target: request.direction.targetLanguage
        )

        if configuration?.source == newConfiguration.source,
           configuration?.target == newConfiguration.target {
            configuration?.invalidate()
        } else {
            configuration = newConfiguration
        }
    }

    @MainActor
    static func run(session: TranslationSession, model: TranslatorModel) async {
        guard let request = model.pendingRequest else { return }

        do {
            let availability = LanguageAvailability()
            let status = await availability.status(
                from: request.direction.sourceLanguage,
                to: request.direction.targetLanguage
            )
            guard model.pendingRequest?.id == request.id else { return }

            switch status {
            case .installed:
                break
            case .supported:
                model.beginLanguageDownload(for: request)
                try await session.prepareTranslation()
                let refreshedStatus = await availability.status(
                    from: request.direction.sourceLanguage,
                    to: request.direction.targetLanguage
                )
                guard refreshedStatus == .installed else {
                    model.fail("语言包尚未下载完成，请完成下载后重新翻译", for: request)
                    return
                }
            case .unsupported:
                model.fail("系统不支持当前中英文翻译组合", for: request)
                return
            @unknown default:
                model.fail("暂时无法确认语言支持状态", for: request)
                return
            }

            guard model.pendingRequest?.id == request.id else { return }
            model.beginTranslation(for: request)
            let response = try await session.translate(request.text)
            guard !Task.isCancelled else { return }
            model.finish(response.targetText, for: request)
        } catch is CancellationError {
            return
        } catch {
            model.fail(friendlyMessage(for: error), for: request)
        }
    }

    static func friendlyMessage(for error: Error) -> String {
        if error is TranslationError {
            return error.localizedDescription.isEmpty
                ? "翻译失败，请稍后重试"
                : "翻译失败：\(error.localizedDescription)"
        }
        return "翻译失败，请稍后重试"
    }
}
