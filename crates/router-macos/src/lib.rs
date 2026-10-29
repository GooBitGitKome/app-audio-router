//! Native macOS backend. HAL handles and unsafe callbacks stay in this crate.
#![cfg(target_os = "macos")]
mod engine;
mod hardware;
pub use engine::*;
pub use hardware::*;

#[derive(Debug, Clone)]
pub struct Error {
    pub operation: String,
    pub status: Option<i32>,
}
impl Error {
    pub fn message(message: impl Into<String>) -> Self {
        Self {
            operation: message.into(),
            status: None,
        }
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.operation)?;
        if let Some(status) = self.status {
            write!(f, " (OSStatus {status})")?;
        }
        Ok(())
    }
}
impl std::error::Error for Error {}
pub type Result<T> = std::result::Result<T, Error>;
fn check(status: i32, operation: &str) -> Result<()> {
    if status == 0 {
        Ok(())
    } else {
        Err(Error {
            operation: operation.into(),
            status: Some(status),
        })
    }
}

/// Playback occurs in this process, so the global tap's mandatory self-exclusion
/// also excludes self-test playback. No external audio player process is used.
pub struct Player(objc2::rc::Retained<objc2_avf_audio::AVAudioPlayer>);
impl Player {
    pub fn play(path: &std::path::Path) -> Result<Self> {
        use objc2::AnyThread;
        let url = objc2_foundation::NSURL::fileURLWithPath(&objc2_foundation::NSString::from_str(
            &path.to_string_lossy(),
        ));
        let player = unsafe {
            objc2_avf_audio::AVAudioPlayer::initWithContentsOfURL_error(
                objc2_avf_audio::AVAudioPlayer::alloc(),
                &url,
            )
        }
        .map_err(|e| Error::message(e.to_string()))?;
        if !unsafe { player.play() } {
            return Err(Error::message("recording playback could not start"));
        }
        Ok(Self(player))
    }
    pub fn is_playing(&self) -> bool {
        unsafe { self.0.isPlaying() }
    }
    pub fn elapsed(&self) -> f64 {
        unsafe { self.0.currentTime() }
    }
    pub fn duration(&self) -> f64 {
        unsafe { self.0.duration() }
    }
}
impl Drop for Player {
    fn drop(&mut self) {
        unsafe {
            self.0.stop();
        }
    }
}
