import Foundation
import Testing

@testable import JCodeKit

@Test func completionFindsSlashAndAtTokensOnlyAtWordStart() {
    #expect(Completion.token(in: "/gr")?.kind == .slash)
    #expect(Completion.token(in: "/gr")?.query == "gr")
    #expect(Completion.token(in: "fix @Sour")?.kind == .file)
    #expect(Completion.token(in: "fix @Sour")?.query == "Sour")
    #expect(Completion.token(in: "@")?.query == "")
    // Mid-word sigils are not tokens (paths, emails, fractions).
    #expect(Completion.token(in: "a/b") == nil)
    #expect(Completion.token(in: "me@host") == nil)
    // Whitespace after the token closes it.
    #expect(Completion.token(in: "/grill ") == nil)
    #expect(Completion.token(in: "") == nil)
    #expect(Completion.token(in: "plain text") == nil)
}

@Test func slashRowsMergeSkillsAndBuiltinsByPrefix() {
    let skills = ["grill-me", "caveman", "Model-Helper"]
    #expect(
        Completion.slashRows(skills: skills, query: "")
            == ["grill-me", "caveman", "Model-Helper", "model", "compact", "clear", "rename", "cancel"])
    #expect(Completion.slashRows(skills: skills, query: "c") == ["caveman", "compact", "clear", "cancel"])
    #expect(Completion.slashRows(skills: skills, query: "MO") == ["Model-Helper", "model"])
    #expect(Completion.slashRows(skills: skills, query: "zzz").isEmpty)
    // A skill shadowing a builtin name is listed once.
    #expect(Completion.slashRows(skills: ["compact"], query: "comp") == ["compact"])
}

@Test func applyReplacesTokenAndAppendsSpace() {
    let draft = "please /gr"
    let token = Completion.token(in: draft)!
    #expect(Completion.apply(token, replacement: "grill-me", to: draft) == "please /grill-me ")

    let fileDraft = "look at @Comp"
    let fileToken = Completion.token(in: fileDraft)!
    #expect(
        Completion.apply(fileToken, replacement: "Sources/Views/Composer.swift", to: fileDraft)
            == "look at @Sources/Views/Composer.swift ")
}

@Test func activeSkillIsLeadingInstalledSkillOnly() {
    let skills = ["grill-me", "caveman"]
    #expect(Completion.activeSkill(in: "/grill-me my plan", skills: skills) == "grill-me")
    #expect(Completion.activeSkill(in: "/GRILL-ME", skills: skills) == "grill-me")
    #expect(Completion.activeSkill(in: "/model gpt-5", skills: skills) == nil)
    #expect(Completion.activeSkill(in: "use /caveman", skills: skills) == nil)
    #expect(Completion.activeSkill(in: "/", skills: skills) == nil)
}
