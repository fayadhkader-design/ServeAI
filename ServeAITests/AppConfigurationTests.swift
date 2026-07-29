import XCTest
@testable import ServeAI

final class AppConfigurationTests: XCTestCase {
    func testVisionIsTheDefaultAnalysisMode() {
        let configuration = AppConfiguration.resolve(environment: [:])

        XCTAssertEqual(configuration.analysisMode, .vision)
    }

    func testExplicitMockModeRemainsAvailableForDevelopment() {
        let configuration = AppConfiguration.resolve(
            environment: [AppConfiguration.analysisModeEnvironmentKey: " MOCK "]
        )

        XCTAssertEqual(configuration.analysisMode, .mock)
    }

    func testCoreMLModeIsCaseInsensitive() {
        let configuration = AppConfiguration.resolve(
            environment: [AppConfiguration.analysisModeEnvironmentKey: "CoreML"]
        )

        XCTAssertEqual(configuration.analysisMode, .coreML)
    }

    func testExperimentalCoreMLModeIsExplicit() {
        let configuration = AppConfiguration.resolve(
            environment: [AppConfiguration.analysisModeEnvironmentKey: "ExperimentalCoreML"]
        )

        XCTAssertEqual(configuration.analysisMode, .experimentalCoreML)
        XCTAssertEqual(
            ServiceFactory.analysisService(configuration: configuration).source,
            .experimentalCoreML
        )
    }

    func testEvaluationCoreMLModeIsExplicitAndClearlyLabeled() {
        let configuration = AppConfiguration.resolve(
            environment: [AppConfiguration.analysisModeEnvironmentKey: "EvaluationCoreML"]
        )

        XCTAssertEqual(configuration.analysisMode, .evaluationCoreML)
        XCTAssertEqual(
            ServiceFactory.analysisService(configuration: configuration).source,
            .evaluationCoreML
        )
        XCTAssertTrue(AnalysisSource.evaluationCoreML.title.contains("not released"))
        XCTAssertTrue(AnalysisSource.evaluationCoreML.detail.contains("not coaching advice"))
        XCTAssertTrue(AnalysisSource.evaluationCoreML.requiresCautionBanner)
        XCTAssertTrue(AppConfiguration.permitsEvaluationCandidateMode)
    }

    func testEvaluationModeCannotBecomeItsOwnFallback() {
        let configuration = AppConfiguration.resolve(
            environment: [:],
            defaultMode: .evaluationCoreML
        )

        XCTAssertEqual(configuration.analysisMode, .vision)
    }

    func testUnknownModeFallsBackToRequestedDefault() {
        let configuration = AppConfiguration.resolve(
            environment: [AppConfiguration.analysisModeEnvironmentKey: "not-a-mode"],
            defaultMode: .mock
        )

        XCTAssertEqual(configuration.analysisMode, .mock)
    }

    func testFactoryWiresDefaultConfigurationToRealVisionService() {
        let configuration = AppConfiguration.resolve(environment: [:])

        XCTAssertEqual(ServiceFactory.analysisService(configuration: configuration).source, .vision)
    }

    func testReleasePolicyRejectsEveryDevelopmentOnlyMode() {
        for mode in [AnalysisMode.mock, .experimentalCoreML, .evaluationCoreML] {
            let configuration = AppConfiguration.resolve(
                environment: [AppConfiguration.analysisModeEnvironmentKey: mode.rawValue],
                permitsDevelopmentModes: false
            )

            XCTAssertEqual(configuration.analysisMode, .vision)
        }
    }

    func testReleasePolicyRejectsDevelopmentOnlyFallback() {
        let configuration = AppConfiguration.resolve(
            environment: [AppConfiguration.analysisModeEnvironmentKey: "unknown"],
            defaultMode: .mock,
            permitsDevelopmentModes: false
        )

        XCTAssertEqual(configuration.analysisMode, .vision)
    }
}
