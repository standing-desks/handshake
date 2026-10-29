//! Nouli's explicit embedding boundary: folder-local env files and the user's shared setup.
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use nouli_core::config::{
    Config, ConfigError,
    auth::{AuthEntry, AuthStore, CredentialSource, KeySource},
    resolve::RuntimeOverrides,
};
use nouli_core::history::ModelSelection;
use thiserror::Error;
use tokio_util::sync::CancellationToken;

use super::{LoginPath, credentials};
use crate::DecisionNode;

const MAX_FILE_BYTES: u64 = 1024 * 1024;

#[derive(Debug, Error)]
pub(crate) enum SettingsError {
    #[error("Nouli needs a home directory to find ~/.nouli/config.toml.")]
    Home,
    #[error("Cannot read Nouli settings: {0}")]
    Read(PathBuf),
    #[error("Invalid syntax, encoding, or size in Nouli settings: {0}")]
    Invalid(PathBuf),
    #[error("Nouli credential store must be a regular file owned by you with mode 0600: {0}")]
    Insecure(PathBuf),
    #[error("Cannot create Nouli configuration: {0}")]
    Create(PathBuf),
    #[error("{source}. Configuration: {path}")]
    Config { path: PathBuf, source: ConfigError },
}

pub(super) struct Settings {
    pub config: Config,
    pub overrides: RuntimeOverrides,
    pub home: PathBuf,
    pub path: PathBuf,
    folder: PathBuf,
    environment: BTreeMap<OsString, OsString>,
    values: BTreeMap<String, String>,
    auth: AuthStore,
}

impl Settings {
    pub(super) fn load(
        folder: &Path,
        home: Option<PathBuf>,
        environment: BTreeMap<OsString, OsString>,
    ) -> Result<Self, SettingsError> {
        let home = home
            .or_else(|| {
                environment
                    .get(std::ffi::OsStr::new("HOME"))
                    .map(PathBuf::from)
            })
            .filter(|path| !path.as_os_str().is_empty())
            .ok_or(SettingsError::Home)?;
        let path = home.join(".nouli/config.toml");
        let input = match read(&path, false)? {
            Some(input) => input,
            None => initialize(&path)?,
        };
        let mut config = Config::parse(&input).map_err(|source| SettingsError::Config {
            path: path.clone(),
            source,
        })?;
        config.execution.max_response_bytes =
            config.execution.max_response_bytes.min(super::MAX_OUTPUT);
        let env_path = folder.join(".env");
        let input = read(&env_path, false)?.unwrap_or_default();
        let input = input.strip_prefix('\u{feff}').unwrap_or(&input).trim_end();
        let values = dotenvy::from_read_iter(input.as_bytes())
            .collect::<Result<_, _>>()
            .map_err(|_| SettingsError::Invalid(env_path))?;
        let auth_path = home.join(".nouli/auth.toml");
        let auth = AuthStore::parse(&read(&auth_path, true)?.unwrap_or_default())
            .map_err(|_| SettingsError::Invalid(auth_path))?;
        let overrides = RuntimeOverrides {
            stored_credentials: auth.providers().map(str::to_owned).collect(),
            output: Some(nouli_core::config::OutputFormat::Json),
            ..RuntimeOverrides::default()
        };
        Ok(Self {
            config,
            overrides,
            home,
            path,
            folder: folder.to_owned(),
            environment,
            values,
            auth,
        })
    }

    fn env(&self, name: &str) -> Option<String> {
        // An exported empty or non-Unicode value must shadow both other sources.
        match self.environment.get(std::ffi::OsStr::new(name)) {
            Some(value) => Some(value.to_str().unwrap_or("").to_owned()),
            None => self.values.get(name).cloned(),
        }
    }

    pub(super) fn credential(
        &self,
        node: &DecisionNode,
        cancel: &CancellationToken,
        login_path: &LoginPath,
    ) -> Result<Option<(CredentialSource, String)>, SettingsError> {
        let selected = self
            .config
            .resolve_snapshot(
                &self.overrides,
                &ModelSelection {
                    provider: node.provider.clone(),
                    model: node.model.clone(),
                },
                &ModelSelection::default(),
                &self.home,
            )
            .map_err(|source| SettingsError::Config {
                path: self.path.clone(),
                source,
            })?;
        if let Some((name, value)) = selected
            .profile
            .api_key_env
            .as_deref()
            .and_then(|name| self.env(name).map(|value| (name, value)))
        {
            return Ok(Some((CredentialSource::Env(name.into()), value)));
        }
        Ok(
            (match self.auth.get(&selected.profile_name).map(AuthEntry::source) {
                Some(KeySource::Key(key)) => Some(key.expose().to_owned()),
                Some(KeySource::Env(name)) => self.env(name),
                Some(KeySource::Command(argv)) => {
                    let path = login_path
                        .get()
                        .or_else(|| self.environment.get(std::ffi::OsStr::new("PATH")).cloned());
                    credentials::command(argv, &self.folder, &self.home, path.as_deref(), cancel)
                }
                None => None,
            })
            .map(|value| (CredentialSource::Auth(selected.profile_name), value)),
        )
    }
}

