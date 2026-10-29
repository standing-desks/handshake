mod mcp;

use handshake_core::browser_control::{Action, ElementState, Request};
use std::path::Path;

const HELP: &str = "Usage: handshake browser [--tab ID] COMMAND [ARGS]\n\nCommands: list, open URL_OR_PATH, navigate URL_OR_PATH, snapshot, click ELEMENT, hover ELEMENT,\n  fill ELEMENT TEXT, select ELEMENT VALUE, press KEY, scroll PIXELS, screenshot,\n  wait TEXT, wait-url SUBSTRING, wait-load, wait-element ELEMENT visible|hidden|enabled,\n  console, close\n\nKeys: Enter, Tab, Escape, Backspace, Delete, Space, Home, End, PageUp, PageDown,\n  arrows or a single letter, with optional Shift+, Control+, Alt+, Meta+ modifiers.\nSelect uses native typeahead for options with a unique initial ASCII letter; other\noptions require manual selection. Meta shortcuts support arrows and Backspace;\nControl/Alt support arrows and deletion. Edit-menu shortcuts (Meta+A/Z) are not supported;\nfill replaces a text field without Select All.\nSnapshots include nested same-origin frames and open shadow roots. Cross-origin\nframes are reported as unavailable; refs become stale when their document changes.\nOpen and navigate accept HTTP(S), file:// URLs, and local paths (relative to the CLI working directory). Local pages can load assets from their directory.\nOpening, navigation and inspection keep your current tab selected; native input and screenshots reveal the browser.\nRun from a Handshake terminal. open returns a tab ID; subsequent commands\nrequire --tab ID. screenshot returns base64 PNG in JSON. Commands time out after 30s.\nStop / Take over revokes authority; start a new terminal to grant it again.\nCodex launches receive a session-local MCP browser tool (browser mcp). Other\nsandboxed agents may request normal approval for the exact CLI command; never\ndisable their sandbox to connect.\n";

fn parse(args: &[String], token: String) -> Result<Request, String> {
    let mut args = args.iter().map(String::as_str);
    if args.next() != Some("browser") {
        return Err(HELP.into());
    }
    let mut next = args.next().ok_or(HELP)?;
    let tab = if next == "--tab" {
        let tab = args.next().ok_or("--tab requires an ID")?.to_owned();
        next = args.next().ok_or(HELP)?;
        Some(tab)
    } else {
        None
    };
    let mut argument = || {
        args.next()
            .map(str::to_owned)
            .ok_or_else(|| "Missing command argument".to_owned())
    };
    let action = match next {
        "list" => Action::List,
        "open" => Action::Open {
            url: navigation_target(argument()?)?,
        },
        "navigate" => Action::Navigate {
            url: navigation_target(argument()?)?,
        },
        "snapshot" => Action::Snapshot,
        "click" => Action::Click {
            element: argument()?,
        },
        "hover" => Action::Hover {
            element: argument()?,
        },
        "select" => Action::Select {
            element: argument()?,
            value: argument()?,
        },
        "fill" => Action::Fill {
            element: argument()?,
            text: argument()?,
        },
        "press" => Action::Press { key: argument()? },
        "scroll" => Action::Scroll {
            dy: argument()?
                .parse()
                .map_err(|_| "scroll requires integer pixels")?,
        },
        "screenshot" => Action::Screenshot,
        "wait" => Action::Wait { text: argument()? },
        "wait-url" => Action::WaitUrl { text: argument()? },
        "wait-load" => Action::WaitLoad,
        "wait-element" => Action::WaitElement {
            element: argument()?,
            state: match argument()?.as_str() {
                "visible" => ElementState::Visible,
                "hidden" => ElementState::Hidden,
                "enabled" => ElementState::Enabled,
                _ => return Err("Use visible, hidden or enabled for element state".into()),
            },
        },
        "console" => Action::Console,
        "close" => Action::Close,
        _ => return Err(HELP.into()),
    };
    if args.next().is_some() {
        return Err("Unexpected arguments".into());
    }
    Ok(Request { token, tab, action })
}

