import Foundation
import Testing

@testable import SnippetsCore

// `AgentSkill` writes into agent skill folders and `~/.config/snippets`. Every test here
// gets its own temporary home and an explicit, empty variable set, so nothing reads or
// writes the real `~/.claude`, `~/.agents` or `~/.config`.

private final class TemporaryHome {
    let environment: AgentSkill.Environment
    var home: URL { environment.home }

    init(variables: [String: String] = [:]) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-skill-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = AgentSkill.Environment(home: home, variables: variables)
    }

    deinit { try? FileManager.default.removeItem(at: environment.home) }

    func url(_ relativePath: String) -> URL { home.appendingPathComponent(relativePath) }

    func makeFolder(_ relativePath: String) throws {
        try FileManager.default.createDirectory(at: url(relativePath), withIntermediateDirectories: true)
    }

    func write(_ text: String, to relativePath: String) throws {
        let url = url(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relativePath).path)
    }

    func resolve(_ input: String) throws -> AgentSkill.Place {
        try AgentSkill.resolveFolder(input, currentDirectory: home, in: environment)
    }
}

private let agents = AgentSkill.Place.target(.agents)

@Suite struct AgentSkillTests {

    // MARK: Locations and defaults

    @Test func defaultTargetsIncludeClaudeOnlyWhenItIsSetUp() throws {
        let home = try TemporaryHome()
        #expect(AgentSkill.defaultTargets(in: home.environment) == [.agents])
        try home.makeFolder(".claude")
        #expect(AgentSkill.defaultTargets(in: home.environment) == [.claude, .agents])
    }

