//! Native AppKit menu-bar application. All UI and engine topology changes are
//! owned by the main thread; only bounded audio processing runs in IOProcs.
use objc2::{
    AnyThread, DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send,
    rc::Retained, runtime::ProtocolObject, sel,
};
use objc2_app_kit::*;
use objc2_foundation::{
    NSArray, NSNotification, NSObject, NSObjectProtocol, NSPoint, NSRect, NSSize, NSString,
    NSTimer, NSUserDefaults,
};
use router_macos::*;
use std::{cell::RefCell, collections::BTreeMap, path::PathBuf, time::Instant};

struct State {
    status: Option<Retained<NSStatusItem>>,
    popover: Option<Retained<NSPopover>>,
    timer: Option<Retained<NSTimer>>,
    engine: Option<Engine>,
    microphone: Option<Aggregate>,
    aggregates: Vec<Aggregate>,
    observer: Option<DeviceObserver>,
    devices: Vec<Device>,
    exclusions: Vec<String>,
    actions: Vec<Action>,
    meters: Vec<(String, Retained<NSTextField>)>,
    value_labels: Vec<(String, Retained<NSTextField>)>,
    desktop_gain: f32,
    desktop_muted: bool,
    meter_enabled: bool,
    mic_controls: BTreeMap<String, (f32, bool)>,
    recording: Option<RecordingJob>,
    recording_start: Option<Instant>,
    recorded: bool,
    player: Option<Player>,
    test_label: Option<Retained<NSTextField>>,
    message: String,
    workspace_dirty: bool,
    smoke_ticks: Option<u32>,
    scroll: Option<Retained<NSScrollView>>,
    advanced: bool,
    pending_test_sound: bool,
    test_sound: Option<std::process::Child>,
    last_report: Option<RecordingReport>,
    test_desktop_in_app: bool,
    test_deadline: Option<Instant>,
}
impl Default for State {
    fn default() -> Self {
        Self {
            status: None,
            popover: None,
            timer: None,
            engine: None,
            microphone: None,
            aggregates: Vec::new(),
            observer: None,
            devices: Vec::new(),
            exclusions: Vec::new(),
            actions: Vec::new(),
            meters: Vec::new(),
            value_labels: Vec::new(),
            desktop_gain: 1.,
            desktop_muted: false,
            meter_enabled: true,
            mic_controls: BTreeMap::new(),
            recording: None,
            recording_start: None,
            recorded: false,
            player: None,
            test_label: None,
            message: String::new(),
            workspace_dirty: false,
            smoke_ticks: None,
            scroll: None,
            advanced: false,
            pending_test_sound: false,
            test_sound: None,
            last_report: None,
            test_desktop_in_app: false,
            test_deadline: None,
        }
    }
}
impl State {
    fn path(&self) -> PathBuf {
        std::env::temp_dir().join(format!("app_audio_router_{}_test.wav", std::process::id()))
    }
    fn refresh(&mut self) {
        match devices() {
            Ok(all) => {
                let invalid = self.engine.as_ref().is_some_and(|engine| {
                    !all.iter().any(|d| {
                        d.id == engine.output_device.id
                            && d.uid == engine.output_device.uid
                            && (d.rate - engine.output_device.rate).abs() < 0.5
                    })
                });
                if invalid {
                    self.engine = None;
                    self.scroll = None;
                    self.message =
                        "Output changed or disappeared. Enable routing again after refreshing."
                            .into();
                }
                self.devices = all;
                self.observer = DeviceObserver::new(&self.devices).ok();
            }
            Err(e) => self.message = e.to_string(),
        }
    }
    fn setup(&mut self) -> Result<()> {
        self.refresh();
        let output=loopback(&self.devices).cloned().ok_or_else(||Error::message("Install BlackHole 2ch, then Refresh. Keep your physical mic as the macOS default input."))?;
        let microphone = Aggregate::virtual_microphone(&output)?;
        if self
            .engine
            .as_ref()
            .is_none_or(|e| e.output_device.id != output.id)
        {
            if let Some(engine) = &mut self.engine {
                engine.shutdown();
            }
            self.engine = Some(Engine::new(output)?);
        }
        // Repeated setup must retain existing ownership, rather than replacing
        // an owned aggregate with a borrowed handle to the same device.
        if self
            .microphone
            .as_ref()
            .is_none_or(|m| m.id != microphone.id)
        {
            self.microphone = Some(microphone);
        }
        self.refresh();
        Ok(())
    }
    fn stop_test_sound(&mut self) {
        self.pending_test_sound = false;
        if let Some(mut child) = self.test_sound.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
    fn playback(&mut self) -> Result<()> {
        if self.devices.iter().any(|d| {
            d.default_output
                && self
                    .engine
                    .as_ref()
                    .is_some_and(|engine| engine.output_device.uid == d.uid)
        }) {
            return Err(Error::message(
                "Playback is set to the loopback device, so you cannot hear it. Choose speakers or headphones under System output.",
            ));
        }
        self.player = Some(Player::play(&self.path())?);
        Ok(())
    }
    fn begin_recording(&mut self, test_sound: bool) -> Result<()> {
        if self.recording.is_some() {
            return Err(Error::message(
                "Stop the current recording before starting another test.",
            ));
        }
        if self.engine.is_none() {
            self.setup()?;
        }
        if test_sound {
            if self.desktop_muted || self.desktop_gain <= 0.0001 {
                return Err(Error::message(
                    "Unmute Desktop audio and raise its volume before testing the desktop route.",
                ));
            }
            if self.source("desktop").is_none() {
                if let Some(source) = self
                    .engine
                    .as_mut()
                    .unwrap()
                    .desktop(true, &self.exclusions)?
                {
                    source.controls.set_gain(self.desktop_gain);
                }
            }
        } else if self
            .engine
            .as_ref()
            .is_none_or(|engine| engine.diagnostics().is_empty())
        {
            return Err(Error::message(
                "No sources are enabled. Turn on Desktop audio and play sound in another app, or turn on a microphone below. Use Test desktop route for an automatic test sound.",
            ));
        }
        self.player = None;
        self.stop_test_sound();
        self.refresh();
        let output_uid = self
            .engine
            .as_ref()
            .ok_or_else(|| Error::message("Routing output changed. Enable the route again."))?
            .output_device
            .uid
            .clone();
        // Read the same loopback input browsers use, rather than an aggregate
        // that may be borrowed from a different client.
        let target = recording_input(&self.devices, &output_uid)?;
        self.recording = Some(RecordingJob::start(target, 5., self.path()));
        self.recording_start = None;
        self.recorded = false;
        self.last_report = None;
        self.pending_test_sound = test_sound;
        self.message=if test_sound {"The test sound will play when capture is ready, then the recording will play back."} else {"Recording only enabled sources. Play audio in another app and/or speak into an enabled microphone."}.into();
        Ok(())
    }
    fn close(&mut self) {
        self.stop_test_sound();
        if let Some(timer) = self.timer.take() {
            timer.invalidate();
        }
        self.recording = None;
        self.player = None;
        if let Some(engine) = &mut self.engine {
            engine.shutdown();
        }
        self.engine = None;
        self.aggregates.clear();
        self.microphone = None;
        self.observer = None;
        let _ = std::fs::remove_file(self.path());
    }
    fn source(&self, key: &str) -> Option<std::sync::Arc<Source>> {
        self.engine.as_ref().and_then(|e| e.source(key))
    }
}
#[derive(Clone)]
enum Action {
    Desktop,
    MuteDesktop,
    Meter,
    DesktopGain,
    Mic(String),
    MicMute(String),
    MicGain(String),
    Exclude(String),
    DefaultInput,
    DefaultOutput,
    Setup,
    Refresh,
    Record,
    TestDesktop,
    Advanced,
    StopRecord,
    Play,
    StopPlay,
    Clear,
    MultiOutput,
    MultiInput,
    Restart,
    Quit,
}
#[derive(Default)]
struct Ivars {
    state: RefCell<State>,
}
define_class!(
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[ivars = Ivars]
    struct Delegate;
    unsafe impl NSObjectProtocol for Delegate {}
    unsafe impl NSApplicationDelegate for Delegate {
        #[unsafe(method(applicationDidFinishLaunching:))]
        fn launched(&self,_notification:&NSNotification){self.start();}
        #[unsafe(method(applicationWillTerminate:))]
        fn terminate(&self,_notification:&NSNotification){unsafe { NSWorkspace::sharedWorkspace().notificationCenter().removeObserver(self); } self.ivars().state.borrow_mut().close();}
        #[unsafe(method(applicationShouldTerminateAfterLastWindowClosed:))]
        fn keep_running(&self,_sender:&NSApplication)->bool{false}
    }
    impl Delegate {
        #[unsafe(method(showControls:))]
        fn show_controls(&self,_sender:&NSObject){
            {let mut state=self.ivars().state.borrow_mut();state.refresh();state.scroll=None;}self.rebuild();
            let state=self.ivars().state.borrow();
            if let (Some(popover),Some(status))=(&state.popover,&state.status){if popover.isShown(){popover.close();}else if let Some(button)=status.button(self.mtm()){popover.showRelativeToRect_ofView_preferredEdge(button.bounds(),&button,objc2_foundation::NSRectEdge::MinY);}}
        }
        #[unsafe(method(control:))]
        fn control(&self,sender:&NSControl){
            let action={let state=self.ivars().state.borrow();state.actions.get(sender.tag() as usize).cloned()};
            if let Some(action)=action {let rebuild=!matches!(action,Action::DesktopGain|Action::MicGain(_));let result=self.perform(action,sender);if let Err(error)=result{{let mut state=self.ivars().state.borrow_mut();state.message=error.to_string();state.scroll=None;}self.rebuild();}else if rebuild{self.rebuild();}}
        }
        #[unsafe(method(workspaceChanged:))]
        fn workspace_changed(&self,_notification:&NSNotification){self.ivars().state.borrow_mut().workspace_dirty=true;}
        #[unsafe(method(tick:))]
        fn tick(&self,_timer:&NSTimer){self.update();}
    }
);
impl Delegate {
    fn start(&self) {
        let mtm = self.mtm();
        let mut state = self.ivars().state.borrow_mut();
        let defaults = NSUserDefaults::standardUserDefaults();
        if let Some(ids) =
            defaults.stringArrayForKey(&NSString::from_str("desktopTapExcludedBundleIDs"))
        {
            state.exclusions = ids.iter().map(|s| s.to_string()).collect();
        }
        if let Err(error) = state.setup() {
            state.message = error.to_string();
        }
        let status =
            NSStatusBar::systemStatusBar().statusItemWithLength(NSVariableStatusItemLength);
        if let Some(button) = status.button(mtm) {
            button.setTitle(&NSString::from_str("Audio"));
            button.setImagePosition(NSCellImagePosition::ImageLeading);
            button.setToolTip(Some(&NSString::from_str(
                "AppAudioRouter — audio routing and tests",
            )));
            if let Some(image) = NSImage::imageWithSystemSymbolName_accessibilityDescription(
                &NSString::from_str("waveform.circle.fill"),
                Some(&NSString::from_str("AppAudioRouter")),
            ) {
                image.setTemplate(true);
                button.setImage(Some(&image));
            } else {
                button.setTitle(&NSString::from_str("Audio"));
            }
            unsafe {
                button.setTarget(Some(self));
                button.setAction(Some(sel!(showControls:)));
            }
        }
        let center = NSWorkspace::sharedWorkspace().notificationCenter();
        unsafe {
            center.addObserver_selector_name_object(
                self,
                sel!(workspaceChanged:),
                Some(NSWorkspaceDidLaunchApplicationNotification),
                None,
            );
            center.addObserver_selector_name_object(
                self,
                sel!(workspaceChanged:),
                Some(NSWorkspaceDidTerminateApplicationNotification),
                None,
            );
        }
        state.status = Some(status);
        state.popover = Some(NSPopover::new(mtm));
        state
            .popover
            .as_ref()
            .unwrap()
            .setBehavior(NSPopoverBehavior::Transient);
        state.timer = Some(unsafe {
            NSTimer::scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
                0.05,
                self,
                sel!(tick:),
                None,
                true,
            )
        });
        let test_desktop = state.test_desktop_in_app;
        drop(state);
        self.rebuild();
        if test_desktop {
            let result = self.ivars().state.borrow_mut().begin_recording(true);
            if let Err(error) = result {
                eprintln!("In-app desktop test failed: {error}");
                self.ivars().state.borrow_mut().close();
                std::process::exit(1);
            }
        }
    }
    fn perform(&self, action: Action, sender: &NSControl) -> Result<()> {
        let mut state = self.ivars().state.borrow_mut();
        state.message.clear();
        match action {
            Action::Desktop => {
                if state.engine.is_none() {
                    state.setup()?;
                }
                let enabled = state.source("desktop").is_none();
                let exclusions = state.exclusions.clone();
                let source = state
                    .engine
                    .as_mut()
                    .unwrap()
                    .desktop(enabled, &exclusions)?;
                if let Some(source) = source {
                    source.controls.set_gain(state.desktop_gain);
                    source.controls.set_muted(state.desktop_muted);
                }
            }
            Action::MuteDesktop => {
                state.desktop_muted = !state.desktop_muted;
                if let Some(source) = state.source("desktop") {
                    source.controls.set_muted(state.desktop_muted);
                }
            }
            Action::Meter => state.meter_enabled = !state.meter_enabled,
            Action::DesktopGain => {
                state.desktop_gain = sender.doubleValue() as f32;
                if let Some(source) = state.source("desktop") {
                    source.controls.set_gain(state.desktop_gain);
                }
            }
            Action::Mic(uid) => {
                if state.engine.is_none() {
                    state.setup()?;
                }
                let device = state
                    .devices
                    .iter()
                    .find(|d| d.uid == uid)
                    .cloned()
                    .ok_or_else(|| Error::message("microphone disappeared"))?;
                let enabled = state.source(&uid).is_none();
                let source = state
                    .engine
                    .as_mut()
                    .unwrap()
                    .microphone(&device, enabled)?;
                if let Some(source) = source {
                    let (gain, muted) =
                        state.mic_controls.get(&uid).copied().unwrap_or((1., false));
                    source.controls.set_gain(gain);
                    source.controls.set_muted(muted);
                }
            }
            Action::MicMute(uid) => {
                let settings = state.mic_controls.entry(uid.clone()).or_insert((1., false));
                settings.1 = !settings.1;
                let muted = settings.1;
                if let Some(source) = state.source(&uid) {
                    source.controls.set_muted(muted);
                }
            }
            Action::MicGain(uid) => {
                let gain = sender.doubleValue() as f32;
                state
                    .mic_controls
                    .entry(uid.clone())
                    .or_insert((1., false))
                    .0 = gain;
                if let Some(source) = state.source(&uid) {
                    source.controls.set_gain(gain);
                }
            }
            Action::Exclude(bundle) => {
                if state.exclusions.contains(&bundle) {
                    state.exclusions.retain(|id| id != &bundle);
                } else {
                    state.exclusions.push(bundle);
                }
                state.exclusions.sort();
                let array = NSArray::from_retained_slice(
                    &state
                        .exclusions
                        .iter()
                        .map(|s| NSString::from_str(s))
                        .collect::<Vec<_>>(),
                );
                unsafe {
                    NSUserDefaults::standardUserDefaults().setObject_forKey(
                        Some(&array),
                        &NSString::from_str("desktopTapExcludedBundleIDs"),
                    );
                }
                if state.source("desktop").is_some() {
                    let exclusions = state.exclusions.clone();
                    if let Some(source) =
                        state.engine.as_mut().unwrap().desktop(true, &exclusions)?
                    {
                        source.controls.set_gain(state.desktop_gain);
                        source.controls.set_muted(state.desktop_muted);
                    }
                }
            }
            Action::DefaultInput | Action::DefaultOutput => {
                let popup = sender
                    .downcast_ref::<NSPopUpButton>()
                    .ok_or_else(|| Error::message("invalid device selector"))?;
                if let Some(item) = popup.selectedItem() {
                    if matches!(action, Action::DefaultInput) {
                        set_default_input(item.tag() as u32)?;
                    } else {
                        set_default_output(item.tag() as u32)?;
                    }
                }
                state.refresh();
            }
            Action::Setup => state.setup()?,
            Action::Refresh => state.refresh(),
            Action::Record => state.begin_recording(false)?,
            Action::TestDesktop => state.begin_recording(true)?,
            Action::Advanced => state.advanced = !state.advanced,
            Action::StopRecord => {
                if let Some(job) = &state.recording {
                    job.stop();
                }
            }
            Action::Play => {
                state.playback()?;
            }
            Action::StopPlay => state.player = None,
            Action::Clear => {
                state.stop_test_sound();
                state.last_report = None;
                state.recording = None;
                state.player = None;
                state.recorded = false;
                let _ = std::fs::remove_file(state.path());
            }
            Action::MultiOutput | Action::MultiInput => {
                let stacked = matches!(action, Action::MultiOutput);
                let all = state.devices.clone();
                drop(state);
                self.aggregate_dialog(&all, stacked)?;
                return Ok(());
            }
            Action::Restart => {
                drop(state);
                let script = NSString::from_str(
                    "do shell script \"launchctl kickstart -kp system/com.apple.audio.coreaudiod\" with administrator privileges",
                );
                let script = objc2_foundation::NSAppleScript::initWithSource(
                    objc2_foundation::NSAppleScript::alloc(),
                    &script,
                )
                .ok_or_else(|| Error::message("cannot construct driver restart request"))?;
                unsafe {
                    script.executeAndReturnError(None);
                }
                self.ivars().state.borrow_mut().refresh();
                return Ok(());
            }
            Action::Quit => {
                state.close();
                drop(state);
                NSApplication::sharedApplication(self.mtm()).terminate(None);
                return Ok(());
            }
        }
        Ok(())
    }
    fn aggregate_dialog(&self, all: &[Device], stacked: bool) -> Result<()> {
        let mtm = self.mtm();
        let candidates: Vec<_> = all
            .iter()
            .filter(|d| {
                !d.aggregate
                    && if stacked {
                        d.output_channels > 0
                    } else {
                        d.input_channels > 0
                    }
            })
            .collect();
        let alert = NSAlert::new(mtm);
        alert.setMessageText(&NSString::from_str(if stacked {
            "Create Multi-Output Device"
        } else {
            "Create Aggregate Microphone"
        }));
        alert.setInformativeText(&NSString::from_str(
            "Select devices. The system default input will not be changed.",
        ));
        alert.addButtonWithTitle(&NSString::from_str("Create"));
        alert.addButtonWithTitle(&NSString::from_str("Cancel"));
        let view = NSView::initWithFrame(
            NSView::alloc(mtm),
            rect(0., 0., 340., 40. + candidates.len() as f64 * 28.),
        );
        let name = NSTextField::initWithFrame(NSTextField::alloc(mtm), rect(0., 0., 340., 24.));
        name.setStringValue(&NSString::from_str(if stacked {
            "AppAudioRouter Multi-Output"
        } else {
            "Combined Microphones"
        }));
        view.addSubview(&name);
        let mut checks = Vec::new();
        for (i, device) in candidates.iter().enumerate() {
            let button = unsafe {
                NSButton::buttonWithTitle_target_action(
                    &NSString::from_str(&device.name),
                    None,
                    None,
                    mtm,
                )
            };
            button.setButtonType(NSButtonType::Switch);
            button.setFrame(rect(0., 32. + i as f64 * 28., 340., 24.));
            view.addSubview(&button);
            checks.push(button);
        }
        alert.setAccessoryView(Some(&view));
        if alert.runModal() != NSAlertFirstButtonReturn {
            return Ok(());
        }
        let uids: Vec<_> = candidates
            .iter()
            .zip(&checks)
            .filter(|(_, button)| button.state() == NSControlStateValueOn)
            .map(|(device, _)| device.uid.clone())
            .collect();
        if uids.len() < if stacked { 2 } else { 1 } {
            return Err(Error::message("select enough devices"));
        }
        let aggregate =
            Aggregate::create(&name.stringValue().to_string(), &uids, stacked, false, None)?;
        self.ivars().state.borrow_mut().aggregates.push(aggregate);
        self.ivars().state.borrow_mut().refresh();
        Ok(())
    }
    fn update(&self) {
        let mut state = self.ivars().state.borrow_mut();
        if let Some(ticks) = state.smoke_ticks.as_mut() {
            if *ticks == 0 {
                assert!(
                    state.status.is_some() && state.popover.is_some(),
                    "native UI did not initialize"
                );
                if let Ok(path) = std::env::var("AAR_PREVIEW_PNG") {
                    if let Some(scroll) = &state.scroll {
                        let bounds = scroll.bounds();
                        if let Some(bitmap) = scroll.bitmapImageRepForCachingDisplayInRect(bounds) {
                            scroll.cacheDisplayInRect_toBitmapImageRep(bounds, &bitmap);
                            let properties = objc2_foundation::NSDictionary::new();
                            if let Some(data) = unsafe {
                                bitmap.representationUsingType_properties(
                                    NSBitmapImageFileType::PNG,
                                    &properties,
                                )
                            } {
                                assert!(
                                    data.writeToFile_atomically(&NSString::from_str(&path), true),
                                    "could not write native preview"
                                );
                            }
                        }
                    }
                }
                drop(state);
                eprintln!("Rust AppKit startup/shutdown smoke test passed");
                NSApplication::sharedApplication(self.mtm()).terminate(None);
                return;
            }
            *ticks -= 1;
        }
        if state.test_desktop_in_app
            && (state
                .test_deadline
                .is_some_and(|deadline| Instant::now() >= deadline)
                || (state.recording.is_none()
                    && state.last_report.is_some()
                    && state.player.is_none()))
        {
            if let Some(report) = state.last_report {
                eprintln!(
                    "In-app desktop test: {:.2}s, peak={:.5}, signal={}",
                    report.duration,
                    report.peak,
                    report.has_signal()
                );
            }
            let success = state.recording.is_none()
                && state.player.is_none()
                && state.last_report.is_some_and(|report| report.has_signal());
            state.close();
            drop(state);
            std::process::exit(if success { 0 } else { 1 });
        }
        let dirty = state.workspace_dirty
            | state
                .observer
                .as_ref()
                .is_some_and(DeviceObserver::take_changed);
        state.workspace_dirty = false;
        if dirty {
            state.refresh();
        }
        if state.recording_start.is_none()
            && state.recording.as_ref().is_some_and(RecordingJob::ready)
        {
            state.recording_start = Some(Instant::now());
        }
        if state.pending_test_sound && state.recording.as_ref().is_some_and(RecordingJob::ready) {
            state.pending_test_sound = false;
            match std::process::Command::new("/usr/bin/afplay")
                .arg("/System/Library/Sounds/Ping.aiff")
                .spawn()
            {
                Ok(child) => state.test_sound = Some(child),
                Err(error) => {
                    state.message = format!("Could not play test sound: {error}");
                    if let Some(recording) = &state.recording {
                        recording.stop();
                    }
                }
            }
        }
        if let Some(child) = &mut state.test_sound {
            if matches!(child.try_wait(), Ok(Some(_))) {
                state.test_sound = None;
            }
        }
        if let Some(result) = state.recording.as_ref().and_then(RecordingJob::poll) {
            state.stop_test_sound();
            state.recording = None;
            state.recording_start = None;
            state.scroll = None;
            match result {
                Ok(report) => {
                    state.recorded = true;
                    state.last_report = Some(report);
                    if report.has_signal() {
                        state.message = format!(
                            "Recorded {:.1}s — peak {:.0}%. Playing through your System output.",
                            report.duration,
                            report.peak * 100.
                        );
                        if let Err(error) = state.playback() {
                            state.message = error.to_string();
                        }
                    } else {
                        state.message="No audible signal was recorded. Play audio in another app or enable a microphone. Check microphone/system-audio permission if the meters stay at zero.".into();
                    }
                }
                Err(error) => state.message = error.to_string(),
            }
            drop(state);
            self.rebuild();
            return;
        }
        if state.player.as_ref().is_some_and(|p| !p.is_playing()) {
            state.player = None;
            drop(state);
            self.rebuild();
            return;
        }
        let visible = state.popover.as_ref().is_some_and(|p| p.isShown());
        if visible {
            for (key, label) in &state.value_labels {
                let gain = if key == "desktop" {
                    state.desktop_gain
                } else {
                    state
                        .mic_controls
                        .get(key)
                        .map_or(1., |settings| settings.0)
                };
                label.setStringValue(&NSString::from_str(&format!("{:.0}%", gain * 100.)));
            }
            for (key, label) in &state.meters {
                let peak = if state.meter_enabled {
                    state.source(key).map_or(0., |s| s.controls.peak())
                } else {
                    0.
                };
                let text = if state.source(key).is_some() {
                    format!("Input level: {:3.0}%", peak * 100.)
                } else {
                    "Not being sent to virtual mic".into()
                };
                label.setStringValue(&NSString::from_str(&text));
            }
            if let Some(label) = &state.test_label {
                let text = if let Some(job) = &state.recording {
                    if !job.ready() {
                        "Preparing capture — check any permission prompt".into()
                    } else {
                        format!(
                            "Recording {:.1}/5s — {:.0}%",
                            state
                                .recording_start
                                .map_or(0., |s| s.elapsed().as_secs_f64()),
                            job.peak() * 100.
                        )
                    }
                } else if let Some(player) = &state.player {
                    format!("Playing {:.1}/{:.1}s", player.elapsed(), player.duration())
                } else if let Some(report) = state.last_report {
                    if report.has_signal() {
                        format!(
                            "Recorded {:.1}s · peak {:.0}%",
                            report.duration,
                            report.peak * 100.
                        )
                    } else {
                        "No audible signal detected".into()
                    }
                } else {
                    "Ready".into()
                };
                label.setStringValue(&NSString::from_str(&text));
            }
        }
        drop(state);
        if dirty && visible {
            self.rebuild();
        }
    }
    fn rebuild(&self) {
        let mtm = self.mtm();
        let mut state = self.ivars().state.borrow_mut();
        let top_offset = state
            .scroll
            .as_ref()
            .and_then(|scroll| {
                scroll.documentView().map(|view| {
                    let visible = scroll.documentVisibleRect();
                    (view.frame().size.height - visible.origin.y - visible.size.height).max(0.)
                })
            })
            .unwrap_or(0.);
        state.actions.clear();
        state.meters.clear();
        state.value_labels.clear();
        let all = state.devices.clone();
        let advanced = state.advanced;
        let (active_bundles, bundles) = if advanced {
            let active_bundles: Vec<String> = processes()
                .unwrap_or_default()
                .into_iter()
                .map(|p| p.bundle_id)
                .collect();
            let mut bundles: Vec<String> = NSWorkspace::sharedWorkspace()
                .runningApplications()
                .iter()
                .filter(|app| app.activationPolicy() != NSApplicationActivationPolicy::Prohibited)
                .filter_map(|app| app.bundleIdentifier().map(|id| id.to_string()))
                .filter(|id| id != "com.devai.AppAudioRouter")
                .collect();
            bundles.extend(state.exclusions.clone());
            bundles.sort();
            bundles.dedup();
            (active_bundles, bundles)
        } else {
            (Vec::new(), Vec::new())
        };
        let physical: Vec<_> = all
            .iter()
            .filter(|d| d.input_channels > 0 && !d.aggregate && !d.virtual_device)
            .collect();
        let height = 960.
            + physical.len() as f64 * 200.
            + if advanced {
                500. + bundles.len() as f64 * 38.
            } else {
                0.
            };
        let view = NSView::initWithFrame(NSView::alloc(mtm), rect(0., 0., 480., height));
        let mut y = height - 48.;
        let title = label(&view, "AppAudioRouter", y, mtm);
        title.setFont(Some(&NSFont::boldSystemFontOfSize(22.)));
        y -= 30.;
        label(&view, "Desktop + microphone mixer · Rust preview", y, mtm);
        y -= 38.;
        let status = if state.message.is_empty() {
            "Enable the sources you want to send, then record a test."
        } else {
            &state.message
        };
        paragraph(&view, status, y - 52., 76., mtm);
        y -= 94.;
        heading(&view, "Test your audio", y, mtm);
        y -= 38.;
        let recording = state.recording.is_some();
        let test = self.button(
            &mut state,
            &view,
            "Test desktop route (plays a sound)",
            Action::TestDesktop,
            y,
        );
        test.setEnabled(!recording);
        y -= 38.;
        if recording {
            self.button(
                &mut state,
                &view,
                "Stop recording & play",
                Action::StopRecord,
                y,
            );
        } else {
            self.button(
                &mut state,
                &view,
                "Record enabled sources · 5 seconds",
                Action::Record,
                y,
            );
        }
        y -= 36.;
        if state.player.is_some() {
            self.button(&mut state, &view, "Stop playback", Action::StopPlay, y);
            y -= 34.;
        } else if state.recorded {
            self.button(&mut state, &view, "Play last recording", Action::Play, y);
            y -= 34.;
        }
        state.test_label = Some(label(
            &view,
            if state.recorded {
                "Recording ready"
            } else {
                "Ready — no recording yet"
            },
            y,
            mtm,
        ));
        y -= 30.;
        let playback = all
            .iter()
            .find(|d| d.default_output)
            .map_or("No output device", |d| d.name.as_str());
        label(&view, &format!("Playback → {playback}"), y, mtm);
        y -= 46.;
        heading(&view, "Desktop audio", y, mtm);
        y -= 36.;
        let desktop = state.source("desktop").is_some();
        self.button(
            &mut state,
            &view,
            if desktop {
                "✓ Desktop audio → virtual mic: ON"
            } else {
                "Desktop audio → virtual mic: OFF"
            },
            Action::Desktop,
            y,
        );
        y -= 38.;
        let muted = state.desktop_muted;
        self.button(
            &mut state,
            &view,
            if muted {
                "Desktop is muted — click to unmute"
            } else {
                "Mute desktop audio"
            },
            Action::MuteDesktop,
            y,
        );
        y -= 34.;
        let gain = state.desktop_gain as f64;
        self.slider(&mut state, &view, Action::DesktopGain, gain, y);
        y -= 30.;
        let meter = label(&view, "Desktop level: 0%", y, mtm);
        state.meters.push(("desktop".into(), meter));
        y -= 44.;
        heading(&view, "Microphones", y, mtm);
        y -= 32.;
        if physical.is_empty() {
            label(
                &view,
                "No physical microphones found. Check permissions.",
                y,
                mtm,
            );
            y -= 32.;
        }
        let output_rate = state.engine.as_ref().map(|e| e.output_device.rate);
        for mic in physical {
            let name = label(&view, &mic.name, y, mtm);
            name.setFont(Some(&NSFont::boldSystemFontOfSize(15.)));
            y -= 30.;
            let compatible = output_rate.is_none_or(|rate| (mic.rate - rate).abs() < 0.5);
            if compatible {
                label(
                    &view,
                    &format!("{} channels · {} Hz", mic.input_channels, mic.rate as u32),
                    y,
                    mtm,
                );
            } else {
                label(
                    &view,
                    "Sample rate differs — use a 48 kHz microphone.",
                    y,
                    mtm,
                );
            }
            y -= 32.;
            let routed = state.source(&mic.uid).is_some();
            let button = self.button(
                &mut state,
                &view,
                if routed {
                    "✓ Send microphone: ON"
                } else {
                    "Send microphone to virtual mic: OFF"
                },
                Action::Mic(mic.uid.clone()),
                y,
            );
            button.setEnabled(compatible);
            y -= 32.;
            let (gain, muted) = state
                .mic_controls
                .get(&mic.uid)
                .copied()
                .unwrap_or((1., false));
            self.slider(
                &mut state,
                &view,
                Action::MicGain(mic.uid.clone()),
                gain as f64,
                y,
            );
            y -= 30.;
            self.button(
                &mut state,
                &view,
                if muted {
                    "Microphone muted — click to unmute"
                } else {
                    "Mute microphone"
                },
                Action::MicMute(mic.uid.clone()),
                y,
            );
            y -= 30.;
            let meter = label(
                &view,
                if routed {
                    "Microphone level: 0%"
                } else {
                    "Microphone is not being sent"
                },
                y,
                mtm,
            );
            state.meters.push((mic.uid.clone(), meter));
            y -= 38.;
        }
        paragraph(
            &view,
            "In Brave/Chrome, select BlackHole 2ch as the site microphone. Keep your physical mic as the macOS default input.",
            y - 26.,
            54.,
            mtm,
        );
        y -= 76.;
        self.button(
            &mut state,
            &view,
            if advanced {
                "Hide device settings & app exclusions"
            } else {
                "Device settings & app exclusions…"
            },
            Action::Advanced,
            y,
        );
        y -= 42.;
        if advanced {
            heading(&view, "System devices", y, mtm);
            y -= 30.;
            for (input, title) in [
                (false, "System output (playback)"),
                (true, "System input (changes macOS default)"),
            ] {
                label(&view, title, y, mtm);
                y -= 30.;
                let popup = NSPopUpButton::initWithFrame_pullsDown(
                    NSPopUpButton::alloc(mtm),
                    rect(18., y, 444., 30.),
                    false,
                );
                popup.setFont(Some(&NSFont::systemFontOfSize(14.)));
                for device in all.iter().filter(|d| {
                    if input {
                        d.input_channels > 0
                            && (d.default_input || !d.virtual_device || d.is_app_microphone())
                    } else {
                        d.output_channels > 0 && (!d.virtual_device || d.aggregate)
                    }
                }) {
                    popup.addItemWithTitle(&NSString::from_str(&device.name));
                    if let Some(item) = popup.lastItem() {
                        item.setTag(device.id as isize);
                    }
                    if if input {
                        device.default_input
                    } else {
                        device.default_output
                    } {
                        popup.selectItem(popup.lastItem().as_deref());
                    }
                }
                self.wire(
                    &mut state,
                    &popup,
                    if input {
                        Action::DefaultInput
                    } else {
                        Action::DefaultOutput
                    },
                );
                view.addSubview(&popup);
                y -= 42.;
            }
            self.button(
                &mut state,
                &view,
                "Create / verify virtual microphone",
                Action::Setup,
                y,
            );
            y -= 42.;
            heading(&view, "Exclude these apps from desktop capture", y, mtm);
            y -= 36.;
            for bundle in bundles {
                let selected = state.exclusions.contains(&bundle);
                let unresolved = selected
                    && !active_bundles.iter().any(|active| {
                        active == &bundle
                            || active
                                .strip_prefix(&bundle)
                                .is_some_and(|s| s.starts_with('.'))
                    });
                self.button(
                    &mut state,
                    &view,
                    &format!(
                        "{} {}{}",
                        if selected { "✓" } else { "○" },
                        bundle,
                        if unresolved { " (unresolved)" } else { "" }
                    ),
                    Action::Exclude(bundle),
                    y,
                );
                y -= 38.;
            }
            let meter_enabled = state.meter_enabled;
            self.button(
                &mut state,
                &view,
                if meter_enabled {
                    "Level meters: ON"
                } else {
                    "Level meters: OFF"
                },
                Action::Meter,
                y,
            );
            y -= 38.;
            for (text, action) in [
                ("Create multi-output device…", Action::MultiOutput),
                ("Combine microphones…", Action::MultiInput),
                ("Restart audio driver…", Action::Restart),
                ("Clear test recording", Action::Clear),
            ] {
                self.button(&mut state, &view, text, action, y);
                y -= 38.;
            }
        }
        self.button(&mut state, &view, "Refresh devices", Action::Refresh, y);
        y -= 38.;
        self.button(&mut state, &view, "Quit AppAudioRouter", Action::Quit, y);
        // Keep the visible position stable across route and meter changes.
        let scroll =
            NSScrollView::initWithFrame(NSScrollView::alloc(mtm), rect(0., 0., 480., 700.));
        scroll.setDrawsBackground(true);
        scroll.setBackgroundColor(&NSColor::windowBackgroundColor());
        scroll.setHasVerticalScroller(true);
        scroll.setDocumentView(Some(&view));
        let controller = NSViewController::new(mtm);
        controller.setView(&scroll);
        if let Some(popover) = &state.popover {
            popover.setContentViewController(Some(&controller));
            popover.setContentSize(NSSize::new(480., 700.));
        }
        view.scrollPoint(NSPoint::new(0., (height - 700. - top_offset).max(0.)));
        state.scroll = Some(scroll);
    }
    fn wire(&self, state: &mut State, control: &NSControl, action: Action) {
        let tag = state.actions.len();
        state.actions.push(action);
        control.setTag(tag as isize);
        unsafe {
            control.setTarget(Some(self));
            control.setAction(Some(sel!(control:)));
        }
    }
    fn button(
        &self,
        state: &mut State,
        view: &NSView,
        text: &str,
        action: Action,
        y: f64,
    ) -> Retained<NSButton> {
        let button = unsafe {
            NSButton::buttonWithTitle_target_action(
                &NSString::from_str(text),
                None,
                None,
                self.mtm(),
            )
        };
        button.setFrame(rect(18., y, 444., 32.));
        button.setFont(Some(&NSFont::systemFontOfSize(14.)));
        button.setBezelStyle(NSBezelStyle::Push);
        button.setToolTip(Some(&NSString::from_str(text)));
        self.wire(state, &button, action);
        view.addSubview(&button);
        button
    }
    fn slider(&self, state: &mut State, view: &NSView, action: Action, value: f64, y: f64) {
        let key = match &action {
            Action::DesktopGain => "desktop".to_owned(),
            Action::MicGain(uid) => uid.clone(),
            _ => String::new(),
        };
        let slider = unsafe {
            NSSlider::sliderWithValue_minValue_maxValue_target_action(
                value,
                0.,
                2.,
                None,
                None,
                self.mtm(),
            )
        };
        slider.setContinuous(false);
        slider.setFrame(rect(18., y, 340., 28.));
        self.wire(state, &slider, action);
        view.addSubview(&slider);
        let text = format!("{:.0}%", value * 100.);
        let field = NSTextField::labelWithString(&NSString::from_str(&text), self.mtm());
        field.setFrame(rect(380., y, 72., 28.));
        field.setFont(Some(&NSFont::systemFontOfSize(15.)));
        field.setTextColor(Some(&NSColor::labelColor()));
        view.addSubview(&field);
        state.value_labels.push((key, field));
    }
}
fn rect(x: f64, y: f64, w: f64, h: f64) -> NSRect {
    NSRect::new(NSPoint::new(x, y), NSSize::new(w, h))
}
fn label(view: &NSView, text: &str, y: f64, mtm: MainThreadMarker) -> Retained<NSTextField> {
    let label = NSTextField::labelWithString(&NSString::from_str(text), mtm);
    label.setFrame(rect(18., y, 444., 26.));
    label.setFont(Some(&NSFont::systemFontOfSize(15.)));
    label.setTextColor(Some(&NSColor::labelColor()));
    label.setToolTip(Some(&NSString::from_str(text)));
    view.addSubview(&label);
    label
}
fn heading(view: &NSView, text: &str, y: f64, mtm: MainThreadMarker) {
    let field = label(view, text, y, mtm);
    field.setFont(Some(&NSFont::boldSystemFontOfSize(17.)));
}
fn paragraph(view: &NSView, text: &str, y: f64, height: f64, mtm: MainThreadMarker) {
    let field = label(view, text, y, mtm);
    field.setFrame(rect(18., y, 444., height));
    field.setMaximumNumberOfLines(0);
    field.setLineBreakMode(NSLineBreakMode::ByWordWrapping);
    field.setSelectable(true);
}
fn main() {
    let mtm = MainThreadMarker::new().expect("AppKit must start on the main thread");
    let app = NSApplication::sharedApplication(mtm);
    app.setActivationPolicy(NSApplicationActivationPolicy::Regular);
    if std::env::args().any(|arg| arg == "--smoke-test")
        && std::env::var("AAR_PREVIEW_APPEARANCE").as_deref() == Ok("dark")
    {
        if let Some(appearance) = NSAppearance::appearanceNamed(unsafe { NSAppearanceNameDarkAqua })
        {
            app.setAppearance(Some(&appearance));
        }
    }
    let mut ivars = Ivars::default();
    if std::env::args().any(|arg| arg == "--smoke-test") {
        ivars.state.get_mut().smoke_ticks = Some(3);
    }
    if std::env::args().any(|arg| arg == "--test-desktop-in-app") {
        ivars.state.get_mut().test_desktop_in_app = true;
        ivars.state.get_mut().test_deadline =
            Some(Instant::now() + std::time::Duration::from_secs(30));
    }
    let delegate: Retained<Delegate> =
        unsafe { msg_send![super(Delegate::alloc(mtm).set_ivars(ivars)), init] };
    let menu = NSMenu::new(mtm);
    let app_item = NSMenuItem::new(mtm);
    let app_menu = NSMenu::new(mtm);
    unsafe {
        app_menu.addItemWithTitle_action_keyEquivalent(
            &NSString::from_str("Quit AppAudioRouter"),
            Some(sel!(terminate:)),
            &NSString::from_str("q"),
        );
    }
    app_item.setSubmenu(Some(&app_menu));
    menu.addItem(&app_item);
    app.setMainMenu(Some(&menu));
    app.setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
    app.run();
    let state = delegate.ivars().state.borrow();
    if state.test_desktop_in_app && !state.last_report.is_some_and(|report| report.has_signal()) {
        std::process::exit(1);
    }
}

