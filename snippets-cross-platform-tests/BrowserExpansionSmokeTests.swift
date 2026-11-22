#if os(macOS)
import AppKit
import ApplicationServices
import XCTest
@testable import Snippets_Debug

/// Run the foreground fixtures with scripts/test-browser-expansion.sh.
@MainActor
final class BrowserExpansionSmokeTests: XCTestCase {
    private struct Scenario: Encodable {
        var surface = "search"
        var prefix = "prefix 😀 "
        var query = "fi"
        var selected = ""
        var direction = "none"
        var entireField = false
        var cancelPaste = false
        var limited = false
        var rewrite = false
        var interrupt = false
    }

    func testSearchExpansionAndPasswordHistoryPasteInChrome() async throws {
        try await exerciseBrowser(.chrome)
    }

    func testSearchExpansionAndPasswordHistoryPasteInWebKit() async throws {
        guard let host = ProcessInfo.processInfo.environment["SNIPPETS_WEBKIT_TEST_HOST"] else {
            throw XCTSkip("Set TEST_RUNNER_SNIPPETS_WEBKIT_TEST_HOST to the compiled WebKit fixture")
        }
        try await exerciseBrowser(.webKit(URL(fileURLWithPath: host)))
    }

    func testSearchExpansionAndPasswordHistoryPasteInSafari() async throws {
        try await exerciseBrowser(.safari)
    }

    func testExpansionAndHistoryInElectron() async throws {
        try await exerciseBrowser(.electron)
    }

    private enum Browser: Equatable { case chrome, electron, safari, webKit(URL) }

