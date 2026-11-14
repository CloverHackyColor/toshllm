import XCTest
@testable import ToshLLM

final class ImageGenMigrationTests: XCTestCase {
    func testImageEngineRoundTripPrefersNewEngineOverLegacyField() throws {
        var config = ImageInstanceConfig()
        config.modelID = ImageGenCatalog.customID
        config.engine = .sdcli

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ImageInstanceConfig.self, from: data)

        XCTAssertEqual(decoded.engine, .sdcli)
    }

    func testImageEngineMigratesLegacyInpaintEngine() throws {
        let json = #"{"inpaintEngine":"sd-cli-diffusion"}"#
        let decoded = try JSONDecoder().decode(
            ImageInstanceConfig.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.engine, .sdcli)
        XCTAssertEqual(decoded.sdcliMode, .diffusion)
    }

    func testCatalogModelAlwaysUsesSDCLI() throws {
        var config = ImageInstanceConfig()
        config.modelID = ImageGenCatalog.sd15.id
        config.engine = .iopaint

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ImageInstanceConfig.self, from: data)

        XCTAssertEqual(decoded.engine, .sdcli)
    }
}
