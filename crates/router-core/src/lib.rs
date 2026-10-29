//! Bounded, preallocated stereo audio processing shared by the macOS app and CLI.
//! No platform handles or Objective-C objects cross this interface.
use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};

pub const VIRTUAL_MIC_UID: &str = "com.appaudiorouter.virtualmic.default";
pub const VIRTUAL_MIC_NAME: &str = "AppAudioRouter Virtual Microphone";
pub const DEFAULT_CAPACITY_FRAMES: usize = 16_384;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct BufferStats {
    pub written_frames: u64,
    pub read_frames: u64,
    pub overwritten_frames: u64,
    pub underrun_frames: u64,
    pub contention_blocks: u64,
}
struct Storage {
    samples: Box<[f32]>,
    read: usize,
    write: usize,
    available: usize,
}
/// A stereo ring with one non-waiting acquisition attempt per operation.
/// Contended writes drop their block; contended reads return silence.
pub struct AudioRing {
    busy: AtomicBool,
    storage: UnsafeCell<Storage>,
    capacity: usize,
    written: AtomicU64,
    read: AtomicU64,
    overwritten: AtomicU64,
    underrun: AtomicU64,
    contention: AtomicU64,
}
// SAFETY: Every access to storage is exclusively protected by busy. The
// acquisition uses Acquire and the guard's release uses Release. Allocation,
// capacity and storage address remain unchanged throughout the ring's lifetime.
unsafe impl Sync for AudioRing {}
struct Gate<'a>(&'a AtomicBool);
impl Drop for Gate<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}
impl AudioRing {
    pub fn new(capacity_frames: usize) -> Self {
        assert!(capacity_frames > 0 && capacity_frames <= usize::MAX / 2);
        Self {
            busy: AtomicBool::new(false),
            capacity: capacity_frames,
            storage: UnsafeCell::new(Storage {
                samples: vec![0.; capacity_frames * 2].into_boxed_slice(),
                read: 0,
                write: 0,
                available: 0,
            }),
            written: AtomicU64::new(0),
            read: AtomicU64::new(0),
            overwritten: AtomicU64::new(0),
            underrun: AtomicU64::new(0),
            contention: AtomicU64::new(0),
        }
    }
    fn acquire(&self) -> Option<Gate<'_>> {
        if self
            .busy
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .is_ok()
        {
            Some(Gate(&self.busy))
        } else {
            self.contention.fetch_add(1, Ordering::Relaxed);
            None
        }
    }
    /// Ignores a trailing incomplete stereo frame. Retains the newest frames on overflow.
    pub fn write(&self, input: &[f32]) -> usize {
        let Some(_guard) = self.acquire() else {
            return 0;
        };
        // SAFETY: The gate is exclusively held until this operation returns.
        let s = unsafe { &mut *self.storage.get() };
        let total = input.len() / 2;
        let count = total.min(self.capacity);
        let discard = (s.available + count).saturating_sub(self.capacity);
        s.read = (s.read + discard) % self.capacity;
        s.available -= discard;
        self.overwritten
            .fetch_add((discard + total - count) as u64, Ordering::Relaxed);
        let input = &input[(total - count) * 2..total * 2];
        for (i, frame) in input.chunks_exact(2).enumerate() {
            let offset = ((s.write + i) % self.capacity) * 2;
            s.samples[offset..offset + 2].copy_from_slice(frame);
        }
        s.write = (s.write + count) % self.capacity;
        s.available += count;
        self.written.fetch_add(count as u64, Ordering::Relaxed);
        count
    }
    pub fn read(&self, output: &mut [f32]) -> usize {
        output.fill(0.);
        let frames = output.len() / 2;
        let Some(_guard) = self.acquire() else {
            return 0;
        };
        // SAFETY: The gate is exclusively held until this operation returns.
        let s = unsafe { &mut *self.storage.get() };
        let count = frames.min(s.available);
        for (i, frame) in output[..count * 2].chunks_exact_mut(2).enumerate() {
            let offset = ((s.read + i) % self.capacity) * 2;
            frame.copy_from_slice(&s.samples[offset..offset + 2]);
        }
        s.read = (s.read + count) % self.capacity;
        s.available -= count;
        self.read.fetch_add(count as u64, Ordering::Relaxed);
        self.underrun
            .fetch_add((frames - count) as u64, Ordering::Relaxed);
        count
    }
    /// Non-waiting clear, also safe to call from a control thread.
    pub fn clear(&self) -> bool {
        let Some(_guard) = self.acquire() else {
            return false;
        };
        // SAFETY: The gate is exclusively held until this operation returns.
        let s = unsafe { &mut *self.storage.get() };
        s.read = 0;
        s.write = 0;
        s.available = 0;
        true
    }
    pub fn stats(&self) -> BufferStats {
        BufferStats {
            written_frames: self.written.load(Ordering::Relaxed),
            read_frames: self.read.load(Ordering::Relaxed),
            overwritten_frames: self.overwritten.load(Ordering::Relaxed),
            underrun_frames: self.underrun.load(Ordering::Relaxed),
            contention_blocks: self.contention.load(Ordering::Relaxed),
        }
    }
}
impl Default for AudioRing {
    fn default() -> Self {
        Self::new(DEFAULT_CAPACITY_FRAMES)
    }
}

