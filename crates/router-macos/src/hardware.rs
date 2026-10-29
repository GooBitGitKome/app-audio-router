use crate::{Error, Result, check};
use objc2::AnyThread;
use objc2_core_audio::*;
use objc2_core_audio_types::*;
use objc2_core_foundation::{
    CFArray, CFDictionary, CFNumber, CFRetained, CFString, Type, kCFTypeDictionaryKeyCallBacks,
    kCFTypeDictionaryValueCallBacks,
};
use objc2_foundation::{NSArray, NSNumber, NSString, NSUUID};
use router_core::{VIRTUAL_MIC_NAME, VIRTUAL_MIC_UID};
use std::ptr::{self, NonNull};

#[derive(Debug, Clone, PartialEq)]
pub struct Device {
    pub id: u32,
    pub uid: String,
    pub name: String,
    pub manufacturer: String,
    pub input_channels: u32,
    pub output_channels: u32,
    pub rate: f64,
    pub aggregate: bool,
    pub virtual_device: bool,
    pub default_input: bool,
    pub default_output: bool,
}
impl Device {
    pub fn is_app_microphone(&self) -> bool {
        self.uid == VIRTUAL_MIC_UID && self.aggregate && self.input_channels > 0
    }
}
#[derive(Debug, Clone)]
pub struct Process {
    pub id: u32,
    pub pid: i32,
    pub bundle_id: String,
}
pub(crate) fn address(selector: u32, scope: u32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress {
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain,
    }
}
// SAFETY: Only the typed wrappers below call this with HAL properties whose
// documented representation matches T; all storage is initialized and aligned.
pub(crate) unsafe fn scalar<T: Copy>(id: u32, selector: u32, scope: u32) -> Result<T> {
    let mut value = unsafe { std::mem::zeroed::<T>() };
    let mut size = std::mem::size_of::<T>() as u32;
    let mut addr = address(selector, scope);
    check(
        unsafe {
            AudioObjectGetPropertyData(
                id,
                NonNull::from(&mut addr),
                0,
                ptr::null(),
                NonNull::from(&mut size),
                NonNull::from(&mut value).cast(),
            )
        },
        "read audio property",
    )?;
    if size as usize != std::mem::size_of::<T>() {
        return Err(Error::message("unexpected audio property size"));
    }
    Ok(value)
}
pub(crate) fn set_scalar<T: Copy>(id: u32, selector: u32, value: &T) -> Result<()> {
    let mut addr = address(selector, kAudioObjectPropertyScopeGlobal);
    check(
        unsafe {
            AudioObjectSetPropertyData(
                id,
                NonNull::from(&mut addr),
                0,
                ptr::null(),
                std::mem::size_of::<T>() as u32,
                NonNull::from(value).cast(),
            )
        },
        "set audio property",
    )
}
pub(crate) fn bytes(id: u32, selector: u32, scope: u32) -> Result<(Vec<u64>, usize)> {
    let mut addr = address(selector, scope);
    let mut size = 0;
    for _ in 0..3 {
        check(
            unsafe {
                AudioObjectGetPropertyDataSize(
                    id,
                    NonNull::from(&mut addr),
                    0,
                    ptr::null(),
                    NonNull::from(&mut size),
                )
            },
            "size audio property",
        )?;
        if size > 16 * 1024 * 1024 {
            return Err(Error::message("audio property exceeds safety limit"));
        }
        if size == 0 {
            return Ok((Vec::new(), 0));
        }
        let capacity = size;
        let mut data = vec![0u64; (size as usize).div_ceil(8)];
        let status = unsafe {
            AudioObjectGetPropertyData(
                id,
                NonNull::from(&mut addr),
                0,
                ptr::null(),
                NonNull::from(&mut size),
                NonNull::new(data.as_mut_ptr().cast()).unwrap(),
            )
        };
        if status == 0 && size <= capacity {
            return Ok((data, size as usize));
        }
    }
    Err(Error::message(
        "audio properties changed repeatedly during enumeration",
    ))
}
fn ids(id: u32, selector: u32) -> Result<Vec<u32>> {
    let (data, size) = bytes(id, selector, kAudioObjectPropertyScopeGlobal)?;
    if size % 4 != 0 {
        return Err(Error::message("invalid object ID list"));
    }
    Ok(unsafe { std::slice::from_raw_parts(data.as_ptr().cast::<u32>(), size / 4) }.to_vec())
}
pub(crate) fn string(id: u32, selector: u32) -> Result<String> {
    let raw = unsafe { scalar::<*mut CFString>(id, selector, kAudioObjectPropertyScopeGlobal)? };
    let value = unsafe {
        CFRetained::from_raw(
            NonNull::new(raw).ok_or_else(|| Error::message("missing audio string"))?,
        )
    };
    Ok(value.to_string())
}
fn channel_count(id: u32, scope: u32) -> u32 {
    let Ok((data, size)) = bytes(id, kAudioDevicePropertyStreamConfiguration, scope) else {
        return 0;
    };
    if size < std::mem::offset_of!(AudioBufferList, mBuffers) {
        return 0;
    }
    let list = data.as_ptr().cast::<AudioBufferList>();
    let count = unsafe { (*list).mNumberBuffers as usize };
    let offset = std::mem::offset_of!(AudioBufferList, mBuffers);
    if count > (size - offset) / std::mem::size_of::<AudioBuffer>() {
        return 0;
    }
    let buffers = unsafe {
        std::slice::from_raw_parts(ptr::addr_of!((*list).mBuffers).cast::<AudioBuffer>(), count)
    };
    buffers.iter().map(|b| b.mNumberChannels).sum()
}
pub fn devices() -> Result<Vec<Device>> {
    let input = unsafe {
        scalar::<u32>(
            kAudioObjectSystemObject as u32,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal,
        )
    }
    .unwrap_or(0);
    let output = unsafe {
        scalar::<u32>(
            kAudioObjectSystemObject as u32,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal,
        )
    }
    .unwrap_or(0);
    let mut devices = Vec::new();
    for id in ids(
        kAudioObjectSystemObject as u32,
        kAudioHardwarePropertyDevices,
    )? {
        let Ok(uid) = string(id, kAudioDevicePropertyDeviceUID) else {
            continue;
        };
        let transport = unsafe {
            scalar::<u32>(
                id,
                kAudioDevicePropertyTransportType,
                kAudioObjectPropertyScopeGlobal,
            )
        }
        .unwrap_or(0);
        devices.push(Device {
            id,
            uid,
            name: string(id, kAudioObjectPropertyName).unwrap_or_else(|_| format!("Device {id}")),
            manufacturer: string(id, kAudioObjectPropertyManufacturer).unwrap_or_default(),
            input_channels: channel_count(id, kAudioObjectPropertyScopeInput),
            output_channels: channel_count(id, kAudioObjectPropertyScopeOutput),
            rate: unsafe {
                scalar::<f64>(
                    id,
                    kAudioDevicePropertyNominalSampleRate,
                    kAudioObjectPropertyScopeGlobal,
                )
            }
            .unwrap_or(0.),
            aggregate: transport == kAudioDeviceTransportTypeAggregate,
            virtual_device: transport == kAudioDeviceTransportTypeVirtual
                || transport == kAudioDeviceTransportTypeAggregate,
            default_input: id == input,
            default_output: id == output,
        });
    }
    Ok(devices)
}
pub fn processes() -> Result<Vec<Process>> {
    let mut result = Vec::new();
    for id in ids(
        kAudioObjectSystemObject as u32,
        kAudioHardwarePropertyProcessObjectList,
    )? {
        if let Ok(pid) = unsafe {
            scalar::<i32>(
                id,
                kAudioProcessPropertyPID,
                kAudioObjectPropertyScopeGlobal,
            )
        } {
            result.push(Process {
                id,
                pid,
                bundle_id: string(id, kAudioProcessPropertyBundleID).unwrap_or_default(),
            });
        }
    }
    Ok(result)
}
pub fn loopback(devices: &[Device]) -> Option<&Device> {
    devices
        .iter()
        .filter(|d| {
            !d.aggregate
                && d.input_channels > 0
                && d.output_channels > 0
                && d.virtual_device
                && !d.uid.contains("VirtualDesktop")
        })
        .min_by_key(|d| {
            if d.uid.to_lowercase().contains("blackhole") {
                0
            } else if d.uid.contains("zoom.us.zoomaudiodevice") {
                1
            } else {
                2
            }
        })
}
pub fn set_default_input(id: u32) -> Result<()> {
    set_scalar(
        kAudioObjectSystemObject as u32,
        kAudioHardwarePropertyDefaultInputDevice,
        &id,
    )
}
pub fn set_default_output(id: u32) -> Result<()> {
    set_scalar(
        kAudioObjectSystemObject as u32,
        kAudioHardwarePropertyDefaultOutputDevice,
        &id,
    )
}
pub fn subdevice_uids(id: u32) -> Result<Vec<String>> {
    let raw = unsafe {
        scalar::<*mut CFArray<CFString>>(
            id,
            kAudioAggregateDevicePropertyFullSubDeviceList,
            kAudioObjectPropertyScopeGlobal,
        )?
    };
    let array = unsafe {
        CFRetained::from_raw(
            NonNull::new(raw).ok_or_else(|| Error::message("missing subdevice list"))?,
        )
    };
    Ok(array.to_vec().iter().map(|s| s.to_string()).collect())
}
fn cf<T: Type>(value: &CFRetained<T>) -> *const std::ffi::c_void {
    std::ptr::from_ref(&**value).cast()
}
fn dict(pairs: &[(&str, *const std::ffi::c_void)]) -> CFRetained<CFDictionary> {
    let strings: Vec<_> = pairs
        .iter()
        .map(|(key, _)| CFString::from_str(key))
        .collect();
    let mut keys: Vec<_> = strings.iter().map(cf).collect();
    let mut values: Vec<_> = pairs.iter().map(|(_, value)| *value).collect();
    // SAFETY: All keys and values are live CF objects. Type callbacks retain
    // them for the dictionary lifetime; pointer arrays may be freed afterwards.
    unsafe {
        CFDictionary::new(
            None,
            keys.as_mut_ptr(),
            values.as_mut_ptr(),
            pairs.len() as isize,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        )
    }
    .expect("CFDictionary allocation failed")
}
fn unique_uid(prefix: &str) -> String {
    format!("com.appaudiorouter.{prefix}.{}", NSUUID::new().UUIDString())
}
/// Owns only a newly created aggregate; borrowing never grants destroy rights.
pub struct Aggregate {
    pub id: u32,
    pub owned: bool,
}
impl Drop for Aggregate {
    fn drop(&mut self) {
        if self.owned {
            unsafe {
                AudioHardwareDestroyAggregateDevice(self.id);
            }
        }
    }
}
impl Aggregate {
    pub fn virtual_microphone(source: &Device) -> Result<Self> {
        if source.aggregate || source.input_channels == 0 || source.output_channels == 0 {
            return Err(Error::message(
                "loopback must be a bidirectional non-aggregate device",
            ));
        }
        if let Some(existing) = devices()?.iter().find(|d| d.uid == VIRTUAL_MIC_UID) {
            if existing.is_app_microphone() && subdevice_uids(existing.id)? == [source.uid.clone()]
            {
                return Ok(Self {
                    id: existing.id,
                    owned: false,
                });
            }
            return Err(Error::message(
                "virtual microphone is owned by another instance with a different configuration",
            ));
        }
        Self::create(
            VIRTUAL_MIC_NAME,
            std::slice::from_ref(&source.uid),
            false,
            false,
            Some(VIRTUAL_MIC_UID),
        )
    }
    /// Explicit CLI-created public aggregates may outlive this process.
    pub fn persist(mut self) -> u32 {
        self.owned = false;
        self.id
    }
    pub fn create(
        name: &str,
        uids: &[String],
        stacked: bool,
        private: bool,
        uid: Option<&str>,
    ) -> Result<Self> {
        let all = devices()?;
        if uids.is_empty()
            || uids
                .iter()
                .any(|uid| !all.iter().any(|d| &d.uid == uid && !d.aggregate))
        {
            return Err(Error::message(
                "aggregate requires existing non-aggregate subdevices",
            ));
        }
        let stacked = stacked
            && !uids.iter().all(|uid| {
                all.iter()
                    .any(|d| &d.uid == uid && d.input_channels > 0 && d.output_channels == 0)
            });
        let uid = uid
            .map(str::to_owned)
            .unwrap_or_else(|| unique_uid(if stacked { "multiout" } else { "aggregatemic" }));
        let members: Vec<_> = uids
            .iter()
            .enumerate()
            .map(|(i, uid)| {
                let uid = CFString::from_str(uid);
                let drift = CFNumber::new_i32(i32::from(i != 0));
                dict(&[("uid", cf(&uid)), ("drift", cf(&drift))])
            })
            .collect();
        let members = CFArray::from_objects(&members.iter().map(|v| &**v).collect::<Vec<_>>());
        let name = CFString::from_str(name);
        let uid = CFString::from_str(&uid);
        let master = CFString::from_str(&uids[0]);
        let stacked = CFNumber::new_i32(i32::from(stacked));
        let private = CFNumber::new_i32(i32::from(private));
        let description = dict(&[
            ("name", cf(&name)),
            ("uid", cf(&uid)),
            ("subdevices", cf(&members)),
            ("master", cf(&master)),
            ("stacked", cf(&stacked)),
            ("private", cf(&private)),
        ]);
        let mut id = 0;
        check(
            unsafe { AudioHardwareCreateAggregateDevice(&description, NonNull::from(&mut id)) },
            "create aggregate device",
        )?;
        if id == 0 {
            return Err(Error::message("aggregate creation returned an invalid ID"));
        }
        let aggregate = Self { id, owned: true };
        // HAL publication is asynchronous. Wait on the control thread so an
        // immediate second setup sees this instance instead of attempting a
        // duplicate fixed-UID creation (observed as OSStatus 'nope').
        let expected_uid = uid.to_string();
        let needs_input = !stacked.as_i32().is_some_and(|value| value != 0)
            && uids
                .iter()
                .any(|uid| all.iter().any(|d| &d.uid == uid && d.input_channels > 0));
        for _ in 0..50 {
            if devices().is_ok_and(|devices| {
                devices.iter().any(|d| {
                    d.id == id && d.uid == expected_uid && (!needs_input || d.input_channels > 0)
                })
            }) {
                return Ok(aggregate);
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        Err(Error::message(
            "aggregate created but did not become discoverable within 500ms",
        ))
    }
}
pub fn cleanup_virtual_microphone() -> Result<()> {
    for d in devices()?
        .iter()
        .filter(|d| d.uid == VIRTUAL_MIC_UID && d.aggregate)
    {
        check(
            unsafe { AudioHardwareDestroyAggregateDevice(d.id) },
            "destroy virtual microphone",
        )?;
    }
    Ok(())
}

pub(crate) struct Tap {
    pub id: u32,
    pub aggregate: Aggregate,
}
impl Tap {
    pub fn create(exclusions: &[String], include_pid: Option<i32>, rate: f64) -> Result<Self> {
        let processes = processes()?;
        let own_pid = std::process::id() as i32;
        let own: Vec<_> = processes
            .iter()
            .filter(|p| p.pid == own_pid)
            .map(|p| p.id)
            .collect();
        if own.is_empty() && include_pid.is_none() {
            return Err(Error::message(
                "cannot resolve self-process IDs; refusing a global tap without self-exclusion",
            ));
        }
        let selected = if let Some(pid) = include_pid {
            processes
                .iter()
                .filter(|p| p.pid == pid && pid != own_pid)
                .map(|p| p.id)
                .collect::<Vec<_>>()
        } else {
            router_core::excluded_process_ids(
                &own,
                exclusions,
                &processes
                    .iter()
                    .map(|p| (p.bundle_id.clone(), vec![p.id]))
                    .collect::<Vec<_>>(),
            )
        };
        if selected.is_empty() {
            return Err(Error::message("no audio process objects resolved"));
        }
        let numbers = NSArray::from_retained_slice(
            &selected
                .iter()
                .map(|id| NSNumber::new_u32(*id))
                .collect::<Vec<_>>(),
        );
        let description = unsafe {
            if include_pid.is_some() {
                CATapDescription::initStereoMixdownOfProcesses(CATapDescription::alloc(), &numbers)
            } else {
                CATapDescription::initStereoGlobalTapButExcludeProcesses(
                    CATapDescription::alloc(),
                    &numbers,
                )
            }
        };
        unsafe {
            description.setName(&NSString::from_str("AppAudioRouterDesktopTap"));
            description.setPrivate(true);
            description.setMuteBehavior(CATapMuteBehavior::Unmuted);
        }
        let mut id = 0;
        check(
            unsafe { AudioHardwareCreateProcessTap(Some(&description), &mut id) },
            "create process tap",
        )?;
        let result = (|| {
            let tap_uid = CFString::from_str(&string(id, kAudioTapPropertyUID)?);
            let one = CFNumber::new_i32(1);
            let sub = dict(&[("uid", cf(&tap_uid)), ("drift", cf(&one))]);
            let taps = CFArray::from_objects(&[&*sub]);
            let name = CFString::from_str("AppAudioRouterTapDevice");
            let uid = CFString::from_str(&unique_uid("tapagg"));
            let description = dict(&[
                ("name", cf(&name)),
                ("uid", cf(&uid)),
                ("taps", cf(&taps)),
                ("private", cf(&one)),
            ]);
            let mut agg = 0;
            check(
                unsafe {
                    AudioHardwareCreateAggregateDevice(&description, NonNull::from(&mut agg))
                },
                "create tap aggregate",
            )?;
            let aggregate = Aggregate {
                id: agg,
                owned: true,
            };
            let _ = set_scalar(agg, kAudioDevicePropertyNominalSampleRate, &rate);
            let mut actual = 0.;
            for _ in 0..50 {
                actual = unsafe {
                    scalar::<f64>(
                        agg,
                        kAudioDevicePropertyNominalSampleRate,
                        kAudioObjectPropertyScopeGlobal,
                    )
                }
                .unwrap_or(0.);
                if (actual - rate).abs() <= 0.5 {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            if (actual - rate).abs() > 0.5 {
                return Err(Error::message(format!(
                    "capture rate {actual} does not match output {rate}"
                )));
            }
            Ok(Self { id, aggregate })
        })();
        if result.is_err() {
            unsafe {
                AudioHardwareDestroyProcessTap(id);
            }
        }
        result
    }
}
impl Drop for Tap {
    fn drop(&mut self) {
        // Aggregate must be destroyed before its tap.
        if self.aggregate.owned {
            unsafe {
                AudioHardwareDestroyAggregateDevice(self.aggregate.id);
            }
            self.aggregate.owned = false;
        }
        unsafe {
            AudioHardwareDestroyProcessTap(self.id);
        }
    }
}

/// HAL listeners only mark dirty; discovery and UI updates run on control threads.
pub struct DeviceObserver {
    dirty: Option<Box<std::sync::atomic::AtomicBool>>,
    registrations: Vec<(u32, AudioObjectPropertyAddress)>,
}
unsafe extern "C-unwind" fn changed(
    _: u32,
    _: u32,
    _: NonNull<AudioObjectPropertyAddress>,
    context: *mut std::ffi::c_void,
) -> i32 {
    // SAFETY: The observer retains this allocation until listeners are removed.
    unsafe { &*context.cast::<std::sync::atomic::AtomicBool>() }
        .store(true, std::sync::atomic::Ordering::Release);
    0
}
impl DeviceObserver {
    pub fn new(all: &[Device]) -> Result<Self> {
        let mut observer = Self {
            dirty: Some(Box::new(std::sync::atomic::AtomicBool::new(false))),
            registrations: Vec::new(),
        };
        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyProcessObjectList,
        ] {
            observer.add(
                kAudioObjectSystemObject as u32,
                selector,
                kAudioObjectPropertyScopeGlobal,
            )?;
        }
        for device in all {
            for selector in [
                kAudioDevicePropertyNominalSampleRate,
                kAudioDevicePropertyDeviceIsAlive,
            ] {
                observer.add(device.id, selector, kAudioObjectPropertyScopeGlobal)?;
            }
        }
        Ok(observer)
    }
    fn add(&mut self, id: u32, selector: u32, scope: u32) -> Result<()> {
        let mut addr = address(selector, scope);
        let pointer = ptr::from_ref(&**self.dirty.as_ref().unwrap())
            .cast_mut()
            .cast();
        check(
            unsafe {
                AudioObjectAddPropertyListener(id, NonNull::from(&mut addr), Some(changed), pointer)
            },
            "register audio property listener",
        )?;
        self.registrations.push((id, addr));
        Ok(())
    }
    pub fn take_changed(&self) -> bool {
        self.dirty
            .as_ref()
            .is_some_and(|v| v.swap(false, std::sync::atomic::Ordering::AcqRel))
    }
}
impl Drop for DeviceObserver {
    fn drop(&mut self) {
        let Some(dirty) = self.dirty.take() else {
            return;
        };
        let pointer = ptr::from_ref(&*dirty).cast_mut().cast();
        let mut failed = false;
        for (id, mut addr) in self.registrations.drain(..) {
            failed |= unsafe {
                AudioObjectRemovePropertyListener(
                    id,
                    NonNull::from(&mut addr),
                    Some(changed),
                    pointer,
                )
            } != 0;
        }
        if failed {
            Box::leak(dirty);
        }
    }
}
