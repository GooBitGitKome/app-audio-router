use crate::{Error, Result, check, hardware::*};
use objc2_core_audio::*;
use objc2_core_audio_types::*;
use router_core::{AudioRing, BufferStats, Controls, clamp, wave_bytes};
use std::{
    cell::UnsafeCell,
    ffi::c_void,
    ptr::{self, NonNull},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

const MAX_FRAMES: usize = 16_384;
#[derive(Default)]
pub struct Source {
    pub ring: AudioRing,
    pub controls: Controls,
}
struct Context {
    output: bool,
    sources: Arc<Mutex<Vec<Arc<Source>>>>,
    input: Option<Arc<Source>>,
    scratch: UnsafeCell<Box<[f32]>>,
    entered: AtomicBool,
    calls: AtomicU64,
    invalid: AtomicU64,
}
// SAFETY: Callback scratch is protected by the non-waiting entered gate. Other
// fields are immutable, atomic, or protected by a mutex used only with try_lock
// from callbacks. The context has a stable allocation until IOProc destruction.
unsafe impl Sync for Context {}
struct Entered<'a>(&'a AtomicBool);
impl Drop for Entered<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}
unsafe fn buffers<'a>(list: NonNull<AudioBufferList>) -> &'a [AudioBuffer] {
    // SAFETY: HAL owns this valid AudioBufferList for the callback duration.
    let count = unsafe { list.as_ref().mNumberBuffers as usize };
    unsafe { std::slice::from_raw_parts(ptr::addr_of!((*list.as_ptr()).mBuffers).cast(), count) }
}
unsafe fn zero_output(list: NonNull<AudioBufferList>) {
    for buffer in unsafe { buffers(list) } {
        if !buffer.mData.is_null() {
            unsafe {
                ptr::write_bytes(buffer.mData.cast::<u8>(), 0, buffer.mDataByteSize as usize);
            }
        }
    }
}
unsafe fn read_stereo(list: NonNull<AudioBufferList>, scratch: &mut [f32]) -> Option<usize> {
    let buffers = unsafe { buffers(list) };
    let first = buffers.first()?;
    if first.mData.is_null() || first.mNumberChannels == 0 || first.mDataByteSize % 4 != 0 {
        return None;
    }
    let channels = first.mNumberChannels as usize;
    let frames = first.mDataByteSize as usize / 4 / channels;
    if frames > scratch.len() / 2 {
        return None;
    }
    let left = unsafe { std::slice::from_raw_parts(first.mData.cast::<f32>(), frames * channels) };
    if buffers.len() == 1 {
        for i in 0..frames {
            scratch[i * 2] = left[i * channels];
            scratch[i * 2 + 1] = left[i * channels + usize::from(channels > 1)];
        }
    } else {
        let right = buffers.get(1)?;
        if channels != 1
            || right.mNumberChannels != 1
            || right.mData.is_null()
            || right.mDataByteSize < first.mDataByteSize
        {
            return None;
        }
        let right = unsafe { std::slice::from_raw_parts(right.mData.cast::<f32>(), frames) };
        for i in 0..frames {
            scratch[i * 2] = left[i];
            scratch[i * 2 + 1] = right[i];
        }
    }
    Some(frames)
}
unsafe extern "C-unwind" fn callback(
    _device: u32,
    _now: NonNull<AudioTimeStamp>,
    input: NonNull<AudioBufferList>,
    _input_time: NonNull<AudioTimeStamp>,
    output: NonNull<AudioBufferList>,
    _output_time: NonNull<AudioTimeStamp>,
    client: *mut c_void,
) -> i32 {
    // SAFETY: Io owns the boxed context until it unregisters this callback.
    let context = unsafe { &*client.cast::<Context>() };
    if context.output {
        unsafe { zero_output(output) };
    }
    if context
        .entered
        .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
        .is_err()
    {
        return 0;
    }
    let _guard = Entered(&context.entered);
    context.calls.fetch_add(1, Ordering::Relaxed);
    // SAFETY: This callback exclusively holds the entered gate.
    let scratch = unsafe { &mut *context.scratch.get() };
    if let Some(source) = &context.input {
        if let Some(frames) = unsafe { read_stereo(input, scratch) } {
            source.controls.process(&mut scratch[..frames * 2]);
            source.ring.write(&scratch[..frames * 2]);
        } else {
            context.invalid.fetch_add(1, Ordering::Relaxed);
        }
        return 0;
    }
    let buffers = unsafe { buffers(output) };
    let Some(first) = buffers.first() else {
        return 0;
    };
    if first.mNumberChannels == 0 || first.mDataByteSize % 4 != 0 {
        return 0;
    }
    let channels = first.mNumberChannels as usize;
    let frames = first.mDataByteSize as usize / 4 / channels;
    if frames > MAX_FRAMES {
        context.invalid.fetch_add(1, Ordering::Relaxed);
        return 0;
    }
    let Ok(sources) = context.sources.try_lock() else {
        return 0;
    };
    for source in sources.iter() {
        source.ring.read(&mut scratch[..frames * 2]);
        for (index, buffer) in buffers.iter().enumerate() {
            if buffer.mData.is_null()
                || buffer.mNumberChannels == 0
                || buffer.mDataByteSize % 4 != 0
            {
                continue;
            }
            let count = buffer.mDataByteSize as usize / 4;
            let ch = buffer.mNumberChannels as usize;
            if count / ch != frames {
                context.invalid.fetch_add(1, Ordering::Relaxed);
                continue;
            }
            let destination =
                unsafe { std::slice::from_raw_parts_mut(buffer.mData.cast::<f32>(), count) };
            for frame in 0..frames {
                for channel in 0..ch.min(2) {
                    let stereo_channel = if buffers.len() == 1 {
                        channel
                    } else {
                        index + channel
                    };
                    if stereo_channel < 2 {
                        destination[frame * ch + channel] += scratch[frame * 2 + stereo_channel];
                    }
                }
            }
        }
    }
    for buffer in buffers {
        if !buffer.mData.is_null() && buffer.mDataByteSize % 4 == 0 {
            clamp(unsafe {
                std::slice::from_raw_parts_mut(
                    buffer.mData.cast::<f32>(),
                    buffer.mDataByteSize as usize / 4,
                )
            });
        }
    }
    0
}
struct Io {
    device: u32,
    rate: f64,
    proc: AudioDeviceIOProcID,
    context: Option<Box<Context>>,
}
impl Io {
    fn start(
        device: u32,
        output: bool,
        input: Option<Arc<Source>>,
        sources: Arc<Mutex<Vec<Arc<Source>>>>,
    ) -> Result<Self> {
        let scope = if output {
            kAudioObjectPropertyScopeOutput
        } else {
            kAudioObjectPropertyScopeInput
        };
        let format = unsafe {
            scalar::<AudioStreamBasicDescription>(device, kAudioDevicePropertyStreamFormat, scope)?
        };
        if format.mFormatID != kAudioFormatLinearPCM
            || format.mFormatFlags & kAudioFormatFlagIsFloat == 0
            || format.mBitsPerChannel != 32
            || format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        {
            return Err(Error::message(
                "only native Float32 PCM streams are supported",
            ));
        }
        if !format.mSampleRate.is_finite()
            || format.mSampleRate <= 0.
            || format.mChannelsPerFrame == 0
        {
            return Err(Error::message("invalid native audio stream format"));
        }
        let mut context = Box::new(Context {
            output,
            sources,
            input,
            scratch: UnsafeCell::new(vec![0.; MAX_FRAMES * 2].into_boxed_slice()),
            entered: AtomicBool::new(false),
            calls: AtomicU64::new(0),
            invalid: AtomicU64::new(0),
        });
        let mut proc = None;
        check(
            unsafe {
                AudioDeviceCreateIOProcID(
                    device,
                    Some(callback),
                    ptr::from_mut(context.as_mut()).cast(),
                    NonNull::from(&mut proc),
                )
            },
            "register audio callback",
        )?;
        if let Err(error) = check(
            unsafe { AudioDeviceStart(device, proc) },
            "start audio device",
        ) {
            unsafe {
                AudioDeviceDestroyIOProcID(device, proc);
            }
            return Err(error);
        }
        Ok(Self {
            device,
            rate: format.mSampleRate,
            proc,
            context: Some(context),
        })
    }
}
impl Drop for Io {
    fn drop(&mut self) {
        let stop = unsafe { AudioDeviceStop(self.device, self.proc) };
        let destroy = unsafe { AudioDeviceDestroyIOProcID(self.device, self.proc) };
        if stop != 0 || destroy != 0 {
            // Keep callback memory valid if HAL cannot confirm unregistration.
            // This exceptional control-thread leak is safer than a use-after-free.
            if let Some(context) = self.context.take() {
                Box::leak(context);
            }
        }
    }
}
struct Capture {
    io: Io,
    source: Arc<Source>,
    tap: Option<Tap>,
}
impl Capture {
    fn input(device: u32) -> Result<Self> {
        let source = Arc::new(Source::default());
        let io = Io::start(
            device,
            false,
            Some(source.clone()),
            Arc::new(Mutex::new(Vec::new())),
        )?;
        Ok(Self {
            io,
            source,
            tap: None,
        })
    }
    fn desktop(exclusions: &[String], pid: Option<i32>, rate: f64) -> Result<Self> {
        let tap = Tap::create(exclusions, pid, rate)?;
        let mut capture = Self::input(tap.aggregate.id)?;
        capture.tap = Some(tap);
        Ok(capture)
    }
}
// Field order ensures IO unregisters before tap and aggregate destruction.
pub struct Engine {
    output: Option<Io>,
    captures: Vec<(String, Capture)>,
    sources: Arc<Mutex<Vec<Arc<Source>>>>,
    pub output_device: Device,
}
impl Engine {
    pub fn new(output: Device) -> Result<Self> {
        if output.output_channels == 0 {
            return Err(Error::message("destination has no output channels"));
        }
        Ok(Self {
            output: None,
            captures: Vec::new(),
            sources: Arc::new(Mutex::new(Vec::new())),
            output_device: output,
        })
    }
    fn attach(&mut self, key: String, capture: Capture) -> Result<Arc<Source>> {
        let rate = unsafe {
            scalar::<AudioStreamBasicDescription>(
                capture.io.device,
                kAudioDevicePropertyStreamFormat,
                kAudioObjectPropertyScopeInput,
            )?
        }
        .mSampleRate;
        if (rate - self.output_device.rate).abs() > 0.5 {
            return Err(Error::message(format!(
                "source rate {rate} differs from output {}; no verified converter",
                self.output_device.rate
            )));
        }
        let source = capture.source.clone();
        self.sources
            .lock()
            .map_err(|_| Error::message("source table poisoned"))?
            .push(source.clone());
        if self.output.is_none() {
            match Io::start(self.output_device.id, true, None, self.sources.clone()) {
                Ok(io) => self.output = Some(io),
                Err(error) => {
                    self.sources.lock().unwrap().pop();
                    return Err(error);
                }
            }
        }
        self.captures.push((key, capture));
        Ok(source)
    }
    pub fn desktop(&mut self, enabled: bool, exclusions: &[String]) -> Result<Option<Arc<Source>>> {
        self.remove("desktop");
        if !enabled {
            return Ok(None);
        }
        let capture = Capture::desktop(exclusions, None, self.output_device.rate)?;
        self.attach("desktop".into(), capture).map(Some)
    }
    pub fn tap_process(&mut self, pid: i32) -> Result<Arc<Source>> {
        let key = format!("pid:{pid}");
        self.remove(&key);
        let capture = Capture::desktop(&[], Some(pid), self.output_device.rate)?;
        self.attach(key, capture)
    }
    pub fn microphone(&mut self, device: &Device, enabled: bool) -> Result<Option<Arc<Source>>> {
        self.remove(&device.uid);
        if !enabled {
            return Ok(None);
        }
        self.attach(device.uid.clone(), Capture::input(device.id)?)
            .map(Some)
    }
    pub fn source(&self, key: &str) -> Option<Arc<Source>> {
        self.captures
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, capture)| capture.source.clone())
    }
    pub fn remove(&mut self, key: &str) {
        if let Some(index) = self.captures.iter().position(|(k, _)| k == key) {
            let (_, capture) = self.captures.remove(index);
            if let Ok(mut sources) = self.sources.lock() {
                sources.retain(|s| !Arc::ptr_eq(s, &capture.source));
            }
            drop(capture);
        }
        if self.captures.is_empty() {
            self.output = None;
        }
    }
    pub fn add_generator(&mut self) -> Result<Arc<Source>> {
        let source = Arc::new(Source::default());
        self.sources
            .lock()
            .map_err(|_| Error::message("source table poisoned"))?
            .push(source.clone());
        if self.output.is_none() {
            self.output = Some(Io::start(
                self.output_device.id,
                true,
                None,
                self.sources.clone(),
            )?);
        }
        Ok(source)
    }
    pub fn shutdown(&mut self) {
        self.output = None;
        self.captures.clear();
        if let Ok(mut sources) = self.sources.lock() {
            sources.clear();
        }
    }
    pub fn diagnostics(&self) -> Vec<(String, BufferStats)> {
        self.captures
            .iter()
            .map(|(key, capture)| (key.clone(), capture.source.ring.stats()))
            .collect()
    }
}
impl Drop for Engine {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Summary of captured samples, independent of the recording UI.
#[derive(Debug, Clone, Copy)]
pub struct RecordingReport {
    pub duration: f64,
    pub peak: f32,
}
impl RecordingReport {
    /// Below -80 dBFS the recording is effectively silent for this self-test.
    pub fn has_signal(&self) -> bool {
        self.peak.is_finite() && self.peak > 0.0001
    }
}

pub fn record(device: &Device, duration: f64, path: &std::path::Path) -> Result<f64> {
    record_inner(
        device,
        duration,
        path,
        &AtomicBool::new(false),
        &std::sync::atomic::AtomicU32::new(0),
        &AtomicBool::new(false),
    )
    .map(|report| report.duration)
}
fn record_inner(
    device: &Device,
    duration: f64,
    path: &std::path::Path,
    stop: &AtomicBool,
    peak: &std::sync::atomic::AtomicU32,
    ready: &AtomicBool,
) -> Result<RecordingReport> {
    if !duration.is_finite() {
        return Err(Error::message("recording duration must be finite"));
    }
    let duration = duration.clamp(1., 30.);
    let capture = Capture::input(device.id)?;
    let rate = capture.io.rate;
    let capacity = (rate * duration * 2.) as usize;
    let mut samples = Vec::new();
    samples
        .try_reserve_exact(capacity)
        .map_err(|_| Error::message("recording buffer allocation failed"))?;
    let mut block = [0.; 2048];
    let mut highest = 0f32;
    // A successful AudioDeviceStart alone does not prove buffers are arriving.
    // Keep the test sound pending until an actual input block has been received.
    let prepare_deadline = Instant::now() + Duration::from_secs(10);
    while capture.source.ring.stats().written_frames == 0
        && !stop.load(Ordering::Relaxed)
        && Instant::now() < prepare_deadline
    {
        std::thread::sleep(Duration::from_millis(5));
    }
    if capture.source.ring.stats().written_frames == 0 {
        return Err(Error::message(
            "No audio frames arrived. Check microphone/system-audio recording permission, then try again.",
        ));
    }
    ready.store(true, Ordering::Release);
    let deadline = Instant::now() + Duration::from_secs_f64(duration);
    while Instant::now() < deadline && !stop.load(Ordering::Relaxed) {
        peak.store(capture.source.controls.peak().to_bits(), Ordering::Relaxed);
        let frames = capture.source.ring.read(&mut block);
        let count = (frames * 2).min(capacity - samples.len());
        for sample in &block[..count] {
            highest = highest.max(sample.abs());
        }
        samples.extend_from_slice(&block[..count]);
        if samples.len() == capacity {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    drop(capture);
    if samples.is_empty() {
        return Err(Error::message(
            "No audio frames arrived. Check microphone/system-audio recording permission, then try again.",
        ));
    }
    let bytes = wave_bytes(&samples, rate as u32).map_err(Error::message)?;
    std::fs::write(path, bytes).map_err(|e| Error::message(e.to_string()))?;
    Ok(RecordingReport {
        duration: samples.len() as f64 / (rate * 2.),
        peak: highest,
    })
}

/// Owns a cancellable recording worker; joining happens only on control threads.
pub struct RecordingJob {
    stop: std::sync::Arc<AtomicBool>,
    peak: std::sync::Arc<std::sync::atomic::AtomicU32>,
    ready: std::sync::Arc<AtomicBool>,
    receiver: std::sync::mpsc::Receiver<Result<RecordingReport>>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl RecordingJob {
    pub fn start(device: Device, duration: f64, path: std::path::PathBuf) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let peak = Arc::new(std::sync::atomic::AtomicU32::new(0));
        let ready = Arc::new(AtomicBool::new(false));
        let (sender, receiver) = std::sync::mpsc::channel();
        let worker_stop = stop.clone();
        let worker_peak = peak.clone();
        let worker_ready = ready.clone();
        let thread = std::thread::spawn(move || {
            let result = record_inner(
                &device,
                duration,
                &path,
                &worker_stop,
                &worker_peak,
                &worker_ready,
            );
            let _ = sender.send(result);
        });
        Self {
            stop,
            peak,
            ready,
            receiver,
            thread: Some(thread),
        }
    }
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }
    pub fn ready(&self) -> bool {
        self.ready.load(Ordering::Acquire)
    }
    pub fn peak(&self) -> f32 {
        f32::from_bits(self.peak.load(Ordering::Relaxed))
    }
    pub fn poll(&self) -> Option<Result<RecordingReport>> {
        match self.receiver.try_recv() {
            Ok(result) => Some(result),
            Err(std::sync::mpsc::TryRecvError::Empty) => None,
            Err(_) => Some(Err(Error::message("recording worker disconnected"))),
        }
    }
}
impl Drop for RecordingJob {
    fn drop(&mut self) {
        self.stop();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Process monitoring does not create a loopback route or change audio defaults.
pub struct ProcessMonitor {
    capture: Capture,
}
impl ProcessMonitor {
    pub fn start(pid: i32) -> Result<Self> {
        Ok(Self {
            capture: Capture::desktop(&[], Some(pid), 48_000.)?,
        })
    }
    pub fn peak(&self) -> f32 {
        self.capture.source.controls.peak()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn context(output: bool, input: Option<Arc<Source>>, sources: Vec<Arc<Source>>) -> Context {
        Context {
            output,
            input,
            sources: Arc::new(Mutex::new(sources)),
            scratch: UnsafeCell::new(vec![0.; MAX_FRAMES * 2].into_boxed_slice()),
            entered: AtomicBool::new(false),
            calls: AtomicU64::new(0),
            invalid: AtomicU64::new(0),
        }
    }
    fn list(samples: &mut [f32], channels: u32) -> AudioBufferList {
        AudioBufferList {
            mNumberBuffers: 1,
            mBuffers: [AudioBuffer {
                mNumberChannels: channels,
                mDataByteSize: std::mem::size_of_val(samples) as u32,
                mData: samples.as_mut_ptr().cast(),
            }],
        }
    }
    fn invoke(context: &mut Context, input: &mut AudioBufferList, output: &mut AudioBufferList) {
        let mut timestamp = unsafe { std::mem::zeroed::<AudioTimeStamp>() };
        unsafe {
            callback(
                1,
                NonNull::from(&mut timestamp),
                NonNull::from(input),
                NonNull::from(&mut timestamp),
                NonNull::from(output),
                NonNull::from(&mut timestamp),
                ptr::from_mut(context).cast(),
            );
        }
    }
    #[test]
    #[ignore = "requires physical microphone permission; observes frame counts only and routes nothing"]
    fn physical_microphone_delivers_frames_without_routing_or_saving_audio() {
        let input = devices()
            .unwrap()
            .into_iter()
            .filter(|device| {
                device.input_channels > 0 && !device.virtual_device && !device.aggregate
            })
            .min_by_key(|device| {
                if device.uid == "BuiltInMicrophoneDevice" {
                    0
                } else {
                    1
                }
            })
            .expect("no physical input available");
        let capture =
            Capture::input(input.id).expect("physical microphone capture could not start");
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline && capture.source.ring.stats().written_frames == 0 {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(
            capture.source.ring.stats().written_frames > 0,
            "no microphone frames arrived; check microphone permission"
        );
    }
    #[test]
    fn silence_is_not_a_successful_signal() {
        assert!(
            !RecordingReport {
                duration: 5.,
                peak: 0.
            }
            .has_signal()
        );
        assert!(
            !RecordingReport {
                duration: 5.,
                peak: f32::NAN
            }
            .has_signal()
        );
        assert!(
            !RecordingReport {
                duration: 5.,
                peak: 0.00001
            }
            .has_signal()
        );
        assert!(
            RecordingReport {
                duration: 5.,
                peak: 0.2
            }
            .has_signal()
        );
    }
    #[test]
    fn mono_capture_duplicates_and_does_not_mutate_input() {
        let source = Arc::new(Source::default());
        source.controls.set_gain(2.);
        let mut context = context(false, Some(source.clone()), vec![]);
        let mut input = [0.1, 0.2];
        let mut input_list = list(&mut input, 1);
        let mut unused = list(&mut [], 2);
        invoke(&mut context, &mut input_list, &mut unused);
        let mut out = [0.; 4];
        source.ring.read(&mut out);
        assert_eq!(out, [0.2, 0.2, 0.4, 0.4]);
        assert_eq!(input, [0.1, 0.2]);
    }
    #[test]
    fn renderer_adds_then_clamps_and_silences_underflow() {
        let a = Arc::new(Source::default());
        let b = Arc::new(Source::default());
        a.ring.write(&[0.8, -0.8]);
        b.ring.write(&[0.8, -0.8]);
        let mut context = context(true, None, vec![a, b]);
        let mut output = [99.; 4];
        let mut output_list = list(&mut output, 2);
        let mut unused = list(&mut [], 2);
        invoke(&mut context, &mut unused, &mut output_list);
        assert_eq!(output, [1., -1., 0., 0.]);
    }
    #[test]
    fn renderer_contention_produces_silence() {
        let mut context = context(true, None, vec![]);
        let sources = context.sources.clone();
        let _guard = sources.lock().unwrap();
        let mut output = [99.; 4];
        let mut output_list = list(&mut output, 2);
        let mut unused = list(&mut [], 2);
        invoke(&mut context, &mut unused, &mut output_list);
        assert_eq!(output, [0.; 4]);
    }
    #[test]
    fn oversized_output_is_zeroed_without_touching_scratch() {
        let mut context = context(true, None, vec![]);
        let mut output = vec![99.; (MAX_FRAMES + 1) * 2];
        let mut output_list = list(&mut output, 2);
        let mut unused = list(&mut [], 2);
        invoke(&mut context, &mut unused, &mut output_list);
        assert!(output.iter().all(|s| *s == 0.));
        assert_eq!(context.invalid.load(Ordering::Relaxed), 1);
    }
    #[test]
    fn planar_capture_maps_channels() {
        #[repr(C)]
        struct Planar {
            count: u32,
            buffers: [AudioBuffer; 2],
        }
        let source = Arc::new(Source::default());
        let mut context = context(false, Some(source.clone()), vec![]);
        let mut left = [0.1, 0.2];
        let mut right = [0.3, 0.4];
        let mut planar = Planar {
            count: 2,
            buffers: [
                list(&mut left, 1).mBuffers[0],
                list(&mut right, 1).mBuffers[0],
            ],
        };
        assert_eq!(
            std::mem::offset_of!(Planar, buffers),
            std::mem::offset_of!(AudioBufferList, mBuffers)
        );
        let mut unused = list(&mut [], 2);
        let planar = unsafe { &mut *ptr::from_mut(&mut planar).cast::<AudioBufferList>() };
        invoke(&mut context, planar, &mut unused);
        let mut out = [0.; 4];
        source.ring.read(&mut out);
        assert_eq!(out, [0.1, 0.3, 0.2, 0.4]);
    }
}