pub struct Controls {
    gain: AtomicU32,
    muted: AtomicBool,
    peak: AtomicU32,
}
impl Default for Controls {
    fn default() -> Self {
        Self {
            gain: AtomicU32::new(1f32.to_bits()),
            muted: AtomicBool::new(false),
            peak: AtomicU32::new(0),
        }
    }
}
impl Controls {
    pub fn set_gain(&self, value: f32) {
        self.gain.store(
            if value.is_finite() {
                value.clamp(0., 2.)
            } else {
                0.
            }
            .to_bits(),
            Ordering::Relaxed,
        );
    }
    pub fn gain(&self) -> f32 {
        f32::from_bits(self.gain.load(Ordering::Relaxed))
    }
    pub fn set_muted(&self, value: bool) {
        self.muted.store(value, Ordering::Relaxed);
    }
    pub fn muted(&self) -> bool {
        self.muted.load(Ordering::Relaxed)
    }
    pub fn peak(&self) -> f32 {
        f32::from_bits(self.peak.load(Ordering::Relaxed))
    }
    pub fn process(&self, samples: &mut [f32]) {
        let gain = if self.muted() { 0. } else { self.gain() };
        let mut peak = 0f32;
        for sample in samples {
            *sample = if sample.is_finite() {
                *sample * gain
            } else {
                0.
            };
            peak = peak.max(sample.abs());
        }
        self.peak.store(peak.min(1.).to_bits(), Ordering::Relaxed);
    }
}
/// Mix without allocating; callers zero output before adding sources.
pub fn add_clamped(output: &mut [f32], input: &[f32]) {
    for (out, sample) in output.iter_mut().zip(input) {
        *out += sample;
    }
}
pub fn clamp(samples: &mut [f32]) {
    for sample in samples {
        *sample = if sample.is_finite() {
            sample.clamp(-1., 1.)
        } else {
            0.
        };
    }
}

