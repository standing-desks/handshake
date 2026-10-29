//! Conservative presentation hints from authenticated shell command boundaries.
//! This never executes a command or infers workflow completion from terminal text.
use super::HarnessId;

pub(crate) fn detect(command: &str) -> Option<HarnessId> {
    // Compound/background/remote commands cannot identify one foreground agent reliably.
    if command.contains([';', '|', '&', '\n', '`', '$', '(', ')', '<', '>']) {
        return None;
    }
    let mut words = command.split_whitespace();
    let mut executable = words.next()?;
    if executable == "command" {
        executable = words.next()?;
    }
    let binary = executable.rsplit('/').next()?;
    let harness = match binary {
        "codex" => HarnessId::Codex,
        "claude" => HarnessId::ClaudeCode,
        "pi" => HarnessId::Pi,
        "agy" => HarnessId::Antigravity,
        "omp" => HarnessId::Omp,
        "opencode" => HarnessId::Opencode,
        "kiro-cli" => HarnessId::Kiro,
        _ => return None,
    };
    let arguments: Vec<_> = words.collect();
    if arguments.iter().any(|arg| {
        matches!(
            *arg,
            "--help" | "-h" | "--version" | "-V" | "--print" | "--non-interactive"
        ) || (*arg == "-p" && harness != HarnessId::Codex)
    }) {
        return None;
    }
    // Known administrative and batch subcommands do not open an agent conversation.
    if arguments.first().is_some_and(|arg| {
        matches!(
            *arg,
            "help"
                | "version"
                | "login"
                | "logout"
                | "auth"
                | "config"
                | "settings"
                | "mcp"
                | "mcp-server"
                | "completion"
                | "completions"
                | "update"
                | "doctor"
                | "exec"
                | "e"
                | "app-server"
                | "exec-server"
                | "run"
                | "serve"
                | "models"
                | "list"
                | "review"
        )
    }) {
        return None;
    }
    Some(harness)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_direct_foreground_harness_commands() {
        for (command, expected) in [
            ("codex", HarnessId::Codex),
            ("codex -p work", HarnessId::Codex),
            (
                "command /opt/bin/claude --model sonnet",
                HarnessId::ClaudeCode,
            ),
            ("kiro-cli chat", HarnessId::Kiro),
            ("omp launch", HarnessId::Omp),
            ("opencode mini", HarnessId::Opencode),
            ("pi", HarnessId::Pi),
            ("agy", HarnessId::Antigravity),
        ] {
            assert_eq!(detect(command), Some(expected), "{command}");
        }
    }

    #[test]
    fn excludes_ambiguous_remote_and_noninteractive_commands() {
        for command in [
            "echo codex",
            "ssh host codex",
            "codex &",
            "codex | cat",
            "codex; ls",
            "codex --help",
            "claude -p test",
            "codex exec task",
            "codex e task",
            "codex app-server",
            "kiro-cli settings",
            "opencode run task",
            "$(echo codex)",
            "my-codex",
            "",
            "command",
        ] {
            assert_eq!(detect(command), None, "{command}");
        }
    }
}