    private func exerciseBrowser(_ browser: Browser) async throws {
        try DesktopExpansionFixture.requireAccess()
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["SNIPPETS_BROWSER_FIXTURE_ROOT"])
        let directory = URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = "snippets-\(UUID().uuidString)-"
        let fixture = directory.appendingPathComponent("fixture.html")
        let replacement = "fixture expansion with a long common suffix for confirmation"
        let scenarios = [
            Scenario(query: ""), Scenario(),
            Scenario(selected: "😀x", direction: "forward"), Scenario(selected: "😀x", direction: "backward"),
            Scenario(query: "fixture"), Scenario(selected: String(repeating: "x", count: 160), entireField: true),
            Scenario(surface: "text", prefix: "кириллица 🧑🏽‍💻 "),
            Scenario(surface: "area", prefix: "first line\nsecond ✨ ", selected: "e\u{301}", direction: "backward"),
            Scenario(surface: "rich", prefix: "café 🐝 "),
            Scenario(surface: "url", prefix: ""), Scenario(surface: "tel", prefix: "номер "),
            Scenario(surface: "shadow", prefix: "inside "), Scenario(surface: "text", limited: true),
            Scenario(cancelPaste: true), Scenario(rewrite: true), Scenario(interrupt: true)
        ]
        let loadingSearch = browser == .chrome
        let casesJSON = String(decoding: try JSONEncoder().encode(scenarios), as: UTF8.self)
        try """
            <!doctype html><meta charset=utf-8><title>starting</title>
            <input type=search id=search placeholder="Search Site…"><input id=text><textarea id=area></textarea>
            <input id=url type=url><input id=tel type=tel><div id=shadowHost></div>
            <div id=rich contenteditable=true role=textbox></div><input type=password id=p><input id=b><input id=lockedField><input id=lateField>
            <script>
            const token='\(token)', suffix=' tail', replacement='\(replacement)';
            const state=name=>document.title=token+name;
            window.onerror=(_,file,line)=>state('fixture-error-line-'+line);
            const cases=\(casesJSON);
            const shadowRoot=shadowHost.attachShadow({mode:'open'});
            const shadow=document.createElement('input'); shadowRoot.append(shadow);
            let index=0, edits, keys, start, end, initial, field;
            function value() { return field.isContentEditable ? field.textContent : field.value }
            function selection() {
                if (!field.isContentEditable) return [field.selectionStart,field.selectionEnd];
                const sel=getSelection();
                if (!sel.rangeCount || !field.contains(sel.anchorNode)) return [-1,-1];
                const r=sel.getRangeAt(0);
                const before=r.cloneRange(); before.selectNodeContents(field); before.setEnd(r.startContainer,r.startOffset);
                return [before.toString().length,before.toString().length+r.toString().length];
            }
            function select(a,b,direction) {
                if (!field.isContentEditable) { field.setSelectionRange(a,b,direction); return }
                const node=field.firstChild;
                getSelection().setBaseAndExtent(node,direction==='backward'?b:a,node,direction==='backward'?a:b);
            }
            function prepare() {
                const c=cases[index], trigger=String.fromCharCode(92)+c.query;
                const leading=c.entireField ? '' : c.prefix, trailing=c.entireField ? '' : suffix;
                field=c.surface==='shadow'?shadow:document.getElementById(c.surface);
                field.removeAttribute('maxlength');
                initial=leading+trigger+c.selected+trailing;
                if (field.isContentEditable) field.textContent=initial; else field.value=initial;
                if(c.limited) field.maxLength=(leading+'fixture'+trailing).length;
                field.focus();
                start=(leading+trigger).length;
                end=start+c.selected.length;
                select(start,end,c.direction);
                edits=0; keys=0;
                state('case-'+index+'-ready');
            }
            function finish() {
                if (++index < cases.length) prepare();
                else { p.focus(); state('password-ready') }
            }
            document.addEventListener('keydown',e=>{
                if(e.composedPath()[0]!==field || index>=cases.length) return;
                if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase()==='a') keys++;
                if (e.key!=='ArrowLeft' && e.key!=='ArrowRight') return;
                keys++;
                if (cases[index].interrupt && keys===2) {
                    e.preventDefault(); b.focus();
                    setTimeout(()=>{if(edits===0 && value()===initial && b.value==='') finish()},600);
                }
            });
            // Model a renderer that accepts an AX selection request without applying it.
            document.addEventListener('selectionchange', ()=>{
                if (index>=cases.length || keys || cases[index].entireField || (shadowRoot.activeElement || document.activeElement)!==field) return;
                const [a,b]=selection();
                if(a!==start || b!==end) select(start,end,cases[index].direction);
            }, true);
            let pasteAttempts=0;
            document.addEventListener('paste',e=>{
                if (index>=cases.length || !cases[index].cancelPaste || e.target!==field) return;
                e.preventDefault();
                if (++pasteAttempts!==1) { state('duplicate-paste'); return }
                setTimeout(()=>{
                    if(pasteAttempts===1 && edits===0 && value()===initial && b.value==='') finish();
                },1700);
            });
            document.addEventListener('input',e=>{
                if(e.composedPath()[0]!==field || index>=cases.length) return;
                edits++;
                const c=cases[index], leading=c.entireField?'':c.prefix, trailing=c.entireField?'':suffix;
                if (c.rewrite) {
                    const caret=selection()[0];
                    field.value=field.value.replace('fixture expansion','altered expansion');
                    select(caret,caret,'none');
                }
                setTimeout(()=>{
                    const inserted=c.limited?'fixture':c.rewrite?replacement.replace('fixture','altered'):replacement;
                    const [a,z]=selection();
                    if (!c.interrupt && edits===1 && value()===leading+inserted+trailing && b.value==='' &&
                        a===leading.length+inserted.length && z===a) finish();
                    else state('case-'+index+'-incorrect-result');
                },c.rewrite || c.limited ? 1700 : 400);
            });
            let passwordEdits=0, areaEdits=0, lockedEdits=0;
            const lockedInitial='guard '+String.fromCharCode(92)+'fixture';
            lockedField.oninput=()=>lockedEdits++;
            lockedField.onkeydown=e=>{
                if(e.key==='F15'){
                    e.preventDefault();
                    if(lockedEdits===0 && lockedField.value===lockedInitial && b.value==='' &&
                       document.activeElement===lockedField && lockedField.readOnly) state('readonly-passed');
                }
            };
            const incomplete=String.fromCharCode(92)+'fixtur', complete=incomplete+'e';
            let lateStage=0, lateEdits=0;
            lateField.oninput=()=>{
                lateEdits++;
                if(lateStage===2) setTimeout(()=>{
                    if(lateEdits===1 && lateField.value===replacement && b.value===complete &&
                       lateField.selectionStart===replacement.length && lateField.selectionEnd===replacement.length)
                        state('late-passed');
                },400);
            };
            // F16 drives fixture state outside Snippets' keyboard callback. In phase
            // one another field already contains the full trigger. In phase two the
            // original editor publishes the completed word after the key was delivered.
            document.addEventListener('keydown',e=>{
                if(e.key!=='F16') return;
                e.preventDefault();
                if(lateStage===0){
                    b.value=complete; lateField.value=incomplete; lateField.focus();
                    lateField.setSelectionRange(incomplete.length,incomplete.length);
                    lateStage=1; state('late-switch-ready');
                } else if(lateStage===1 && e.target===lateField){
                    b.focus(); b.setSelectionRange(complete.length,complete.length);
                    setTimeout(()=>{
                        if(lateEdits!==0 || b.value!==complete || lateField.value!==incomplete) return;
                        lateField.focus(); lateField.setSelectionRange(incomplete.length,incomplete.length);
                        lateStage=2; state('late-original-ready');
                    },500);
                } else if(lateStage===2 && e.target===lateField){
                    setTimeout(()=>{
                        lateField.value=complete; lateField.setSelectionRange(complete.length,complete.length);
                    },80);
                }
            });
            p.oninput=()=>{
                if(++passwordEdits!==1 || p.value!=='fixture history' || b.value!=='') return;
                const area=document.getElementById('area');
                area.value='first 🐝 old tail'; area.focus();
                const start='first 🐝 '.length;
                area.setSelectionRange(start,start+3,'backward');
                area.oninput=()=>{
                    const payload='строка\\n🌻';
                    if(++areaEdits===1 && area.value==='first 🐝 '+payload+' tail' &&
                       area.selectionStart===start+payload.length && area.selectionEnd===area.selectionStart &&
                       p.value==='fixture history' && b.value==='') {
                        lockedField.value=lockedInitial;
                        lockedField.focus();
                        lockedField.setSelectionRange(lockedInitial.length,lockedInitial.length);
                        lockedField.readOnly=true;
                        state('readonly-ready');
                    }
                };
                state('history-area-ready');
            };
            // An unfinished child document keeps Chromium serving its old AX snapshot
            // after Shift-Left has already changed the DOM selection. No network needed.
            const loadingFrame = \(loadingSearch) ? document.createElement('iframe') : null;
            if (loadingFrame) {
                document.body.appendChild(loadingFrame);
                loadingFrame.contentDocument.open();
                loadingFrame.contentDocument.write('loading');
                const search = document.getElementById('search');
                search.focus();
                let pastes = 0;
                const prefix = 'keep 🐝 ', suffix = ' tail';
                search.onpaste = () => { pastes++ };
                search.oninput = event => {
                    if (event.inputType !== 'insertFromPaste') return;
                    const first = pastes === 1;
                    const caret = (first ? 0 : prefix.length) + replacement.length;
                    if (document.readyState === 'complete' || pastes > 2 ||
                        search.value !== (first ? replacement : prefix + replacement + suffix) ||
                        search.selectionStart !== caret || search.selectionEnd !== caret) {
                        state('incorrect-loading-paste'); return;
                    }
                    if (first) {
                        setTimeout(() => {
                            search.value = prefix + suffix;
                            search.setSelectionRange(prefix.length, prefix.length);
                            state('loading-tab-ready');
                        }, 400);
                    } else {
                        setTimeout(() => {
                            search.value = '';
                            state('loading-cancel-ready');
                            // Hold the last printable until after Tab. Another user key
                            // cancels that pick even if the original word then appears.
                            search.onkeydown = e => {
                                if (e.key === 'q') e.preventDefault();
                                if (e.key !== 'x') return;
                                e.preventDefault();
                                search.value = String.fromCharCode(92) + 'zq';
                                setTimeout(() => {
                                    if (pastes !== 2 || search.value !== String.fromCharCode(92) + 'zq') {
                                        state('unexpected-delayed-paste'); return;
                                    }
                                    search.onkeydown = search.oninput = search.onpaste = null;
                                    loadingFrame.contentDocument.close();
                                    prepare();
                                }, 500);
                            };
                        }, 400);
                    }
                };
                state('loading-ready');
            } else {
                setTimeout(prepare, 500);
            }
            </script>
            """.write(to: fixture, atomically: true, encoding: .utf8)