fn navigation_target(value: String) -> Result<String, String> {
    if value.is_empty() {
        return Err("A URL or file path is required".into());
    }
    // Resolve paths in the caller's directory, before sending them to the app host.
    let has_scheme = value.split_once(':').is_some_and(|(scheme, _)| {
        scheme.starts_with(|c: char| c.is_ascii_alphabetic())
            && scheme
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    });
    if has_scheme {
        return Ok(value);
    }
    std::path::absolute(value)
        .map_err(|error| error.to_string())?
        .into_os_string()
        .into_string()
        .map_err(|_| "The file path must be UTF-8".into())
}

fn run() -> Result<bool, Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if is_help(&args) {
        print!("{HELP}");
        return Ok(true);
    }
    let token = std::env::var("HANDSHAKE_BROWSER_TOKEN")
        .map_err(|_| "Run this command from a Handshake terminal.")?;
    let socket = std::env::var("HANDSHAKE_BROWSER_SOCKET")?;
    if args == ["browser", "mcp"] {
        mcp::serve(std::io::stdin().lock(), std::io::stdout().lock(), |args| {
            execute(args, token.clone(), &socket).map_err(|error| error.to_string())
        })?;
        return Ok(true);
    }
    let result = execute(&args, token, &socket)?;
    println!("{}", serde_json::to_string(&result)?);
    Ok(result["ok"] == true)
}

fn execute(
    args: &[String],
    token: String,
    socket: &str,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    if is_help(args) {
        return Ok(serde_json::json!({"ok": true, "help": HELP}));
    }
    let request = parse(args, token)?;
    let result = match handshake_core::browser_control::request(Path::new(socket), &request) {
        Ok(result) => result,
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => serde_json::json!({
            "ok": false,
            "error": {
                "code": "transport_permission_denied",
                "message": "The operating system denied the local browser connection. In a sandboxed agent, request user approval to rerun this exact browser CLI command outside the sandbox through the agent's normal permission flow. Do not disable the sandbox or change global settings. If approval is denied or unavailable, stop. This is separate from Handshake's Stop / Take over revocation, which must never be bypassed."
            }
        }),
        Err(error) => return Err(error.into()),
    };
    Ok(result)
}

fn is_help(args: &[String]) -> bool {
    args.is_empty() || args == ["--help"] || args == ["browser", "--help"]
}

fn main() -> std::process::ExitCode {
    match run() {
        Ok(true) => std::process::ExitCode::SUCCESS,
        Ok(false) => std::process::ExitCode::FAILURE,
        Err(error) => {
            eprintln!("{error}");
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn resolves_local_paths_in_the_callers_directory() {
        for relative in [
            "reports/my page #1.html",
            "./reports/12:30.html",
            "reports/build:debug/index.html",
        ] {
            let expected = std::path::absolute(relative).unwrap();
            assert_eq!(
                navigation_target(relative.into()).unwrap(),
                expected.to_str().unwrap()
            );
        }
        for value in [
            "https://example.test",
            "file:///tmp/my%20page.html",
            "javascript:alert(1)",
        ] {
            assert_eq!(navigation_target(value.into()).unwrap(), value);
        }
        assert!(navigation_target(String::new()).is_err());
    }

    #[test]
    fn preserves_literal_input_and_rejects_extra_arguments() {
        let args = ["browser", "--tab", "tab", "fill", "e1", "a\n'b"].map(str::to_owned);
        let request = parse(&args, "secret".into()).unwrap();
        assert!(matches!(request.action, Action::Fill { text, .. } if text == "a\n'b"));
        assert!(
            parse(
                &["browser", "snapshot", "extra"].map(str::to_owned),
                String::new()
            )
            .is_err()
        );
    }

    #[test]
    fn help_text_as_input_is_not_a_help_command() {
        for args in [
            vec!["browser", "--tab", "tab", "fill", "e1", "--help"],
            vec!["browser", "--tab", "tab", "wait", "--help"],
        ] {
            let args: Vec<_> = args.into_iter().map(str::to_owned).collect();
            assert!(!is_help(&args));
            assert!(parse(&args, "token".into()).is_ok());
        }
        assert!(is_help(&["browser".into(), "--help".into()]));
    }
}
