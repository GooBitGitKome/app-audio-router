use std::{
    alloc::{GlobalAlloc, Layout, System},
    cell::Cell,
};
struct Counting;
thread_local! {static WATCH:Cell<bool>=const{Cell::new(false)};static ALLOCATIONS:Cell<u64>=const{Cell::new(0)};static DEALLOCATIONS:Cell<u64>=const{Cell::new(0)};}
// SAFETY: All requests are forwarded unchanged to the system allocator. The
// counters are thread-local, nonallocating, and only enabled around the test.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        WATCH.with(|w| {
            if w.get() {
                ALLOCATIONS.with(|c| c.set(c.get() + 1));
            }
        });
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        WATCH.with(|w| {
            if w.get() {
                DEALLOCATIONS.with(|c| c.set(c.get() + 1));
            }
        });
        unsafe {
            System.dealloc(ptr, layout);
        }
    }
}
#[global_allocator]
static ALLOCATOR: Counting = Counting;
#[test]
fn audio_primitives_neither_allocate_nor_deallocate() {
    let ring = router_core::AudioRing::new(1024);
    let controls = router_core::Controls::default();
    let mut block = [0.25; 512];
    let mut output = [0.; 512];
    ALLOCATIONS.with(|c| c.set(0));
    DEALLOCATIONS.with(|c| c.set(0));
    WATCH.with(|w| w.set(true));
    for _ in 0..1000 {
        controls.process(&mut block);
        ring.write(&block);
        ring.read(&mut output);
        router_core::clamp(&mut output);
    }
    WATCH.with(|w| w.set(false));
    assert_eq!(ALLOCATIONS.with(Cell::get), 0);
    assert_eq!(DEALLOCATIONS.with(Cell::get), 0);
}
