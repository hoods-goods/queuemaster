import XCTest
@testable import CupsKit

/// Fixtures are real output captured from CUPS 2.4 with three test queues:
/// DYMO_4XL (default), Zebra_ZPL (paused, two jobs, one held) and
/// Office_Laser (rejecting jobs).
final class ParserTests: XCTestCase {

    func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return Parsers.decodePPD(try Data(contentsOf: url))
    }

    func testLpoptionsAttributesWithUnescapedQuotes() throws {
        var p = Printer(name: "Zebra_ZPL")
        Parsers.applyLpoptions(try fixture("lpoptions_p.txt"), to: &p)
        XCTAssertEqual(p.info, "Zebra 'ZPL' test")
        XCTAssertEqual(p.location, "")
        XCTAssertEqual(p.makeAndModel, "Zebra ZPL Label Printer")
        XCTAssertEqual(p.deviceURI, "socket://10.0.0.20")
        XCTAssertEqual(p.state, .stopped) // captured while paused
        XCTAssertTrue(p.isShared)
        XCTAssertTrue(p.isAccepting)
        XCTAssertEqual(p.attributes["printer-uri-supported"], "ipp://localhost/printers/Zebra_ZPL")
    }

    func testOptionTokens() {
        let d = Parsers.optionDictionary("PageSize=w288h432 printer-info='Front desk, shelf 2' Collate cupsDarkness=Dark")
        XCTAssertEqual(d["PageSize"], "w288h432")
        XCTAssertEqual(d["printer-info"], "Front desk, shelf 2")
        XCTAssertEqual(d["cupsDarkness"], "Dark")
        XCTAssertEqual(d["Collate"], "")
    }

    func testUserOptionsFile() {
        let text = "Default DYMO_4XL PageSize=w162h288\nDest Zebra_ZPL Darkness=20 zePrintMode=Tear\nDest Zebra_ZPL/thick Darkness=30\n"
        let opts = Parsers.userOptionsFile(text)
        XCTAssertEqual(opts["DYMO_4XL"]?["PageSize"], "w162h288")
        XCTAssertEqual(opts["Zebra_ZPL"]?["Darkness"], "20")
        XCTAssertEqual(opts["Zebra_ZPL"]?["zePrintMode"], "Tear")
    }

    func testPrinterStatus() throws {
        let st = Parsers.printerStatus(try fixture("lpstat_p.txt"))
        XCTAssertEqual(st["DYMO_4XL"]?.enabled, true)
        XCTAssertEqual(st["Zebra_ZPL"]?.enabled, false)
        XCTAssertEqual(st["Zebra_ZPL"]?.message, "Out of labels")
        XCTAssertEqual(st["Office_Laser"]?.message, "Maintenance")
        let printing = Parsers.printerStatus("printer HP is now printing HP-12.  enabled since Fri Oct 23 09:26:13 2026\n")
        XCTAssertEqual(printing["HP"]?.nowPrinting, "HP-12")
    }

    func testAcceptance() throws {
        let a = Parsers.acceptance(try fixture("lpstat_a.txt"))
        XCTAssertEqual(a["DYMO_4XL"]?.accepting, true)
        XCTAssertEqual(a["Office_Laser"]?.accepting, false)
        XCTAssertEqual(a["Office_Laser"]?.reason, "Maintenance")
    }

    func testDefaultAndDestinations() {
        XCTAssertEqual(Parsers.defaultDestination("system default destination: DYMO_4XL\n"), "DYMO_4XL")
        XCTAssertNil(Parsers.defaultDestination("no system default destination\n"))
        XCTAssertEqual(Parsers.destinations("DYMO_4XL\nOffice_Laser\nZebra_ZPL\n"), ["DYMO_4XL", "Office_Laser", "Zebra_ZPL"])
    }

    func testJobsAndTitles() throws {
        var jobs = Parsers.jobs(try fixture("lpstat_jobs.txt"))
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs[0].id, "Zebra_ZPL-1")
        XCTAssertEqual(jobs[0].number, 1)
        XCTAssertEqual(jobs[0].printer, "Zebra_ZPL")
        XCTAssertEqual(jobs[0].user, "root")
        XCTAssertEqual(jobs[0].size, 1024)
        XCTAssertEqual(jobs[0].state, .pending)
        XCTAssertEqual(jobs[1].state, .held)

        let titles = Parsers.lpqTitles(try fixture("lpq.txt"))
        XCTAssertEqual(titles[1]?.title, "Test label")
        XCTAssertEqual(titles[2]?.title, "held job")
        jobs[0].title = titles[1]!.title
        XCTAssertEqual(jobs[0].title, "Test label")
    }

    func testOptionList() throws {
        let opts = Parsers.optionList(try fixture("lpoptions_l.txt"))
        let page = try XCTUnwrap(opts.first { $0.key == "PageSize" })
        XCTAssertEqual(page.label, "Media Size")
        XCTAssertEqual(page.current, "w288h360")
        XCTAssertTrue(page.supportsCustom)
        XCTAssertFalse(page.choices.contains { $0.keyword.hasPrefix("Custom") })
        let darkness = try XCTUnwrap(opts.first { $0.key == "Darkness" })
        XCTAssertEqual(darkness.current, "-1")
        XCTAssertEqual(opts.first { $0.key == "zePrintMode" }?.choices.map(\.keyword),
                       ["Saved", "Tear", "Peel", "Rewind", "Applicator", "Cutter"])
    }

    func testPPD() throws {
        let groups = Parsers.ppd(try fixture("dymo.ppd"))
        let all = groups.flatMap(\.options)
        XCTAssertNil(all.first { $0.key == "PageRegion" }, "PageRegion duplicates PageSize and is hidden")
        let page = try XCTUnwrap(all.first { $0.key == "PageSize" })
        XCTAssertEqual(page.queueDefault, "w81h252")
        XCTAssertEqual(page.choices.first?.label, "Address")
        XCTAssertEqual(page.label(for: "w162h288"), "2.25x4.00\"")
        let dark = try XCTUnwrap(all.first { $0.key == "cupsDarkness" })
        XCTAssertEqual(dark.choices.map(\.keyword), ["Light", "Medium", "Normal", "Dark"])
        XCTAssertEqual(dark.queueDefault, "Normal")
        XCTAssertEqual(all.first { $0.key == "Resolution" }?.queueDefault, "300dpi")
    }

    func testLpinfoBlocks() {
        let models = """
        Model:  name = drv:///sample.drv/dymo.ppd
                natural_language = en
                make-and-model = DYMO Label Printer
                device-id =
        Model:  name = Library/Printers/PPDs/Contents/Resources/DYMO LabelWriter 4XL.PPD
                natural_language = en
                make-and-model = DYMO LabelWriter 4XL
                device-id = MFG:DYMO;MDL:LabelWriter 4XL;
        """
        let d = Parsers.drivers(models)
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d[1].name, "Library/Printers/PPDs/Contents/Resources/DYMO LabelWriter 4XL.PPD")
        XCTAssertEqual(d[1].deviceID, "MFG:DYMO;MDL:LabelWriter 4XL;")

        let devs = Parsers.devices("""
        Device: uri = socket
                class = network
                info = AppSocket/HP JetDirect
                make-and-model = Unknown
                device-id =
                location =
        Device: uri = usb://DYMO/LabelWriter%204XL?serial=17032316350921
                class = direct
                info = DYMO LabelWriter 4XL
                make-and-model = DYMO LabelWriter 4XL
                device-id = MFG:DYMO;CMD: ;MDL:LabelWriter 4XL;CLS:PRINTER;
                location =
        """).filter(\.isConcrete)
        XCTAssertEqual(devs.count, 1)
        XCTAssertEqual(devs[0].info, "DYMO LabelWriter 4XL")
    }

    func testCupsctl() throws {
        let s = Parsers.cupsctl(try fixture("cupsctl.txt"))
        XCTAssertFalse(s.sharePrinters)
        XCTAssertFalse(s.debugLogging)
        XCTAssertEqual(s.errorPolicy, "retry-job")
    }

    func testShellQuotingAndSplitting() {
        XCTAssertEqual(Shell.quote(["lpadmin", "-p", "DYMO_4XL", "-D", "Bob's printer"]),
                       "lpadmin -p DYMO_4XL -D 'Bob'\\''s printer'")
        XCTAssertEqual(Shell.split(#"lpadmin -p X -D "Front desk" -L 'Shelf 2' -o a=b\ c"#),
                       ["lpadmin", "-p", "X", "-D", "Front desk", "-L", "Shelf 2", "-o", "a=b c"])
        XCTAssertEqual(Shell.appleScriptString(#"say "hi" \ there"#), #""say \"hi\" \\ there""#)
    }

    func testQueueNameAndArguments() {
        XCTAssertEqual(CupsClient.sanitizeQueueName("DYMO LabelWriter 4XL #2"), "DYMO_LabelWriter_4XL_2")
        var n = CupsClient.NewPrinter(name: "Zebra", deviceURI: "socket://10.0.0.20:9100", driver: .model("everywhere"))
        n.info = "Zebra ZD421"
        XCTAssertEqual(CupsClient.addArguments(n),
                       ["-p", "Zebra", "-E", "-v", "socket://10.0.0.20:9100", "-m", "everywhere",
                        "-D", "Zebra ZD421", "-o", "printer-is-shared=false"])
        XCTAssertEqual(CupsClient.setOptionArguments("Z", ["b": "2", "a": "1"]), ["-p", "Z", "-o", "a=1", "-o", "b=2"])
    }
    // MARK: Twin Turbo rolls

    func testTwinTurboRolls() throws {
        let groups = Parsers.ppd(try fixture("dymo_twin_turbo.ppd"))
        let opts = PrinterOptions(groups: groups, source: "PPD file", ppdText: nil)
        XCTAssertEqual(opts.rollSlots.map(\.keyword), ["Left", "Right"])
        XCTAssertEqual(opts.rollSlots.map(\.label), ["Left Roll", "Right Roll"])
        XCTAssertEqual(opts.queueDefault("InputSlot"), "Auto")
        XCTAssertEqual(opts.queueDefault("PageSize"), "w167h288")
        XCTAssertEqual(opts.pageSizeOption?.choices.first?.label, "11351 Jewelry Label")
        XCTAssertNil(opts.all.first { $0.key == "InputSlot" }?.choices.first { $0.keyword.hasPrefix("de.") })

        let single = PrinterOptions(groups: Parsers.ppd(try fixture("dymo.ppd")), source: "", ppdText: nil)
        // The CUPS sample DYMO driver also covers the Twin (Roll / Roll2).
        XCTAssertEqual(single.rollSlots.map(\.keyword), ["Roll", "Roll2"])
        let none = PrinterOptions(groups: Parsers.ppd(try fixture("dymo.ppd")).map { g in
            OptionGroup(name: g.name, label: g.label, options: g.options.filter { $0.key != "InputSlot" })
        }, source: "", ppdText: nil)
        XCTAssertTrue(none.rollSlots.isEmpty)
    }

    func testLockedPPDOffersOnlyItsRoll() throws {
        let original = try fixture("dymo_twin_turbo.ppd")
        let locked = CupsClient.lockedPPD(original, slot: "Left")
        let opts = PrinterOptions(groups: Parsers.ppd(locked), source: "", ppdText: locked)
        let input = try XCTUnwrap(opts.all.first { $0.key == "InputSlot" })
        XCTAssertEqual(input.choices.map(\.keyword), ["Left"])
        XCTAssertEqual(input.queueDefault, "Left")
        XCTAssertEqual(opts.lockedRoll, "Left")
        XCTAssertTrue(opts.rollSlots.isEmpty, "a locked roll printer doesn't get its own Rolls tab")
        XCTAssertFalse(locked.contains("*InputSlot Right"))
        XCTAssertFalse(locked.contains("*InputSlot Auto"))
        XCTAssertFalse(locked.contains("*de.InputSlot Right"), "translations of removed choices go too")
        XCTAssertTrue(locked.contains("*de.InputSlot Left/Linke Etikettenrolle"))
        XCTAssertTrue(locked.contains("*de.Translation InputSlot/Papierquelle"))
        // Everything else is untouched.
        let before = PrinterOptions(groups: Parsers.ppd(original), source: "", ppdText: original)
        XCTAssertEqual(opts.pageSizeOption?.choices.count, before.pageSizeOption?.choices.count)
        XCTAssertEqual(opts.all.count, before.all.count)
        XCTAssertEqual(original.components(separatedBy: "\n").count - locked.components(separatedBy: "\n").count,
                       original.components(separatedBy: "\n").filter { $0.contains("InputSlot Auto") || $0.contains("InputSlot Right") }.count,
                       "only the other rolls' lines are removed")
        XCTAssertNil(before.lockedRoll, "the original Twin Turbo isn't locked")

        let right = CupsClient.lockedPPD(original, slot: "Right")
        XCTAssertEqual(PrinterOptions(groups: Parsers.ppd(right), source: "", ppdText: right).lockedRoll, "Right")
    }

    func testLockedPPDHandlesMultiLineValuesAndConstraints() {
        let ppd = """
        *PPD-Adobe: "4.3"
        *UIConstraints: *InputSlot Right *PageSize w79h252
        *UIConstraints: *InputSlot Left *PageSize w79h252
        *OpenUI *InputSlot/Media Source: PickOne
        *DefaultInputSlot: Auto
        *InputSlot Auto/Auto: "<</cupsMediaPosition 0>>setpagedevice"
        *InputSlot Left/Left Roll: "<</cupsMediaPosition 1>>setpagedevice"
        *InputSlot Right/Right Roll: "<<
          /cupsMediaPosition 2
        >>setpagedevice"
        *End
        *CloseUI: *InputSlot
        """
        let locked = CupsClient.lockedPPD(ppd, slot: "Left")
        XCTAssertFalse(locked.contains("cupsMediaPosition 2"), "multi-line value of a removed choice is skipped")
        XCTAssertFalse(locked.contains("*End"), "and its *End line")
        XCTAssertFalse(locked.contains("*InputSlot Right *PageSize"), "constraint naming a removed choice is dropped")
        XCTAssertTrue(locked.contains("*UIConstraints: *InputSlot Left *PageSize w79h252"))
        XCTAssertTrue(locked.contains("*DefaultInputSlot: Left"))
        XCTAssertTrue(locked.contains("*CloseUI: *InputSlot"))
        XCTAssertEqual(Parsers.ppd(locked).flatMap(\.options).first { $0.key == "InputSlot" }?.choices.map(\.keyword), ["Left"])
    }

    func testMatchesRollPrintersByNameNotByTheirCurrentDefault() {
        let left = RollSlot(keyword: "Left", label: "Left Roll"), right = RollSlot(keyword: "Right", label: "Right Roll")
        let slots = [left, right]
        // After DYMO Connect, both roll printers' defaults read "Left" (or Auto).
        let queues = [
            RollQueue(name: "DYMO_LabelWriter_450_Twin_Turbo", info: "DYMO LabelWriter 450 Twin Turbo", slot: "Left", pageSize: nil),
            RollQueue(name: "DYMO_Mini", info: "DYMO Mini (Left Roll)", slot: "Auto", pageSize: nil, isSelf: true),
            RollQueue(name: "DYMO_Inventory", info: "DYMO Inventory (Right Roll)", slot: "Left", pageSize: nil),
        ]
        XCTAssertEqual(CupsClient.matchRollQueue(left, allSlots: slots, in: queues)?.name, "DYMO_Mini")
        XCTAssertEqual(CupsClient.matchRollQueue(right, allSlots: slots, in: queues)?.name, "DYMO_Inventory")

        // A locked printer wins, whatever it's called; the main printer is never picked.
        let locked = queues + [RollQueue(name: "Labels", info: "Labels", slot: "Right", pageSize: nil, locked: true)]
        XCTAssertEqual(CupsClient.matchRollQueue(right, allSlots: slots, in: locked)?.name, "Labels")
        XCTAssertNil(CupsClient.matchRollQueue(left, allSlots: slots, in: [queues[0]]))
        // "(Left)" counts; a name mentioning both rolls doesn't.
        XCTAssertEqual(CupsClient.matchRollQueue(left, allSlots: slots,
                       in: [RollQueue(name: "X", info: "DYMO Mail (Left)", slot: nil, pageSize: nil)])?.name, "X")
        XCTAssertNil(CupsClient.matchRollQueue(left, allSlots: slots,
                     in: [RollQueue(name: "X", info: "Left Roll and Right Roll", slot: nil, pageSize: nil)]))
    }

    func testOfficeTraysAreNotRolls() {
        var input = PrinterOption(key: "InputSlot", label: "Paper Source")
        input.choices = [
            OptionChoice(keyword: "AutoSelect", label: "Auto Select"),
            OptionChoice(keyword: "Tray1", label: "Tray 1"),
            OptionChoice(keyword: "Tray2", label: "Tray 2"),
            OptionChoice(keyword: "MPTray", label: "MP Tray"),
            OptionChoice(keyword: "Manual", label: "Manual Feed"),
        ]
        let brother = PrinterOptions(groups: [OptionGroup(name: "General", label: "General", options: [input])],
                                     source: "", ppdText: nil)
        XCTAssertTrue(brother.rollSlots.isEmpty, "A Brother laser's trays must not show the Rolls tab")
    }

    func testRollQueueHelpers() {
        var base = Printer(name: "DYMO_Twin")
        base.makeAndModel = "DYMO LabelWriter 450 Twin Turbo"
        base.deviceURI = "usb://DYMO/LabelWriter%20450%20Twin%20Turbo?serial=1"
        var left = Printer(name: "DYMO_Inventory"); left.deviceURI = base.deviceURI + "/"
        var other = Printer(name: "Zebra"); other.deviceURI = "socket://10.0.0.20:9100"
        XCTAssertEqual(CupsClient.siblings(of: base, in: [base, left, other]).map(\.name), ["DYMO_Inventory"])

        let slot = RollSlot(keyword: "Left", label: "Left Roll")
        XCTAssertEqual(CupsClient.suggestedRollQueueName(base: base, labelName: "Inventory", slot: slot), "DYMO_Inventory")
        XCTAssertEqual(CupsClient.rollOptionArguments("DYMO_Inventory", info: "DYMO Inventory (Left Roll)", slot: "Left", pageSize: "w79h252"),
                       ["-p", "DYMO_Inventory", "-D", "DYMO Inventory (Left Roll)", "-o", "InputSlot=Left", "-o", "PageSize=w79h252"])
    }
}