fn read(path: &Path, private: bool) -> Result<Option<String>, SettingsError> {
    let mut options = OpenOptions::new();
    options
        .read(true)
        .custom_flags(libc::O_NONBLOCK | if private { libc::O_NOFOLLOW } else { 0 });
    let file = match options.open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) if private && error.raw_os_error() == Some(libc::ELOOP) => {
            return Err(SettingsError::Insecure(path.into()));
        }
        Err(_) => return Err(SettingsError::Read(path.into())),
    };
    let metadata = file
        .metadata()
        .map_err(|_| SettingsError::Read(path.into()))?;
    // SAFETY: geteuid has no preconditions and returns this process's effective user ID.
    if private
        && (!metadata.is_file()
            || metadata.mode() & 0o077 != 0
            || metadata.uid() != unsafe { libc::geteuid() })
    {
        return Err(SettingsError::Insecure(path.into()));
    }
    if !metadata.is_file() {
        return Err(SettingsError::Read(path.into()));
    }
    let mut input = String::new();
    file.take(MAX_FILE_BYTES + 1)
        .read_to_string(&mut input)
        .map_err(|_| SettingsError::Invalid(path.into()))?;
    if input.len() as u64 > MAX_FILE_BYTES {
        return Err(SettingsError::Invalid(path.into()));
    }
    Ok(Some(input))
}

