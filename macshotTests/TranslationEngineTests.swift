import XCTest

/// Pure pieces of the translation layer: request budgeting, answer
/// reconciliation, signing, vendor-response parsing and the language mapping.
///
/// Nothing here touches the network — the signed vendor APIs are exactly the
/// parts that break silently (a wrong digest or a misplaced line reads as
/// "translation failed"), so they are pinned down with recorded responses.
final class TranslationEngineTests: XCTestCase {

    // MARK: - Batch planning

    func testPlannerSkipsBlankLinesAndKeepsOrder() {
        let texts = ["one", "", "  ", "two", "three"]
        let groups = TranslationBatchPlanner.groups(for: texts, maximumBytes: 1000, maximumLines: 20)
        XCTAssertEqual(groups, [[0, 3, 4]], "blank entries must not be sent to the vendor")
    }

    func testPlannerRespectsTheLineBudget() {
        let texts = ["a", "b", "c", "d", "e"]
        let groups = TranslationBatchPlanner.groups(for: texts, maximumBytes: 1000, maximumLines: 2)
        XCTAssertEqual(groups, [[0, 1], [2, 3], [4]])
    }

    func testPlannerRespectsTheByteBudget() {
        // Each entry costs its UTF-8 length + 1 for the joining newline.
        let texts = ["12345", "12345", "12345"]
        let tight = TranslationBatchPlanner.groups(for: texts, maximumBytes: 11, maximumLines: 20)
        XCTAssertEqual(tight, [[0], [1], [2]], "one 6-byte line only")

        let pair = TranslationBatchPlanner.groups(for: texts, maximumBytes: 12, maximumLines: 20)
        XCTAssertEqual(pair, [[0, 1], [2]], "12 bytes fits exactly one pair of lines")
    }

    func testPlannerGivesAnOversizedLineItsOwnGroup() {
        // Truncating the user's text would silently translate something else.
        let texts = ["short", String(repeating: "x", count: 50)]
        let groups = TranslationBatchPlanner.groups(for: texts, maximumBytes: 10, maximumLines: 20)
        XCTAssertEqual(groups, [[0], [1]])
    }

    func testPlannerReturnsNoGroupsWhenEverythingIsBlank() {
        XCTAssertEqual(TranslationBatchPlanner.groups(for: ["", "  \n"], maximumBytes: 100, maximumLines: 5), [])
        XCTAssertEqual(TranslationBatchPlanner.groups(for: [], maximumBytes: 100, maximumLines: 5), [])
    }

    func testPlannerCountsMultibyteTextInBytes() {
        // 5 CJK characters are 15 bytes; two of them do not fit in 20 bytes.
        let texts = ["中文中文中", "中文中文中"]
        let groups = TranslationBatchPlanner.groups(for: texts, maximumBytes: 20, maximumLines: 20)
        XCTAssertEqual(groups, [[0], [1]])
    }

    // MARK: - Answer reconciliation

    func testReconcilerMapsOneAnswerPerLine() {
        XCTAssertEqual(
            TranslationBatchReconciler.reconcile(segments: ["a", "b"], sentCount: 2), ["a", "b"])
    }

    func testReconcilerAcceptsASingleSegmentForASingleLine() {
        XCTAssertEqual(
            TranslationBatchReconciler.reconcile(segments: ["merged"], sentCount: 1), ["merged"])
    }

    func testReconcilerStitchesSentenceSegmentsOfOneLine() {
        // Vendors split a long line by sentence; they still belong to that line.
        XCTAssertEqual(
            TranslationBatchReconciler.reconcile(segments: ["First one.", " Second one."], sentCount: 1),
            ["First one. Second one."])
    }

    func testReconcilerRefusesAnAmbiguousAnswer() {
        // The vendor split one line into two segments: mapping them positionally
        // would shift every following line onto the wrong source line.
        XCTAssertNil(TranslationBatchReconciler.reconcile(segments: ["a", "b"], sentCount: 3))
        XCTAssertNil(TranslationBatchReconciler.reconcile(segments: [], sentCount: 2))
        XCTAssertEqual(TranslationBatchReconciler.reconcile(segments: [], sentCount: 0), [])
    }

    // MARK: - Signing

    func testBaiduSignatureIsMD5() {
        // md5("hello"), the digest a Baidu developer console test would produce.
        XCTAssertEqual(
            TranslationSigner.md5Hex("hello"), "5d41402abc4b2a76b9719d911017c592")
    }

