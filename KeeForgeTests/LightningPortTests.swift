import XCTest
@testable import KeeForge

/// Which devices offer "YubiKey via Lightning". YubiKit alone would offer it on
/// every iPhone newer than its model table, all of which have USB-C.
final class LightningPortTests: XCTestCase {
    func testLightningIPhonesHaveThePort() {
        // iPhone XS, iPhone 11, iPhone SE (3rd generation), iPhone 14, iPhone 14 Pro Max.
        for model in ["iPhone11,2", "iPhone12,1", "iPhone14,6", "iPhone14,7", "iPhone15,3"] {
            XCTAssertTrue(LightningPort.isPresent(onModel: model), model)
        }
    }

    func testUSBCIPhonesHaveNoPort() {
        // iPhone 15, iPhone 15 Pro Max, iPhone 16, iPhone 16e, iPhone 17.
        for model in ["iPhone15,4", "iPhone16,2", "iPhone17,3", "iPhone17,5", "iPhone18,3"] {
            XCTAssertFalse(LightningPort.isPresent(onModel: model), model)
        }
    }

    func testLightningIPadsHaveThePort() {
        // iPad Pro 10.5-inch, iPad (7th generation), iPad mini (5th generation),
        // iPad (8th generation), iPad (9th generation).
        for model in ["iPad7,3", "iPad7,12", "iPad11,1", "iPad11,7", "iPad12,2"] {
            XCTAssertTrue(LightningPort.isPresent(onModel: model), model)
        }
    }

    func testUSBCIPadsHaveNoPort() {
        // iPad Pro 11-inch (2018), iPad Air (4th generation), iPad (10th generation),
        // iPad mini (6th generation), a model newer than this table.
        for model in ["iPad8,1", "iPad13,1", "iPad13,18", "iPad14,1", "iPad16,3"] {
            XCTAssertFalse(LightningPort.isPresent(onModel: model), model)
        }
    }

    func testUnrecognizedIdentifiersHaveNoPort() {
        for model in ["arm64", "x86_64", "", "iPhone", "iPhone15", "iPhone15,", "iPhone,4", "iPhoneX,1", "iPod9,1", "Watch7,1"] {
            XCTAssertFalse(LightningPort.isPresent(onModel: model), model)
        }
    }
}
