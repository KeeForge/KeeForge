import Foundation
import XCTest
@testable import KeeForge

final class KDBXCompatibilityArtifactTests: XCTestCase {
    private var bundle: Bundle {
        Bundle(for: Self.self)
    }

    func testEmitCompatibilityArtifactsForExternalOpenerGate() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kdbx-compatibility-artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let plans = try KDBXCompatibilitySupport.artifactPlans(bundle: bundle)
        var manifestArtifacts: [KDBXCompatibilitySupport.ArtifactManifest.Artifact] = []
        var attachedKeyFiles: Set<String> = []

        for plan in plans {
            let result = try plan.scenario.apply(to: plan.fixture)
            let artifactURL = outputDirectory.appendingPathComponent(plan.scenario.artifactFileName)
            try result.written.write(to: artifactURL, options: .atomic)

            let attachment = XCTAttachment(contentsOfFile: artifactURL)
            attachment.name = plan.scenario.artifactFileName
            attachment.lifetime = .keepAlways
            add(attachment)

            let keyFileAttachmentName: String?
            if let keyFileData = plan.fixture.keyFileData, let fixtureKeyFileName = plan.fixture.fixture.keyFileName {
                keyFileAttachmentName = "\(fixtureKeyFileName).key"
                if let keyFileAttachmentName, attachedKeyFiles.insert(keyFileAttachmentName).inserted {
                    let keyFileURL = outputDirectory.appendingPathComponent(keyFileAttachmentName)
                    try keyFileData.write(to: keyFileURL, options: .atomic)
                    let keyAttachment = XCTAttachment(contentsOfFile: keyFileURL)
                    keyAttachment.name = keyFileAttachmentName
                    keyAttachment.lifetime = .keepAlways
                    add(keyAttachment)
                }
            } else {
                keyFileAttachmentName = nil
            }

            manifestArtifacts.append(
                KDBXCompatibilitySupport.ArtifactManifest.Artifact(
                    id: "\(plan.fixture.fixture.id)-\(plan.scenario.id)",
                    fileName: plan.scenario.artifactFileName,
                    password: plan.fixture.fixture.password,
                    keyFileName: keyFileAttachmentName,
                    expectedSearchTerms: plan.scenario.expectedSearchTerms,
                    expectedGroupPaths: plan.scenario.expectedGroupPaths,
                    expectedAttachments: KDBXCompatibilitySupport.expectedAttachments(forScenarioID: plan.scenario.id)
                )
            )
        }

        let manifest = KDBXCompatibilitySupport.ArtifactManifest(artifacts: manifestArtifacts)
        let manifestData = try JSONEncoder.compatibilityManifest.encode(manifest)
        let manifestURL = outputDirectory.appendingPathComponent(KDBXCompatibilitySupport.artifactManifestName)
        try manifestData.write(to: manifestURL, options: .atomic)

        let manifestAttachment = XCTAttachment(contentsOfFile: manifestURL)
        manifestAttachment.name = KDBXCompatibilitySupport.artifactManifestName
        manifestAttachment.lifetime = .keepAlways
        add(manifestAttachment)
    }

    func testKeeOTPArtifactUsesStandardExternalProbe() throws {
        let plan = try KDBXCompatibilitySupport.artifactPlans(bundle: bundle)
            .first { $0.scenario.id == "keeotp-source-matrix" }

        XCTAssertEqual(plan?.scenario.expectedSearchTerms, ["Compat Update Target"])
        XCTAssertEqual(
            plan?.fixture.rootGroup.entries.filter { $0.title.hasPrefix("KeeOTP ") }.count,
            KDBXCompatibilitySupport.keeOTPCases.count
        )
    }
}

private extension JSONEncoder {
    static var compatibilityManifest: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
