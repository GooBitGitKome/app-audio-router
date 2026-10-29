use router_macos::*;
use std::{
    path::PathBuf,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};
static RUNNING: AtomicBool = AtomicBool::new(true);
extern "C" fn interrupt(_: i32) {
    RUNNING.store(false, Ordering::Relaxed);
}
fn help() {
    println!(
        "AppAudioRouter CLI — native Rust backend (experimental)\n\nUsage: AppAudioRouterCLI <command>\n  devices                              List audio devices\n  processes                            List CoreAudio processes\n  tap --pid <pid>                      Tap and monitor a process\n  multi-output <uid1> <uid2> ...        Create Multi-Output device\n  multi-input <uid1> ...               Create Aggregate Microphone\n  setup-virtual-mic [--set-default]     Publish virtual microphone\n  cleanup-virtual-mic                  Explicitly destroy virtual microphone\n  test-virtual-mic [seconds]            Record and play (default 3, range 1–30)\n  test-tone                           Test 440Hz routing and recording\n  test-desktop                        Test desktop tap and recording\n  diagnose                            Inspect devices and permissions\n  watch-input [seconds]                Watch device changes (default 60)\n\nRequires macOS 14.2+ and a bidirectional loopback driver."
    );
}
fn main() {
    unsafe {
        libc::signal(libc::SIGINT, interrupt as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, interrupt as *const () as libc::sighandler_t);
    }
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.is_empty() || args.iter().any(|s| s == "--help" || s == "-h") {
        help();
        return;
    }
    if let Err(error) = run(&args) {
        eprintln!("Error: {error}");
        std::process::exit(1);
    }
}
fn duration(arg: Option<&String>, default: f64, max: f64) -> Result<f64> {
    let value = arg
        .map(|s| s.parse::<f64>())
        .transpose()
        .map_err(|_| Error::message("invalid duration"))?
        .unwrap_or(default);
    if !value.is_finite() {
        return Err(Error::message("duration must be finite"));
    }
    Ok(value.clamp(1., max))
}
fn target() -> Result<Device> {
    loopback(&devices()?)
        .cloned()
        .ok_or_else(|| Error::message("no bidirectional loopback driver; install BlackHole 2ch"))
}
fn recording_target() -> Result<Device> {
    let all = devices()?;
    all.iter()
        .find(|d| d.is_app_microphone())
        .or_else(|| loopback(&all))
        .cloned()
        .ok_or_else(|| Error::message("no virtual microphone or loopback input"))
}
fn path() -> PathBuf {
    std::env::temp_dir().join("virtual_input_test.wav")
}
fn playback(path: &std::path::Path) -> Result<()> {
    let player = Player::play(path)?;
    while RUNNING.load(Ordering::Relaxed) && player.is_playing() {
        std::thread::sleep(Duration::from_millis(50));
    }
    Ok(())
}
fn list_devices(all: &[Device]) {
    for d in all {
        println!(
            "• [{}] {} ({}){}{}{}{}\n    UID: {}\n    Channels: In={}, Out={}, Rate: {}Hz",
            d.id,
            d.name,
            d.manufacturer,
            if d.default_input { " [DEFAULT_IN]" } else { "" },
            if d.default_output {
                " [DEFAULT_OUT]"
            } else {
                ""
            },
            if d.virtual_device { " [VIRTUAL]" } else { "" },
            if d.aggregate { " [AGGREGATE]" } else { "" },
            d.uid,
            d.input_channels,
            d.output_channels,
            d.rate
        );
        if d.aggregate {
            println!(
                "    Configured subdevices: {}",
                subdevice_uids(d.id).unwrap_or_default().join(", ")
            );
        }
    }
}
fn run(args: &[String]) -> Result<()> {
    match args[0].as_str() {
        "devices" => {
            let all = devices()?;
            list_devices(&all);
            if all.is_empty() {
                return Err(Error::message(
                    "CoreAudio returned no devices; hardware access is unverified",
                ));
            }
        }
        "processes" => {
            for p in processes()? {
                println!("• PID {}: {} (object {})", p.pid, p.bundle_id, p.id);
            }
        }
        "tap" => {
            let index = args
                .iter()
                .position(|s| s == "--pid")
                .ok_or_else(|| Error::message("missing --pid"))?;
            let pid = args
                .get(index + 1)
                .and_then(|s| s.parse::<i32>().ok())
                .filter(|p| *p > 0)
                .ok_or_else(|| Error::message("invalid --pid"))?;
            let monitor = ProcessMonitor::start(pid)?;
            let start = Instant::now();
            while RUNNING.load(Ordering::Relaxed) && start.elapsed() < Duration::from_secs(15) {
                println!("Peak: {:.0}%", monitor.peak() * 100.);
                std::thread::sleep(Duration::from_millis(500));
            }
        }
        "multi-output" | "multi-input" | "aggregate-input" | "combine-mics" => {
            let stacked = args[0] == "multi-output";
            if args.len() < if stacked { 3 } else { 2 } {
                return Err(Error::message("not enough device UIDs"));
            }
            let aggregate = Aggregate::create(
                if stacked {
                    "CLI Multi-Output Device"
                } else {
                    "CLI Combined Microphones"
                },
                &args[1..],
                stacked,
                false,
                None,
            )?;
            println!("Created public device {}", aggregate.persist());
        }
        "setup-virtual-mic" | "setup-desktop-mic" | "desktop-mic" => {
            let source = target()?;
            let aggregate = Aggregate::virtual_microphone(&source)?;
            if args.iter().any(|arg| arg == "--set-default") {
                set_default_input(aggregate.id)?;
            }
            println!(
                "{} active, ID {}",
                router_core::VIRTUAL_MIC_NAME,
                aggregate.persist()
            );
        }
        "cleanup-virtual-mic" | "destroy-virtual-mic" => cleanup_virtual_microphone()?,
        "test-virtual-mic" | "test-input" => {
            let seconds = duration(args.get(1), 3., 30.)?;
            let actual = record(&recording_target()?, seconds, &path())?;
            println!("Recorded {actual:.2}s to {}", path().display());
            playback(&path())?;
        }
        "test-tone" => tone_test()?,
        "test-desktop" => desktop_test()?,
        "diagnose" => {
            let all = devices()?;
            list_devices(&all);
            if all.is_empty() {
                return Err(Error::message(
                    "no devices visible; cannot validate audio pipeline",
                ));
            }
            let source = target()?;
            println!("Loopback: {} ({}Hz)", source.name, source.rate);
            let own: Vec<_> = processes()?
                .into_iter()
                .filter(|p| p.pid == std::process::id() as i32)
                .collect();
            println!(
                "Self-process IDs: {:?}",
                own.iter().map(|p| p.id).collect::<Vec<_>>()
            );
            if own.is_empty() {
                return Err(Error::message("self-exclusion unresolved"));
            }
            println!(
                "Hardware enumeration completed. Capture permission, effective stream conversion, and continuity require test-desktop/test-tone; not proven by enumeration."
            );
        }
        "watch-input" => {
            let seconds = duration(args.get(1), 60., 3600.)?;
            let end = Instant::now() + Duration::from_secs_f64(seconds);
            let mut previous: Option<Vec<Device>> = None;
            println!(
                "Watching audio device changes every 500ms. Browser input tracks and the process responsible for changes are not observable here."
            );
            while RUNNING.load(Ordering::Relaxed) && Instant::now() < end {
                let mut all = devices()?;
                all.sort_by(|a, b| a.uid.cmp(&b.uid));
                if previous.as_ref() != Some(&all) {
                    println!("Time: {:?}", std::time::SystemTime::now());
                    if let Some(old) = &previous {
                        for d in old
                            .iter()
                            .filter(|d| !all.iter().any(|new| new.uid == d.uid))
                        {
                            println!("REMOVED {} uid={}", d.name, d.uid);
                        }
                    }
                    list_devices(&all);
                    previous = Some(all);
                }
                std::thread::sleep(Duration::from_millis(500));
            }
        }
        _ => {
            return Err(Error::message(format!(
                "unknown command: {} (use --help)",
                args[0]
            )));
        }
    }
    Ok(())
}
fn tone_test() -> Result<()> {
    let output = target()?;
    let _aggregate = Aggregate::virtual_microphone(&output)?;
    let input = recording_target()?;
    let mut engine = Engine::new(output.clone())?;
    let source = engine.add_generator()?;
    let path = path();
    let capture_path = path.clone();
    let capture = std::thread::spawn(move || record(&input, 3., &capture_path));
    let start = Instant::now();
    let mut phase = 0f64;
    let mut samples = [0.; 1024];
    while RUNNING.load(Ordering::Relaxed) && start.elapsed() < Duration::from_secs(4) {
        for frame in samples.chunks_exact_mut(2) {
            let sample = (phase.sin() * 0.5) as f32;
            frame.fill(sample);
            phase = (phase + 2. * std::f64::consts::PI * 440. / output.rate)
                % (2. * std::f64::consts::PI);
        }
        source.ring.write(&samples);
        std::thread::sleep(Duration::from_secs_f64(512. / output.rate));
    }
    capture
        .join()
        .map_err(|_| Error::message("capture thread failed"))??;
    engine.shutdown();
    validate_recording(&path)?;
    playback(&path)
}
fn desktop_test() -> Result<()> {
    let output = target()?;
    let _aggregate = Aggregate::virtual_microphone(&output)?;
    let mut engine = Engine::new(output)?;
    engine.desktop(true, &[])?;
    let input = recording_target()?;
    let path = path();
    let capture_path = path.clone();
    let capture = std::thread::spawn(move || record(&input, 3., &capture_path));
    std::thread::sleep(Duration::from_millis(300));
    let status = std::process::Command::new("/usr/bin/afplay")
        .arg("/System/Library/Sounds/Ping.aiff")
        .status()
        .map_err(|e| Error::message(e.to_string()))?;
    capture
        .join()
        .map_err(|_| Error::message("capture thread failed"))??;
    engine.shutdown();
    if !status.success() {
        return Err(Error::message("test sound playback failed"));
    }
    validate_recording(&path)?;
    playback(&path)
}
fn validate_recording(path: &std::path::Path) -> Result<()> {
    let bytes = std::fs::read(path).map_err(|e| Error::message(e.to_string()))?;
    let peak = bytes
        .get(44..)
        .unwrap_or_default()
        .chunks_exact(2)
        .map(|s| i16::from_le_bytes([s[0], s[1]]).unsigned_abs())
        .max()
        .unwrap_or(0);
    println!("Recorded peak: {peak}/32767");
    if peak < 100 {
        return Err(Error::message("recording has no meaningful test signal"));
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn durations_are_bounded() {
        assert_eq!(duration(None, 3., 30.).unwrap(), 3.);
        assert_eq!(duration(Some(&"100".into()), 3., 30.).unwrap(), 30.);
        assert!(duration(Some(&"NaN".into()), 3., 30.).is_err());
    }
    #[test]
    fn unknown_command_fails_without_hardware() {
        assert!(run(&["invalid".into()]).is_err());
    }
}