fn recording_input(all: &[Device], output_uid: &str) -> Result<Device> {
    all.iter().find(|d|d.uid==output_uid && d.input_channels>0).cloned()
        .ok_or_else(||Error::message("The active loopback input is unavailable. Refresh devices and enable routing again."))
}
#[cfg(test)]
mod tests {
    use super::*;
    fn device(id: u32, uid: &str) -> Device {
        Device {
            id,
            uid: uid.into(),
            name: "Test device".into(),
            manufacturer: String::new(),
            input_channels: 2,
            output_channels: 2,
            rate: 48_000.,
            aggregate: false,
            virtual_device: true,
            default_input: false,
            default_output: false,
        }
    }
    fn state() -> State {
        State {
            engine: Some(Engine::new(device(1, "loopback")).unwrap()),
            ..State::default()
        }
    }
    #[test]
    fn no_enabled_sources_does_not_start_an_empty_test() {
        let mut state = state();
        let error = state.begin_recording(false).unwrap_err();
        assert!(error.to_string().contains("No sources are enabled"));
        assert!(state.recording.is_none());
    }
    #[test]
    fn muted_desktop_test_requires_user_to_unmute() {
        let mut state = state();
        state.desktop_muted = true;
        let error = state.begin_recording(true).unwrap_err();
        assert!(error.to_string().contains("Unmute"));
        assert!(state.recording.is_none());
    }
    #[test]
    fn recording_uses_active_loopback_not_unrelated_aggregate() {
        let mut aggregate = device(2, router_core::VIRTUAL_MIC_UID);
        aggregate.aggregate = true;
        let source = device(1, "loopback");
        assert_eq!(
            recording_input(&[aggregate, source], "loopback")
                .unwrap()
                .id,
            1
        );
        assert!(recording_input(&[], "loopback").is_err());
    }
}
