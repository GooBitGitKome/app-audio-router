//! Explicit hardware acceptance tests; never run against a live app implicitly.
use router_macos::*;
#[test]
#[ignore = "requires interactive macOS CoreAudio access"]
fn enumerate_real_devices() {
    let all = devices().expect("CoreAudio enumeration failed");
    assert!(
        !all.is_empty(),
        "no devices visible; hardware access is unverified"
    );
    assert!(all.iter().any(|device| device.output_channels > 0));
}
#[test]
#[ignore = "requires loopback driver; stop the running app before invoking"]
fn virtual_microphone_ownership_and_defaults() {
    let all = devices().unwrap();
    assert!(
        !all.iter().any(|d| d.uid == router_core::VIRTUAL_MIC_UID),
        "stop the running app and clean up its virtual mic before this test"
    );
    let original = all.iter().find(|d| d.default_input).map(|d| d.uid.clone());
    let source = loopback(&all).expect("install a bidirectional loopback driver");
    let owner = Aggregate::virtual_microphone(source).unwrap();
    let borrower = Aggregate::virtual_microphone(source).unwrap();
    assert_eq!(owner.id, borrower.id);
    assert!(owner.owned);
    assert!(!borrower.owned);
    drop(borrower);
    assert!(devices().unwrap().iter().any(|d| d.id == owner.id));
    assert_eq!(
        devices()
            .unwrap()
            .iter()
            .find(|d| d.default_input)
            .map(|d| d.uid.clone()),
        original
    );
    drop(owner);
    for _ in 0..50 {
        if !devices()
            .unwrap()
            .iter()
            .any(|d| d.uid == router_core::VIRTUAL_MIC_UID)
        {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    panic!("owned virtual microphone remained published after cleanup");
}
