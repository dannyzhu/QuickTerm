import AppKit

/// `hooks install | uninstall | status` — the control plane's half of the hook installer
/// (plan §2.6).
///
/// The whole group is three lines of glue over `HookInstaller`, and that is the design: the CLI,
/// the menu item and the registry's auto-install ask are three front doors onto **one** installer,
/// so there is one place that knows how to edit another program's config file, one confirmation in
/// front of it, and one set of refusals.
///
/// Two things this file does own:
/// - **validating the agent id**, because the command table is static while rule files are loaded
///   at runtime: `claude-code | codex | gemini | all` in the help is a description, not a list the
///   parser can enforce, so a wrong id is answered here with the ids that actually exist. The
///   check is reachable **before** the confirmation gate as well (`validateHooksInstallTarget`,
///   called from the runner's pre-consent `pin`): an id that can never install must be a
///   `bad_request`, not a sheet in front of the user asking about a file nothing will ever write;
/// - **the diff**, computed read-only before anything is written, so `commit()` can turn "already
///   installed at this tier" into a silent success (exit 7 under `--fail-if-noop`) without the
///   command body knowing anything about dry runs.
@MainActor
extension ControlCommandRunner {
    func runHooks(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "install": return try hooksInstall(ctx)
        case "uninstall": return try hooksUninstall(ctx)
        case "status": return try hooksStatus(ctx)
        default:
            throw ControlErrorBody(.unknownCommand, "hooks has no verb \(ctx.spec.verb)",
                                   candidates: ControlCommandTable.commands(inGroup: "hooks").map(\.verb))
        }
    }

    // MARK: install

    private func hooksInstall(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let ids = try requestedAgents(ctx, verb: "install")
        let configDir = ctx.string("config-dir")

        // The plan is a pure read, and it is what the confirmation gate, `--dry-run` and
        // `--fail-if-noop` all act on. An agent already installed at the current tier contributes
        // nothing, so `hooks install all` run twice is a no-op even when one of the three was
        // installed and the other two were not.
        var plans: [HookChange] = []
        for id in ids {
            let plan = try HookInstaller.plan(id: id, configDir: configDir)
            if plan.changed { plans.append(plan) }
        }
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: plans.map { ControlChange("hooks.\($0.agent)", from: $0.from, to: $0.to) },
            controllers: [],
            // Nothing to undo: `quickterm hooks uninstall` is the revert, and Cmd+Z reaching into
            // another program's settings file is not something a terminal's undo stack should do.
            undoCommand: nil, target: nil)
        return (nil, try commit(mutation) {
            for plan in plans { _ = try HookInstaller.install(id: plan.agent, configDir: configDir) }
        })
    }

    // MARK: uninstall

    private func hooksUninstall(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let ids = try requestedAgents(ctx, verb: "uninstall")
        let configDir = ctx.string("config-dir")

        var plans: [HookChange] = []
        for id in ids {
            let plan = try HookInstaller.uninstallPlan(id: id, configDir: configDir)
            if plan.changed { plans.append(plan) }
        }
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: plans.map { ControlChange("hooks.\($0.agent)", from: $0.from, to: $0.to) },
            controllers: [], undoCommand: nil, target: nil)
        return (nil, try commit(mutation) {
            for plan in plans { _ = try HookInstaller.uninstall(id: plan.agent, configDir: configDir) }
        })
    }

    // MARK: status

    private func hooksStatus(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let configDir = ctx.string("config-dir")
        let ids: [String]
        if let named = ctx.string("agent") {
            guard HookInstaller.installableIDs.contains(named) || AgentRegistry.shared.rules[named] != nil else {
                throw unknownAgent(named, verb: "status")
            }
            ids = [named]
        } else {
            // Every loaded rule, installer or not: "Gemini has no [install] table" is exactly the
            // kind of thing someone runs `hooks status` to find out.
            ids = AgentRegistry.shared.activeRulesForInstall.map(\.id)
        }
        let payload = ControlHooksPayload(
            // The script `--config-dir` redirects, not the one in a directory this call never
            // touches: `status` has to report what `install` with the same flag would write.
            script: HookInstaller.scriptStatus(configDir: configDir),
            agents: ids.map { HookInstaller.status(id: $0, configDir: configDir) })
        return (nil, payload)
    }

    // MARK: The agent argument

    /// **The pre-consent check** for `hooks install` (called from the runner's `pin`, before the
    /// confirmation goes out). Exactly the resolution the command body does a moment later, thrown
    /// away: `hooks install claude` is a typo, and asking the user to approve editing a file that
    /// no rule names is a question with no right answer — it can only end in `bad_request` once
    /// they have clicked.
    func validateHooksInstallTarget(_ request: ControlRequest) throws {
        _ = try requestedAgents(request.args["agent"]?.stringValue, verb: "install")
    }

    /// `<agent>` resolved to the ids to act on. `all` means every loaded rule that has an
    /// installer — never one that has none, which would only be a refusal the user did not ask for.
    private func requestedAgents(_ ctx: ControlContext, verb: String) throws -> [String] {
        try requestedAgents(ctx.string("agent"), verb: verb)
    }

    private func requestedAgents(_ raw: String?, verb: String) throws -> [String] {
        guard let raw else {
            throw ControlErrorBody(
                .badRequest, "hooks \(verb) needs an agent: quickterm hooks \(verb) <agent>",
                hint: "quickterm hooks status lists the agents QuickTerm knows about.",
                candidates: HookInstaller.installableIDs + ["all"])
        }
        if raw == "all" {
            let ids = HookInstaller.installableIDs
            guard !ids.isEmpty else {
                throw ControlErrorBody(.badRequest, "No loaded agent rule file declares an [install] table")
            }
            return ids
        }
        guard HookInstaller.installableIDs.contains(raw) else { throw unknownAgent(raw, verb: verb) }
        return [raw]
    }

    private func unknownAgent(_ raw: String, verb: String) -> ControlErrorBody {
        // Two different mistakes deserve two different sentences: an id nobody has heard of, and a
        // rule file that loaded fine but declares no [install] table. Telling the second caller
        // "no rule file with that id" sends them hunting for a file that is right there.
        let loaded = AgentRegistry.shared.activeRulesForInstall.first { $0.id == raw }
        let message = loaded == nil
            ? "No agent rule file with id \(raw)"
            : "The rule file for \(raw) declares no [install] table, so there are no hooks to \(verb)"
        return ControlErrorBody(.badRequest, message,
                                hint: loaded == nil
                                    ? "Rule files live in the app bundle and in ~/.config/quickterm/agents; "
                                        + "quickterm hooks status lists the ids that loaded."
                                    : "Add an [install] table to the rule file (shape, config) to make it installable.",
                                candidates: HookInstaller.installableIDs + (verb == "status" ? [] : ["all"]))
    }
}
