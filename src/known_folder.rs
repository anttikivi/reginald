//! Safe wrappers for accessing the Windows Known Folders API.

use std::{ffi::OsString, os::windows::ffi::OsStringExt, path::PathBuf, ptr, slice};

use log::warn;
use windows_sys::{
    Win32::{
        Foundation::S_OK,
        System::Com::CoTaskMemFree,
        UI::Shell::{
            FOLDERID_LocalAppData, FOLDERID_ProgramData, FOLDERID_RoamingAppData, KF_FLAG_DEFAULT,
            SHGetKnownFolderPath,
        },
    },
    core::GUID,
};

/// The Known Folders that Reginald uses.
#[expect(clippy::enum_variant_names, reason = "match the Windows API names")]
#[derive(Clone, Copy, Debug)]
pub enum Folder {
    /// `%LOCALAPPDATA%`, data of the current user on this machine.
    LocalAppData,
    /// `%APPDATA%`, data of the current user that may be shared between
    /// machines.
    RoamingAppData,
    /// `%PROGRAMDATA%`, data that may be shared between users on this machine.
    ProgramData,
}

impl Folder {
    const fn id(self) -> &'static GUID {
        match self {
            Self::LocalAppData => &FOLDERID_LocalAppData,
            Self::RoamingAppData => &FOLDERID_RoamingAppData,
            Self::ProgramData => &FOLDERID_ProgramData,
        }
    }
}

/// Returns the path of `folder` for the current user or `None` if Windows
/// cannot resolve it.
#[expect(unsafe_code, reason = "calls the Windows Known Folders API")]
pub fn path(folder: Folder) -> Option<PathBuf> {
    struct CoTaskMem(*mut u16);

    impl Drop for CoTaskMem {
        fn drop(&mut self) {
            // SAFETY: `SHGetKnownFolderPath` requires freeing the pointer with
            // `CoTaskMemFree` whether or not the call succeeded, and
            // `CoTaskMemFree` accepts null.
            unsafe { CoTaskMemFree(self.0.cast()) };
        }
    }

    let mut raw = ptr::null_mut();

    // SAFETY: `folder.id()` points to a valid, static GUID. The flags are the
    // documented default, a null token requests the folder of the current
    // user, and `raw` is a valid location for the output pointer.
    let result = unsafe {
        SHGetKnownFolderPath(
            folder.id(),
            KF_FLAG_DEFAULT.cast_unsigned(),
            ptr::null_mut(),
            &raw mut raw,
        )
    };
    let raw = CoTaskMem(raw);

    if result != S_OK {
        warn!(
            "cannot resolve known folder {folder:?}: HRESULT 0x{:08x}",
            result.cast_unsigned()
        );
        return None;
    }

    if raw.0.is_null() {
        warn!("known folder {folder:?} resolved to a null pointer");
        return None;
    }

    // SAFETY: On success, `raw.0` is non-null and points to a valid,
    // NUL-terminated wide string that stays alive until `raw` is dropped at the
    // end of this function. Reading up to the NUL stays inside that allocation.
    let wide = unsafe {
        let mut len = 0;
        while *raw.0.add(len) != 0 {
            len += 1;
        }
        slice::from_raw_parts(raw.0, len)
    };

    Some(PathBuf::from(OsString::from_wide(wide)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folders_resolve_to_existing_absolute_directories() {
        for folder in [
            Folder::LocalAppData,
            Folder::RoamingAppData,
            Folder::ProgramData,
        ] {
            let resolved = path(folder);
            assert!(
                resolved
                    .as_deref()
                    .is_some_and(|p| p.is_absolute() && p.is_dir()),
                "{folder:?}: {resolved:?}"
            );
        }
    }
}