pub fn excluded_process_ids(
    own: &[u32],
    selected: &[String],
    processes: &[(String, Vec<u32>)],
) -> Vec<u32> {
    let mut ids = own.to_vec();
    for (bundle, objects) in processes {
        if selected.iter().any(|id| {
            bundle == id
                || bundle
                    .strip_prefix(id)
                    .is_some_and(|suffix| suffix.starts_with('.'))
        }) {
            ids.extend(objects);
        }
    }
    ids.retain(|id| *id != 0);
    ids.sort_unstable();
    ids.dedup();
    ids
}
/// PCM WAV encoding is a control-thread operation, never an audio callback.
pub fn wave_bytes(samples: &[f32], rate: u32) -> Result<Vec<u8>, &'static str> {
    if rate == 0 || rate > u32::MAX / 4 || samples.len() % 2 != 0 {
        return Err("invalid stereo WAV format");
    }
    let size = u32::try_from(samples.len().checked_mul(2).ok_or("WAV too large")?)
        .map_err(|_| "WAV too large")?;
    let riff_size = size.checked_add(36).ok_or("WAV too large")?;
    let mut bytes = Vec::with_capacity(size as usize + 44);
    bytes.extend_from_slice(b"RIFF");
    bytes.extend(riff_size.to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend(16u32.to_le_bytes());
    bytes.extend(1u16.to_le_bytes());
    bytes.extend(2u16.to_le_bytes());
    bytes.extend(rate.to_le_bytes());
    bytes.extend((rate * 4).to_le_bytes());
    bytes.extend(4u16.to_le_bytes());
    bytes.extend(16u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend(size.to_le_bytes());
    for &sample in samples {
        let value = if sample.is_finite() {
            sample.clamp(-1., 1.)
        } else {
            0.
        };
        bytes.extend(((value * 32767.) as i16).to_le_bytes());
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wrap_overflow_and_silence() {
        let ring = AudioRing::new(3);
        ring.write(&[1., 1., 2., 2.]);
        let mut first = [0.; 2];
        assert_eq!(ring.read(&mut first), 1);
        assert_eq!(first, [1., 1.]);
        ring.write(&[3., 3., 4., 4., 5., 5.]);
        let mut out = [99.; 8];
        assert_eq!(ring.read(&mut out), 3);
        assert_eq!(out, [3., 3., 4., 4., 5., 5., 0., 0.]);
        assert_eq!(ring.stats().overwritten_frames, 1);
        assert_eq!(ring.stats().underrun_frames, 1);
    }
    #[test]
    fn oversized_write_retains_newest() {
        let ring = AudioRing::new(2);
        ring.write(&[1., 1., 2., 2., 3., 3., 4., 4.]);
        let mut out = [0.; 4];
        ring.read(&mut out);
        assert_eq!(out, [3., 3., 4., 4.]);
        assert_eq!(ring.stats().overwritten_frames, 2);
    }
    #[test]
    fn contention_never_waits() {
        let ring = AudioRing::new(2);
        let gate = ring.acquire().unwrap();
        assert_eq!(ring.write(&[1., 1.]), 0);
        let mut out = [1.; 4];
        assert_eq!(ring.read(&mut out), 0);
        assert_eq!(out, [0.; 4]);
        drop(gate);
        assert_eq!(ring.stats().contention_blocks, 2);
    }
    #[test]
    fn controls_and_mix() {
        let controls = Controls::default();
        controls.set_gain(2.);
        let mut out = [0.8, -0.8, f32::NAN, 0.];
        controls.process(&mut out);
        assert_eq!(controls.peak(), 1.);
        clamp(&mut out);
        assert_eq!(out, [1., -1., 0., 0.]);
        controls.set_muted(true);
        controls.process(&mut out);
        assert_eq!(out, [0.; 4]);
    }
    #[test]
    fn helper_exclusions_preserve_self() {
        assert_eq!(
            excluded_process_ids(
                &[7],
                &["com.google.Chrome".into()],
                &[
                    ("com.google.Chrome.helper".into(), vec![12, 13]),
                    ("com.google.ChromeX".into(), vec![14])
                ]
            ),
            vec![7, 12, 13]
        );
    }
    #[test]
    fn wave_header_and_conversion() {
        let bytes = wave_bytes(&[1., -1., 0., f32::NAN], 48_000).unwrap();
        assert_eq!(&bytes[..4], b"RIFF");
        assert_eq!(bytes.len(), 52);
        assert_eq!(&bytes[24..28], &48_000u32.to_le_bytes());
        assert_eq!(&bytes[44..48], &[255, 127, 1, 128]);
        assert!(wave_bytes(&[0.], 48_000).is_err());
    }
    #[test]
    fn concurrent_access_is_bounded() {
        let ring = std::sync::Arc::new(AudioRing::new(64));
        let writer = ring.clone();
        let thread = std::thread::spawn(move || {
            for _ in 0..10_000 {
                writer.write(&[0.5; 32]);
            }
        });
        let mut block = [0.; 32];
        for _ in 0..10_000 {
            ring.read(&mut block);
            assert!(block.iter().all(|x| *x == 0. || *x == 0.5));
        }
        thread.join().unwrap();
    }
}