    func testYoudaoSignatureIsSHA256() {
        // sha256("hello")
        XCTAssertEqual(
            TranslationSigner.sha256Hex("hello"),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testYoudaoHashesAShortQueryWhole() {
        XCTAssertEqual(TranslationSigner.youdaoQueryFingerprint("Hello world"), "Hello world")
        // Exactly 20 characters stays whole.
        let twenty = "12345678901234567890"
        XCTAssertEqual(TranslationSigner.youdaoQueryFingerprint(twenty), twenty)
    }

    func testYoudaoShortensLongQueries() {
        // first 10 + character count + last 10, as the v3 signature spec defines.
        let query = "1234567890MIDDLE0987654321TAIL"
        XCTAssertEqual(query.count, 30)
        XCTAssertEqual(
            TranslationSigner.youdaoQueryFingerprint(query),
            "1234567890" + "30" + "87654321TAIL")
    }

    // MARK: - Vendor responses

    func testBaiduResponseYieldsOneSegmentPerLine() throws {
        let json = """
        {"from":"en","to":"zh","trans_result":[{"src":"one","dst":"一"},{"src":"two","dst":"二"}]}
        """
        let segments = try BaiduTranslationEngine.parseSegments(from: Data(json.utf8))
        XCTAssertEqual(segments, ["一", "二"])
    }

    func testBaiduErrorCodeAsStringBecomesAReadableError() {
        let json = #"{"error_code":"54003","error_msg":"Invalid Access Limit"}"#
        XCTAssertThrowsError(try BaiduTranslationEngine.parseSegments(from: Data(json.utf8))) { error in
            guard case TranslationError.service(let message)? = error as? TranslationError else {
                return XCTFail("expected a vendor service error, got \(error)")
            }
            XCTAssertTrue(message.contains("54003"), "the vendor code has to survive: \(message)")
            XCTAssertTrue(message.contains("Invalid Access Limit"), "the vendor message has to survive: \(message)")
        }
    }

    func testBaiduErrorCodeAsNumberIsAccepted() {
        // Baidu sends the same field as a JSON number in some responses.
        let json = #"{"error_code":52003,"error_msg":"UNAUTHORIZED USER"}"#
        XCTAssertThrowsError(try BaiduTranslationEngine.parseSegments(from: Data(json.utf8))) { error in
            guard case TranslationError.service(let message)? = error as? TranslationError else {
                return XCTFail("expected a vendor service error, got \(error)")
            }
            XCTAssertTrue(message.contains("52003"), message)
        }
    }

    func testBaiduSuccessCodeIsNotAnError() throws {
        let json = #"{"error_code":"52000","trans_result":[{"src":"a","dst":"b"}]}"#
        XCTAssertEqual(try BaiduTranslationEngine.parseSegments(from: Data(json.utf8)), ["b"])
    }

    func testBaiduEmptyResultIsReportedAsSuch() {
        let json = #"{"from":"en","to":"zh"}"#
        XCTAssertThrowsError(try BaiduTranslationEngine.parseSegments(from: Data(json.utf8))) { error in
            guard case TranslationError.emptyResult? = error as? TranslationError else {
                return XCTFail("expected emptyResult, got \(error)")
            }
        }
    }

    func testBaiduGarbageIsAParseError() {
        XCTAssertThrowsError(try BaiduTranslationEngine.parseSegments(from: Data("not json".utf8))) { error in
            guard case TranslationError.parseError? = error as? TranslationError else {
                return XCTFail("expected parseError, got \(error)")
            }
        }
    }

    func testYoudaoResponseYieldsOneSegmentPerLine() throws {
        let json = #"{"errorCode":"0","translation":["一","二"],"query":"one\ntwo"}"#
        XCTAssertEqual(try YoudaoTranslationEngine.parseSegments(from: Data(json.utf8)), ["一", "二"])
    }

    func testYoudaoErrorCodeCarriesAnActionableHint() {
        let json = #"{"errorCode":"202"}"#
        XCTAssertThrowsError(try YoudaoTranslationEngine.parseSegments(from: Data(json.utf8))) { error in
            guard case TranslationError.service(let message)? = error as? TranslationError else {
                return XCTFail("expected a vendor service error, got \(error)")
            }
            XCTAssertTrue(message.contains("202"), message)
            XCTAssertTrue(message.lowercased().contains("secret key"), message)
        }
    }

    func testYoudaoUnknownErrorCodeStillNamesTheCode() {
        XCTAssertTrue(YoudaoTranslationEngine.describe(errorCode: "999").contains("999"))
    }

    func testFlexibleStringAcceptsBothJSONShapes() throws {
        XCTAssertEqual(try JSONDecoder().decode(FlexibleString.self, from: Data(#""7""#.utf8)).value, "7")
        XCTAssertEqual(try JSONDecoder().decode(FlexibleString.self, from: Data("7".utf8)).value, "7")
        XCTAssertEqual(try JSONDecoder().decode(FlexibleString.self, from: Data("7.5".utf8)).value, "7.5")
    }

    // MARK: - Language mapping

    func testBaiduOnlyAdvertisesLanguagesItCanBeAskedFor() {
        let engine = BaiduTranslationEngine()
        let codes = Set(engine.languages.map(\.code))
        XCTAssertTrue(codes.contains("zh-TW"), "Baidu spells Traditional Chinese `cht`, but must still offer it")
        XCTAssertFalse(codes.contains("sk"), "Slovak has no verified Baidu mapping and must not be offered")
        XCTAssertEqual(BaiduTranslationEngine.vendorCode(for: "zh-TW"), "cht")
    }

    func testYoudaoOffersTheWholeCatalog() {
        let offered = Set(YoudaoTranslationEngine().languages.map(\.code))
        XCTAssertEqual(offered, Set(TranslationLanguageCatalog.all.map(\.code)))
        XCTAssertEqual(YoudaoTranslationEngine.vendorCode(for: "zh-CN"), "zh-CHS")
        XCTAssertEqual(YoudaoTranslationEngine.vendorCode(for: "nb"), "no")
    }

    func testEveryMappingTargetsACatalogLanguage() {
        // Guards against a typo in a canonical code: the engine would advertise a
        // language the pickers can never show.
        for engine in TranslationEngineRegistry.engines {
            for language in engine.languages {
                XCTAssertNotNil(TranslationLanguageCatalog.language(for: language.code),
                                "\(engine.provider.rawValue) offers \(language.code), which is not in the catalog")
            }
        }
    }

    func testEnginesAreNeverEmptyAndAdvertiseTheirBrandName() {
        for engine in TranslationEngineRegistry.engines {
            XCTAssertFalse(engine.displayName.isEmpty)
            XCTAssertFalse(engine.languages.isEmpty, "\(engine.displayName) offers no languages")
        }
    }

    // MARK: - Resolution + settings

    func testUnsupportedTargetFallsBackToTheEngineDefault() {
        let codes = BaiduTranslationEngine().languages.map(\.code)
        XCTAssertEqual(TranslationLanguageCatalog.resolvedCode("sk", in: codes), "en")
        XCTAssertEqual(TranslationLanguageCatalog.resolvedCode("ja", in: codes), "ja")
    }

    func testStoredProviderForAnUnavailableEngineFallsBack() {
        withDefaults(["translationProvider": "not-a-provider"]) {
            XCTAssertEqual(TranslationService.provider, TranslationEngineRegistry.fallbackProvider)
        }
    }

    func testTargetLanguageIsClampedButTheStoredChoiceSurvives() {
        // Baidu has no Slovak: translating into it has to use something it knows,
        // while the user's stored pick stays put for when they switch back.
        withDefaults(["translationProvider": "baidu", "translateTargetLang": "sk"]) {
            XCTAssertEqual(TranslationService.targetLanguage, "en")
            XCTAssertEqual(UserDefaults.standard.string(forKey: "translateTargetLang"), "sk")
        }
    }

    func testCredentialsAreTrimmedAndClearedWhenEmpty() {
        withDefaults(["baiduTranslateAppID": nil, "baiduTranslateSecretKey": nil]) {
            TranslationCredentials.set("  app-123  ", for: "baiduTranslateAppID")
            XCTAssertEqual(TranslationCredentials.value(for: "baiduTranslateAppID"), "app-123")

            let engine = TranslationEngineRegistry.engine(for: .baidu)
            XCTAssertEqual(engine?.isConfigured, false, "an app id without its secret is not configured")

            TranslationCredentials.set("secret-456", for: "baiduTranslateSecretKey")
            XCTAssertEqual(engine?.isConfigured, true)

            TranslationCredentials.set("", for: "baiduTranslateAppID")
            XCTAssertEqual(TranslationCredentials.value(for: "baiduTranslateAppID"), "")
        }
    }

    func testTranslationCredentialsNeverLeaveTheMachineInASettingsExport() {
        for key in [
            BaiduTranslationEngine.appIDKey, BaiduTranslationEngine.secretKey,
            YoudaoTranslationEngine.appKeyDefaultsKey, YoudaoTranslationEngine.appSecretDefaultsKey,
        ] {
            XCTAssertFalse(SettingsPortability.isPortable(key), "`\(key)` must not be exported")
        }
    }
}
