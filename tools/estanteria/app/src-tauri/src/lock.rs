//! The computer's own lock in front of the app: Windows Hello (face, fingerprint or the PIN of the
//! user's account) through `UserConsentVerifier`. Elsewhere there is none and both commands say no.
//!
//! The question goes through `IUserConsentVerifierInterop::RequestVerificationForWindowAsync` with the
//! app's window: a desktop (non-UWP) app that asks `RequestVerificationAsync` gets a dialog that may
//! open behind its window or without the focus; tied to the window it opens over it, in front. The
//! wait happens on a blocking thread, so the window keeps painting while the person answers.

/// Whether this computer has Windows Hello set up (a face, a fingerprint or a PIN).
#[tauri::command]
pub async fn lock_available() -> bool {
    #[cfg(windows)]
    {
        tauri::async_runtime::spawn_blocking(hello::available).await.unwrap_or(false)
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// Asks for Windows Hello over the window that asked; true when the person passed. `reason` is the
/// line the dialog shows.
#[tauri::command]
pub async fn lock_unlock(window: tauri::Window, reason: String) -> bool {
    #[cfg(windows)]
    {
        // the handle crosses to the blocking thread as a number (a raw pointer is not Send)
        let hwnd = window.hwnd().map(|h| h.0 as isize).unwrap_or(0);
        tauri::async_runtime::spawn_blocking(move || hello::verify(hwnd, &reason)).await.unwrap_or(false)
    }
    #[cfg(not(windows))]
    {
        let _ = (window, reason);
        false
    }
}

#[cfg(windows)]
mod hello {
    use windows::core::{factory, HSTRING};
    use windows::Security::Credentials::UI::{
        UserConsentVerificationResult, UserConsentVerifier, UserConsentVerifierAvailability,
    };
    use windows::Win32::Foundation::HWND;
    use windows::Win32::System::WinRT::IUserConsentVerifierInterop;

    /// Blocking: Windows answers at once, but it is still an asynchronous operation waited on here.
    pub fn available() -> bool {
        UserConsentVerifier::CheckAvailabilityAsync()
            .and_then(|op| op.join())
            .map(|a| a == UserConsentVerifierAvailability::Available)
            .unwrap_or(false)
    }

    /// Blocking until the person answers (or cancels) the dialog.
    pub fn verify(hwnd: isize, reason: &str) -> bool {
        let message = HSTRING::from(reason);
        // the interop call's operation type is the plain call's (IAsyncOperation<UserConsentVerificationResult>)
        let operation = if hwnd != 0 {
            factory::<UserConsentVerifier, IUserConsentVerifierInterop>().and_then(|interop| unsafe {
                interop.RequestVerificationForWindowAsync(HWND(hwnd as *mut _), &message)
            })
        } else {
            // no window to tie it to (it should not happen): the plain call, which may open behind
            UserConsentVerifier::RequestVerificationAsync(&message)
        };
        operation
            .and_then(|op| op.join())
            .map(|r| r == UserConsentVerificationResult::Verified)
            .unwrap_or(false)
    }

    #[cfg(test)]
    mod tests {
        /// Only the availability: asking for Windows Hello would open the real dialog.
        #[test]
        fn availability_answers() {
            // the raw answer too: an error is told apart from "not set up" (NotConfiguredForUser…)
            let raw = super::UserConsentVerifier::CheckAvailabilityAsync().and_then(|op| op.join());
            println!("Windows Hello on this computer: {raw:?}");
            assert_eq!(super::available(), matches!(raw, Ok(super::UserConsentVerifierAvailability::Available)));
        }
    }
}