        let previousApp = NSWorkspace.shared.frontmostApplication
        let process = Process()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let appInstance: NSRunningApplication
        switch browser {
        case .safari:
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let safari = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"))
            let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari")
            appInstance = try await NSWorkspace.shared.open([fixture], withApplicationAt: safari, configuration: configuration)
            if existing.isEmpty {
                try String(appInstance.processIdentifier).write(to: URL(fileURLWithPath: root).appendingPathComponent("owned-safari-pid"),
                                                               atomically: true, encoding: .utf8)
            }
        case .chrome, .electron:
            let identifier: String
            let application: URL
            let arguments: [String]
            if case .electron = browser {
                identifier = "com.github.Electron"
                if let path = ProcessInfo.processInfo.environment["SNIPPETS_ELECTRON_APP"] {
                    application = URL(fileURLWithPath: path)
                    guard Bundle(url: application)?.bundleIdentifier == identifier else {
                        return XCTFail("Configured path does not point to an Electron runtime")
                    }
                } else if let runtime = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                    application = runtime
                } else { throw XCTSkip("Electron unavailable") }
                // LaunchServices otherwise puts up a system-wide "damaged" alert for
                // a quarantined runtime whose signature Gatekeeper rejects.
                if getxattr(application.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 {
                    let assessment = Process()
                    assessment.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
                    assessment.arguments = ["--assess", "--type", "execute", application.path]
                    assessment.standardOutput = FileHandle.nullDevice
                    assessment.standardError = FileHandle.nullDevice
                    try assessment.run()
                    assessment.waitUntilExit()
                    try XCTSkipUnless(assessment.terminationStatus == 0,
                        "macOS rejected the quarantined Electron runtime. Select a runnable copy with TEST_RUNNER_SNIPPETS_ELECTRON_APP.")
                }
                let main = directory.appendingPathComponent("main.js")
                try """
                    const {app,BrowserWindow,Menu}=require('electron');
                    Menu.setApplicationMenu(Menu.buildFromTemplate([{role:'editMenu'}]));
                    let win;
                    app.whenReady().then(()=>{
                        win=new BrowserWindow({webPreferences:{sandbox:true}});
                        win.loadFile(require('path').join(__dirname,'fixture.html'));
                        win.focus();
                    });
                    """.write(to: main, atomically: true, encoding: .utf8)
                arguments = [main.path]
            } else {
                identifier = "com.google.Chrome"
                application = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier))
                arguments = ["--app=\(fixture.absoluteString)"]
            }
            let existing = Set(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).map(\.processIdentifier))
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--user-data-dir=\(directory.path)/profile", "--no-first-run", "--no-default-browser-check",
                "--disable-background-networking", "--use-mock-keychain", "--force-renderer-accessibility"] + arguments
            appInstance = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
            try XCTSkipIf(existing.contains(appInstance.processIdentifier), "Application reused an existing process")
        case .webKit(let host):
            process.executableURL = host
            process.arguments = [fixture.path]
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while NSRunningApplication(processIdentifier: process.processIdentifier) == nil, process.isRunning,
                  ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
            appInstance = try XCTUnwrap(NSRunningApplication(processIdentifier: process.processIdentifier))
        }
        let app = AXUIElementCreateApplication(appInstance.processIdentifier)
        let attribute = DesktopExpansionFixture.attribute
        func fixtureTitle(of window: AXUIElement) -> String? {
            guard let title = attribute(window, "AXTitle") as? String,
                  let marker = title.range(of: token) else { return nil }
            return String(title[marker.upperBound...])
        }
        func fixtureTitle() -> String? {
            guard let window = attribute(app, "AXFocusedWindow"), CFGetTypeID(window) == AXUIElementGetTypeID()
            else { return nil }
            return fixtureTitle(of: window as! AXUIElement)
        }
        func isFrontmost() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == appInstance.processIdentifier
        }
        func closeFixture() async {
            let restorePrevious = isFrontmost()
            // The runner closes Safari tabs by their exact fixture directory, including
            // background tabs and failed cases. Safari can ignore Command-W in a form.
            if restorePrevious { previousApp?.activate() }
            switch browser {
            case .chrome, .electron:
                await DesktopExpansionFixture.closeOwnedInstance(appInstance)
            default: break
            }
        }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        func waitForTitle(_ title: String) async throws {
            for _ in 0..<120 {
                if (title == "case-0-ready" || title == "loading-ready"), fixtureTitle() == nil,
                   let windows = attribute(app, "AXWindows") as? [AXUIElement],
                   let ours = windows.first(where: { fixtureTitle(of: $0) != nil }) {
                    AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, ours)
                    AXUIElementPerformAction(ours, kAXRaiseAction as CFString)
                }
                if fixtureTitle()?.hasPrefix(title) == true {
                    if isFrontmost() { return }
                    // A completed scenario may have lost foreground while the next one was loading.
                    // Only restore it between scenarios and only for this test's focused window.
                    if title.hasPrefix("case-") || title == "loading-ready" {
                        DesktopExpansionFixture.activate(appInstance, app: app)
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw FixtureFailure.missingBrowserState(expected: title, observed: fixtureTitle(), frontmost: isFrontmost())
        }
        func waitForFocusedField(search: Bool = false) async throws -> AXUIElement {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            repeat {
                if let object = attribute(app, "AXFocusedUIElement"), CFGetTypeID(object) == AXUIElementGetTypeID() {
                    let field = object as! AXUIElement
                    if !search || attribute(field, "AXSubrole") as? String == "AXSearchField" { return field }
                }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            throw FixtureFailure.missingBrowserState(expected: "focused field", observed: fixtureTitle(), frontmost: isFrontmost())
        }
        do {
            if loadingSearch {
                try await waitForTitle("loading-ready")
                let field = try await waitForFocusedField(search: true)
                try await DesktopExpansionFixture.withEngine(in: directory.appendingPathComponent("loading"),
                    replacement: replacement, keyword: "zqfixture") { engine in
                    @MainActor func type(_ keys: String, interval: Duration = .milliseconds(40)) async throws {
                        try await DesktopExpansionFixture.typeKeys(keys, to: appInstance, interval: interval) {
                            guard let focused = attribute(app, "AXFocusedUIElement") else { return false }
                            return CFEqual(focused, field)
                        }
                    }
                    try await type("\\zqfixture")
                    try await waitForTitle("loading-tab-ready")
                    XCTAssertEqual(engine.statusText, "Expanded Fixture.")
                    try await type("\\z")
                    try await type("q\t", interval: .milliseconds(1))
                    try await waitForTitle("loading-cancel-ready")
                    XCTAssertEqual(engine.statusText, "Expanded Fixture.")
                    try await type("\\z")
                    try await type("q\tx", interval: .milliseconds(1))
                    try await waitForTitle("case-0-ready")
                }
            }
            try await DesktopExpansionFixture.withEngine(in: directory, replacement: replacement) { engine in
                for (index, scenario) in scenarios.enumerated() {
                    try await waitForTitle("case-\(index)-ready")
                    if index > 0, scenarios[index - 1].rewrite || scenarios[index - 1].cancelPaste || scenarios[index - 1].limited {
                        XCTAssertTrue(engine.statusText.contains("insertion could not be confirmed"),
                                      "A cancelled or rewritten paste must remain unconfirmed")
                    }
                    // A new WKWebView publishes its AX tree asynchronously on the first read.
                    // Start delivery only after the fixture has an actual, focused text field.
                    _ = try await waitForFocusedField()
                    try await DesktopExpansionFixture.expand(query: scenario.query, using: engine)
                }
                try await waitForTitle("password-ready")
                try await pasteFixtureHistory("fixture history", using: engine) { try await waitForTitle("history-area-ready") }
                try await pasteFixtureHistory("строка\n🌻", using: engine) { try await waitForTitle("readonly-ready") }
                try await DesktopExpansionFixture.expand(query: "fixture", using: engine)
                try await Task.sleep(for: .milliseconds(1700))
                guard fixtureTitle()?.hasPrefix("readonly-ready") == true, isFrontmost()
                else { throw FixtureFailure.missingBrowserState(expected: "readonly-ready", observed: fixtureTitle(), frontmost: isFrontmost()) }
                for down in [true, false] {
                    let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 113, keyDown: down))
                    key.postToPid(appInstance.processIdentifier)
                }
                try await waitForTitle("readonly-passed")
                @MainActor func advanceDelayedFixture() throws {
                    guard isFrontmost(), fixtureTitle() != nil else {
                        throw FixtureFailure.missingBrowserState(expected: "fixture focused", observed: nil, frontmost: isFrontmost())
                    }
                    for down in [true, false] {
                        let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 106, keyDown: down))
                        key.postToPid(appInstance.processIdentifier)
                    }
                }
                try advanceDelayedFixture()
                for title in ["late-switch-ready", "late-original-ready"] {
                    try await waitForTitle(title)
                    // Previous scenario may still have an active suggestions panel.
                    let escape = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
                    _ = SnippetExpansionEngine.eventTapCallback(type: .keyDown, event: escape,
                        refcon: Unmanaged.passUnretained(engine.callbackContext).toOpaque())
                    try await DesktopExpansionFixture.expand(query: "fixture", using: engine)
                    try advanceDelayedFixture()
                }
                try await waitForTitle("late-passed")
            }
        } catch {
            await closeFixture()
            throw error
        }
        await closeFixture()
    }

    private enum FixtureFailure: Error { case missingBrowserState(expected: String, observed: String?, frontmost: Bool) }
}
#endif