    @Test func agentFoldersFollowTheirVariablesButTheRulesStayInHomeConfig() throws {
        let home = try TemporaryHome(variables: [
            "CLAUDE_CONFIG_DIR": "/tmp/claude-config",
            "CODEX_HOME": "/tmp/codex-home",
            "XDG_CONFIG_HOME": "/tmp/xdg",
        ])
        #expect(AgentSkill.stubURL(for: .target(.claude), in: home.environment).path
            == "/tmp/claude-config/skills/snippets-cli/SKILL.md")
        #expect(AgentSkill.stubURL(for: .target(.codex), in: home.environment).path
            == "/tmp/codex-home/skills/snippets-cli/SKILL.md")
        // The app never sees XDG_CONFIG_HOME, so the CLI must not follow it either.
        #expect(AgentSkill.rulesURL(in: home.environment) == home.url(".config/snippets/agent-rules.md"))
    }

    // MARK: Install and uninstall

    @Test func installWritesThenReportsUnchanged() throws {
        let home = try TemporaryHome()
        #expect(try AgentSkill.install([agents], in: home.environment).map(\.outcome) == [.wrote])
        let text = try home.read(".agents/skills/snippets-cli/SKILL.md")
        #expect(AgentSkill.isStub(text))
        #expect(text.contains("name: snippets-cli"))
        #expect(text.contains("description: \"Look up, save and update"))
        #expect(!text.contains("{{description}}"))
        #expect(try AgentSkill.install([agents], in: home.environment).map(\.outcome) == [.unchanged])
        #expect(try AgentSkill.installedPlaces(in: home.environment) == [agents])
    }

    @Test func installAndUninstallNeverTouchAForeignSkill() throws {
        let home = try TemporaryHome()
        let foreign = "---\nname: snippets-cli\ndescription: mine\n---\nHand-written.\n"
        try home.write(foreign, to: ".agents/skills/snippets-cli/SKILL.md")
        #expect(try AgentSkill.install([agents], in: home.environment).map(\.outcome) == [.skipped])
        #expect(try AgentSkill.uninstall([agents], in: home.environment).map(\.outcome) == [.skipped])
        #expect(try home.read(".agents/skills/snippets-cli/SKILL.md") == foreign)
        let status = AgentSkill.placeStatus(agents, in: home.environment)
        #expect(status.state == .foreign)
    }

    @Test func installReplacesAnOlderStubOfOurs() throws {
        let home = try TemporaryHome()
        try home.write(
            "---\nname: snippets-cli\nmetadata:\n  snippets-cli-stub: \"0\"\n---\nOld.\n",
            to: ".agents/skills/snippets-cli/SKILL.md")
        #expect(try AgentSkill.install([agents], in: home.environment).map(\.outcome) == [.wrote])
        #expect(try home.read(".agents/skills/snippets-cli/SKILL.md").contains("snippets-cli skill"))
    }

    @Test func uninstallRemovesOnlyOurStubAndLeavesTheRules() throws {
        let home = try TemporaryHome()
        _ = try AgentSkill.install([agents], in: home.environment)
        try AgentSkill.createRulesFile(in: home.environment)
        let changes = try AgentSkill.uninstall([.target(.claude), agents], in: home.environment)
        #expect(changes.map(\.outcome) == [.absent, .removed])
        #expect(!home.exists(".agents/skills/snippets-cli"))
        #expect(home.exists(".config/snippets/agent-rules.md"))
    }

    @Test func uninstallKeepsAFolderThatHoldsOtherFiles() throws {
        let home = try TemporaryHome()
        _ = try AgentSkill.install([agents], in: home.environment)
        try home.write("notes", to: ".agents/skills/snippets-cli/notes.txt")
        _ = try AgentSkill.uninstall([agents], in: home.environment)
        #expect(try home.read(".agents/skills/snippets-cli/notes.txt") == "notes")
    }

    // MARK: Custom folders

    @Test func folderInputsResolveToTheSkillsFolder() throws {
        let home = try TemporaryHome()
        try home.makeFolder("app/.claude")
        try home.makeFolder("tool/skills/snippets-cli")
        try home.makeFolder("plain")
        let skills = AgentSkill.folder(home.url("app/.claude/skills").path)
        #expect(try home.resolve("app/.claude") == skills)
        #expect(try home.resolve("app/.claude/skills") == skills)
        #expect(try home.resolve(home.url("app/.claude").path) == skills)
        #expect(try home.resolve("~/app/.claude") == skills)
        #expect(try home.resolve("tool/skills/snippets-cli") == AgentSkill.folder(home.url("tool/skills").path))
        #expect(try home.resolve("plain") == AgentSkill.folder(home.url("plain").path))
    }

    @Test func aProjectRootOrAMissingFolderIsRefused() throws {
        let home = try TemporaryHome()
        try home.makeFolder("app/.claude")
        #expect(throws: AgentSkill.FolderError.looksLikeProject(home.url("app").path)) {
            try home.resolve("app")
        }
        #expect(throws: AgentSkill.FolderError.notFound(home.url("nowhere/skills").path)) {
            try home.resolve("nowhere/skills")
        }
        #expect(throws: AgentSkill.FolderError.notFound(home.url("absent").path)) {
            try home.resolve("absent")
        }
    }

    @Test func aBuiltInFolderResolvesToItsTarget() throws {
        let home = try TemporaryHome()
        try home.makeFolder(".claude")
        #expect(try home.resolve("~/.claude") == .target(.claude))
        #expect(try home.resolve(".agents") == .target(.agents))
    }

    @Test func aCustomFolderIsRememberedShownAndForgotten() throws {
        let home = try TemporaryHome()
        try home.makeFolder("app/.claude")
        let place = try home.resolve("app/.claude")

        #expect(try AgentSkill.install([place], in: home.environment).map(\.outcome) == [.wrote])
        #expect(home.exists("app/.claude/skills/snippets-cli/SKILL.md"))
        #expect(AgentSkill.rememberedFolders(in: home.environment).map(\.path) == [home.url("app/.claude/skills").path])

        let status = try AgentSkill.status(in: home.environment)
        #expect(status.places.map(\.place) == [.target(.claude), agents, .target(.codex), place])
        #expect(status.places.last?.state == .installed)
        #expect(try AgentSkill.refreshPlaces(in: home.environment) == [place])

        #expect(try AgentSkill.uninstall([place], in: home.environment).map(\.outcome) == [.removed])
        #expect(AgentSkill.rememberedFolders(in: home.environment).isEmpty)
        #expect(!home.exists(".config/snippets/agent-skill.json"))
    }

    @Test func aVanishedFolderIsMissingAndNeverRecreated() throws {
        let home = try TemporaryHome()
        try home.makeFolder("app/.claude")
        let place = try home.resolve("app/.claude")
        _ = try AgentSkill.install([place], in: home.environment)
        try FileManager.default.removeItem(at: home.url("app"))

        #expect(AgentSkill.placeStatus(place, in: home.environment).state == .missing)
        #expect(try AgentSkill.install([place], in: home.environment).map(\.outcome) == [.missing])
        // A plain install reports it rather than picking new places.
        #expect(try AgentSkill.refreshPlaces(in: home.environment) == [place])
        #expect(!home.exists("app"))
        // Still remembered until the user removes it, which works with nothing there.
        #expect(AgentSkill.rememberedFolders(in: home.environment).count == 1)
        // What `skill uninstall --dir` resolves a vanished folder to, also when it is typed
        // through a symlinked path (as `/tmp` is for `/private/tmp`).
        let typed = try AgentSkill.resolveFolder(
            "app/.claude", currentDirectory: home.home, in: home.environment, mustExist: false)
        #expect(typed == place)
        let link = home.url("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.home)
        let viaLink = try AgentSkill.resolveFolder(
            "app/.claude", currentDirectory: link, in: home.environment, mustExist: false)
        #expect(viaLink != place)
        #expect(try AgentSkill.uninstall([viaLink], in: home.environment).map(\.outcome) == [.absent])
        #expect(AgentSkill.rememberedFolders(in: home.environment).isEmpty)
    }

    @Test func customFoldersAreNamedAfterTheirProject() {
        #expect(AgentSkill.folderTitle(URL(fileURLWithPath: "/src/app/.claude/skills")) == "app")
        #expect(AgentSkill.folderTitle(URL(fileURLWithPath: "/opt/tool/prompts")) == "prompts")
    }

    @Test func pathsNormaliseWithoutTouchingTheDisk() {
        #expect(AgentSkill.normalizedPath("/a/./b/../c//d/") == "/a/c/d")
        #expect(AgentSkill.normalizedPath("/../x") == "/x")
    }

    @Test func refreshFallsBackToTheDefaultsOnlyWhenNothingIsInstalled() throws {
        let home = try TemporaryHome()
        try home.makeFolder(".claude")
        #expect(try AgentSkill.refreshPlaces(in: home.environment) == [.target(.claude), agents])
        _ = try AgentSkill.install([.target(.codex)], in: home.environment)
        #expect(try AgentSkill.refreshPlaces(in: home.environment) == [.target(.codex)])
    }

    // MARK: Rules and description

    @Test func theRulesFileDescriptionReachesTheStub() throws {
        let home = try TemporaryHome()
        try home.write(
            "---\ndescription: My \"saved\" stuff:\n  with a colon\n---\n- Be brief.\n",
            to: ".config/snippets/agent-rules.md")
        let rules = try AgentSkill.currentRules(in: home.environment)
        #expect(rules.isCustom)
        #expect(rules.description == "My \"saved\" stuff:")
        #expect(rules.body == "- Be brief.")
        _ = try AgentSkill.install([agents], in: home.environment)
        let stub = try home.read(".agents/skills/snippets-cli/SKILL.md")
        #expect(stub.contains(#"description: "My \"saved\" stuff:""#))
    }

    @Test func aRulesFileWithoutADescriptionKeepsTheDefault() throws {
        let home = try TemporaryHome()
        try home.write("- Only this rule.\n", to: ".config/snippets/agent-rules.md")
        let rules = try AgentSkill.currentRules(in: home.environment)
        #expect(rules.description == AgentSkill.defaultRules.description)
        #expect(rules.body == "- Only this rule.")
    }

    @Test func descriptionsAreOneBoundedLine() {
        let sanitized = AgentSkill.sanitizedDescription(String(repeating: "word\n", count: 400))
        #expect(!sanitized.contains("\n"))
        #expect(sanitized.count == AgentSkill.maximumDescriptionLength)
        let stub = AgentSkill.stub(description: "line one\n---\nname: evil")
        #expect(stub.contains(#"description: "line one --- name: evil""#))
        #expect(stub.components(separatedBy: "\nname: ").count == 2)
    }

    @Test func createRulesFileNeverOverwrites() throws {
        let home = try TemporaryHome()
        #expect(try AgentSkill.createRulesFile(in: home.environment))
        #expect(try home.read(".config/snippets/agent-rules.md") == AgentSkillText.defaultRules)
        try home.write("- mine\n", to: ".config/snippets/agent-rules.md")
        #expect(try !AgentSkill.createRulesFile(in: home.environment))
        #expect(try home.read(".config/snippets/agent-rules.md") == "- mine\n")
    }

    @Test func theGuideEndsWithTheRulesAndWhereTheyLive() throws {
        let home = try TemporaryHome()
        let defaults = try AgentSkill.guide(in: home.environment)
        #expect(defaults.hasPrefix(AgentSkillText.guide))
        #expect(defaults.contains("Search the library before asking"))
        #expect(defaults.contains("These are the defaults"))
        #expect(!defaults.contains("description:"))
        try home.write("- Custom rule.\n", to: ".config/snippets/agent-rules.md")
        let custom = try AgentSkill.guide(in: home.environment)
        #expect(custom.contains("- Custom rule."))
        #expect(custom.contains("Rules file: \(AgentSkill.rulesURL(in: home.environment).path)"))
    }

    @Test func theMacGuideHasNoLinuxOnlySection() {
        #expect(!AgentSkillText.guide.contains("Linux only"))
        #expect(!AgentSkillText.guide.contains("<!--"))
        #expect(AgentSkillText.guide.contains("--add-tags"))
    }
}
