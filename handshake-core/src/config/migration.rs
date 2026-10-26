//! Adopts the legacy config tree without rewriting user files or following imported symlinks.
use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};

use thiserror::Error;

#[derive(Debug, Error)]
#[error(
    "Could not adopt config from {legacy} into {destination}: {source}. The legacy source is retained; repair the paths and retry."
)]
pub struct ConfigMigrationError {
    legacy: PathBuf,
    destination: PathBuf,
    #[source]
    source: io::Error,
}

pub(super) fn adopt(legacy: &Path, destination: &Path) -> Result<(), ConfigMigrationError> {
    adopt_tree(legacy, destination).map_err(|source| ConfigMigrationError {
        legacy: legacy.into(),
        destination: destination.into(),
        source,
    })
}

fn adopt_tree(legacy: &Path, destination: &Path) -> io::Result<()> {
    // An established Handshake tree is authoritative, including a user-managed directory symlink.
    match fs::symlink_metadata(destination) {
        Ok(_) => return Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let root_is_link = match fs::symlink_metadata(legacy) {
        Ok(metadata) => metadata.file_type().is_symlink(),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    let source = legacy.canonicalize()?;
    if !source.is_dir() {
        return Err(io::Error::other("legacy config root is not a directory"));
    }
    let parent = destination
        .parent()
        .ok_or_else(|| io::Error::other("config root needs a parent"))?;
    fs::create_dir_all(parent)?;
    if !root_is_link && parent.canonicalize()?.starts_with(&source) {
        return Err(io::Error::other(
            "new config root must be outside the legacy tree",
        ));
    }
    let copy = tempfile::Builder::new()
        .prefix(".handshake-config-")
        .tempdir_in(parent)?;
    let publication = if root_is_link {
        // Preserve the user-managed root's identity: copying its children would rebase ../ imports
        // and relative symlinks. The resolved target survives removal of the old root link.
        let link = copy.path().join("root");
        std::os::unix::fs::symlink(&source, &link)?;
        link
    } else {
        copy_tree(&source, copy.path())?;
        copy.path().to_owned()
    };
    match rustix::fs::renameat_with(
        rustix::fs::CWD,
        &publication,
        rustix::fs::CWD,
        destination,
        rustix::fs::RenameFlags::NOREPLACE,
    ) {
        Ok(()) => {
            if !root_is_link {
                let _published = copy.keep();
            }
        }
        Err(rustix::io::Errno::EXIST) => return Ok(()),
        Err(error) => return Err(error.into()),
    }
    File::open(parent)?.sync_all()
}

fn copy_tree(source: &Path, destination: &Path) -> io::Result<()> {
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let target = destination.join(entry.file_name());
        let kind = entry.file_type()?;
        if kind.is_symlink() {
            // Preserve link targets and relative layout, rather than copying third-party trees.
            std::os::unix::fs::symlink(fs::read_link(entry.path())?, target)?;
        } else if kind.is_dir() {
            fs::create_dir(&target)?;
            copy_tree(&entry.path(), &target)?;
        } else if kind.is_file() {
            fs::copy(entry.path(), &target)?;
            File::open(&target)?.sync_all()?;
        } else {
            return Err(io::Error::other(
                "config contains a special file; migrate it manually",
            ));
        }
    }
    File::open(destination)?.sync_all()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, FontSize};

    #[test]
    fn adopts_imports_workflows_custom_themes_and_links_once_without_editing_sources() {
        let root = tempfile::tempdir().unwrap();
        let legacy = root.path().join("twine");
        let destination = root.path().join("handshake");
        fs::create_dir_all(legacy.join("parts")).unwrap();
        fs::create_dir(legacy.join("themes")).unwrap();
        fs::create_dir(legacy.join("workflows")).unwrap();
        let config = "import = 'parts/settings.toml'\n[theme]\ndark = 'twine_dark'\n";
        fs::write(legacy.join("config.toml"), config).unwrap();
        fs::write(
            legacy.join("parts/settings.toml"),
            "[terminal]\nfont_size = 17.5\n",
        )
        .unwrap();
        fs::write(
            legacy.join("themes/twine_dark.toml"),
            "[terminal.colors]\nbackground = '#123456'\n",
        )
        .unwrap();
        let workflow = crate::BuiltinType::Adversarial.definition();
        fs::write(
            legacy.join("workflows/mine.toml"),
            toml::to_string(&workflow).unwrap(),
        )
        .unwrap();
        std::os::unix::fs::symlink("parts/settings.toml", legacy.join("linked.toml")).unwrap();
        adopt(&legacy, &destination).unwrap();
        let loaded = Config::load(&destination.join("config.toml"));
        assert_eq!(loaded.diagnostics, []);
        assert_eq!(loaded.config.terminal.font_size, FontSize(17.5));
        assert_eq!(
            loaded.config.terminal.palettes.dark.background.as_str(),
            "#123456"
        );
        assert_eq!(
            fs::read_to_string(legacy.join("config.toml")).unwrap(),
            config
        );
        let restored: crate::WorkflowTypeDefinition =
            toml::from_str(&fs::read_to_string(destination.join("workflows/mine.toml")).unwrap())
                .unwrap();
        assert_eq!(restored, workflow);
        assert_eq!(
            fs::read_link(destination.join("linked.toml")).unwrap(),
            Path::new("parts/settings.toml")
        );
        fs::write(
            destination.join("config.toml"),
            "[terminal]\nfont_size = 22\n",
        )
        .unwrap();
        fs::write(legacy.join("config.toml"), "invalid").unwrap();
        adopt(&legacy, &destination).unwrap();
        assert_eq!(
            Config::load(&destination.join("config.toml"))
                .config
                .terminal
                .font_size,
            FontSize(22.0)
        );
    }

    #[test]
    fn user_managed_root_links_keep_external_relative_imports_at_the_same_location() {
        let root = tempfile::tempdir().unwrap();
        let xdg = root.path().join("xdg");
        let files = root.path().join("dotfiles/settings");
        fs::create_dir_all(&xdg).unwrap();
        fs::create_dir_all(&files).unwrap();
        fs::write(files.join("config.toml"), "import = '../shared.toml'\n").unwrap();
        fs::write(
            root.path().join("dotfiles/shared.toml"),
            "[terminal]\nfont_size = 19\n",
        )
        .unwrap();
        let legacy = xdg.join("twine");
        let destination = xdg.join("handshake");
        std::os::unix::fs::symlink(&files, &legacy).unwrap();
        adopt(&legacy, &destination).unwrap();
        assert!(destination.is_symlink());
        let loaded = Config::load(&destination.join("config.toml"));
        assert_eq!(loaded.diagnostics, []);
        assert_eq!(loaded.config.terminal.font_size, FontSize(19.0));
        fs::remove_file(&legacy).unwrap();
        assert_eq!(
            Config::load(&destination.join("config.toml"))
                .config
                .terminal
                .font_size,
            FontSize(19.0)
        );
    }

    #[test]
    fn failed_copy_and_interrupted_private_tree_do_not_establish_a_destination() {
        let root = tempfile::tempdir().unwrap();
        let legacy = root.path().join("twine");
        let destination = root.path().join("handshake");
        fs::write(&legacy, b"unavailable").unwrap();
        assert!(adopt(&legacy, &destination).is_err());
        assert!(!destination.exists());
        fs::remove_file(&legacy).unwrap();
        fs::create_dir(&legacy).unwrap();
        fs::write(legacy.join("config.toml"), "[terminal]\nfont_size = 18\n").unwrap();
        fs::create_dir(root.path().join(".handshake-config-interrupted")).unwrap();
        adopt(&legacy, &destination).unwrap();
        assert_eq!(
            Config::load(&destination.join("config.toml"))
                .config
                .terminal
                .font_size,
            FontSize(18.0)
        );
    }
}