fn initialize(path: &Path) -> Result<String, SettingsError> {
    let failed = || SettingsError::Create(path.into());
    let parent = path.parent().ok_or_else(failed)?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)
        .map_err(|_| failed())?;
    let mut file = tempfile::NamedTempFile::new_in(parent).map_err(|_| failed())?;
    file.write_all(b"output = \"auto\"\n")
        .map_err(|_| failed())?;
    file.as_file().sync_all().map_err(|_| failed())?;
    match file.persist_noclobber(path) {
        Ok(_) => {}
        Err(error) if error.error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(_) => return Err(failed()),
    }
    read(path, false)?.ok_or_else(failed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStringExt;
    use std::os::unix::fs::{PermissionsExt, symlink};

    fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        let folder = root.path().join("folder");
        fs::create_dir_all(home.join(".nouli")).unwrap();
        fs::create_dir_all(&folder).unwrap();
        fs::write(
            home.join(".nouli/config.toml"),
            r#"
default_provider = "fixture"
default_model = "offline"
[providers.fixture]
protocol = "typesafe"
base_url = "http://localhost:1"
api_key_env = "TOKEN"
[providers.fixture.models.offline]
context_budget_tokens = 4096
"#,
        )
        .unwrap();
        (root, home, folder)
    }

    fn node() -> DecisionNode {
        serde_json::from_value(serde_json::json!({"kind":"noul","question":"Is it ready?"}))
            .unwrap()
    }

    fn stored(home: &Path, source: &str) {
        let path = home.join(".nouli/auth.toml");
        fs::write(
            &path,
            format!("[providers.fixture]\ntype = \"api_key\"\n{source}\n"),
        )
        .unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
    }

    fn key(settings: &Settings) -> Option<(CredentialSource, String)> {
        settings
            .credential(&node(), &CancellationToken::new(), &LoginPath::ready(None))
            .unwrap()
    }

    #[test]
    fn exported_values_shadow_folder_env_and_store_even_when_empty_or_invalid() {
        let (_root, home, folder) = fixture();
        stored(&home, "key = \"STORED_SENTINEL\"");
        fs::write(folder.join(".env"), "TOKEN='FILE_SENTINEL'\n").unwrap();
        let load = |environment| Settings::load(&folder, Some(home.clone()), environment).unwrap();
        assert_eq!(
            key(&load(BTreeMap::new())),
            Some((
                CredentialSource::Env("TOKEN".into()),
                "FILE_SENTINEL".into()
            ))
        );
        for value in ["EXPORTED_SENTINEL", ""] {
            let environment = [(OsString::from("TOKEN"), OsString::from(value))].into();
            assert_eq!(
                key(&load(environment)),
                Some((CredentialSource::Env("TOKEN".into()), value.into()))
            );
        }
        fs::remove_file(folder.join(".env")).unwrap();
        assert_eq!(
            key(&load(BTreeMap::new())),
            Some((
                CredentialSource::Auth("fixture".into()),
                "STORED_SENTINEL".into()
            ))
        );
        let environment = [(OsString::from("TOKEN"), OsString::from_vec(vec![0xff]))].into();
        assert_eq!(
            key(&load(environment)),
            Some((CredentialSource::Env("TOKEN".into()), String::new()))
        );
    }

    #[test]
    fn auth_store_environment_and_command_sources_share_nouli_formats() {
        let (_root, home, folder) = fixture();
        fs::write(folder.join(".env"), "STORED_TOKEN=ENV_SENTINEL\n").unwrap();
        stored(&home, "env = \"STORED_TOKEN\"");
        let settings = Settings::load(&folder, Some(home.clone()), BTreeMap::new()).unwrap();
        assert_eq!(
            key(&settings),
            Some((
                CredentialSource::Auth("fixture".into()),
                "ENV_SENTINEL".into()
            ))
        );
        stored(
            &home,
            "command = [\"/bin/sh\", \"-c\", \"printf COMMAND_SENTINEL\"]",
        );
        let settings = Settings::load(&folder, Some(home), BTreeMap::new()).unwrap();
        assert_eq!(
            key(&settings),
            Some((
                CredentialSource::Auth("fixture".into()),
                "COMMAND_SENTINEL".into()
            ))
        );
    }

    #[test]
    fn each_folder_loads_only_its_own_env_without_changing_process_globals() {
        let (root, home, first) = fixture();
        let second = root.path().join("second");
        fs::create_dir(&second).unwrap();
        fs::write(first.join(".env"), "TOKEN=FIRST").unwrap();
        fs::write(second.join(".env"), "TOKEN=SECOND").unwrap();
        fs::write(root.path().join(".env"), "TOKEN=PARENT").unwrap();
        let cwd = std::env::current_dir().unwrap();
        for (folder, expected) in [(&first, "FIRST"), (&second, "SECOND")] {
            let settings = Settings::load(folder, Some(home.clone()), BTreeMap::new()).unwrap();
            assert_eq!(key(&settings).unwrap().1, expected);
        }
        assert_eq!(std::env::current_dir().unwrap(), cwd);
    }

    #[test]
    fn unsafe_auth_files_and_invalid_env_fail_without_exposing_contents() {
        let (_root, home, folder) = fixture();
        stored(&home, "key = \"SECRET_SENTINEL\"");
        let path = home.join(".nouli/auth.toml");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        let error = Settings::load(&folder, Some(home.clone()), BTreeMap::new())
            .err()
            .unwrap();
        assert!(matches!(error, SettingsError::Insecure(_)));
        assert!(!error.to_string().contains("SECRET_SENTINEL"));
        fs::rename(&path, path.with_extension("real")).unwrap();
        symlink(path.with_extension("real"), &path).unwrap();
        assert!(matches!(
            Settings::load(&folder, Some(home.clone()), BTreeMap::new()),
            Err(SettingsError::Insecure(_))
        ));
        fs::remove_file(&path).unwrap();
        fs::write(folder.join(".env"), "TOKEN=\"SECRET_SENTINEL").unwrap();
        let error = Settings::load(&folder, Some(home), BTreeMap::new())
            .err()
            .unwrap();
        assert!(!format!("{error:?} {error}").contains("SECRET_SENTINEL"));
    }

    #[test]
    fn first_use_creates_private_config_without_a_ledger_and_preserves_existing_files() {
        let root = tempfile::tempdir().unwrap();
        let settings =
            Settings::load(root.path(), Some(root.path().into()), BTreeMap::new()).unwrap();
        assert!(settings.config.providers.is_empty());
        assert_eq!(fs::metadata(&settings.path).unwrap().mode() & 0o777, 0o600);
        assert_eq!(
            fs::metadata(settings.path.parent().unwrap())
                .unwrap()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(fs::read_dir(root.path().join(".nouli")).unwrap().count(), 1);
        fs::write(&settings.path, "invalid = [").unwrap();
        assert!(Settings::load(root.path(), Some(root.path().into()), BTreeMap::new()).is_err());
        assert_eq!(fs::read_to_string(&settings.path).unwrap(), "invalid = [");
    }
}
