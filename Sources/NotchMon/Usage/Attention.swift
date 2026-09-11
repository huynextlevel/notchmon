import CoreAudio
import Foundation

/// Whether this is a bad moment to be interrupted.
///
/// The one state the reminders should stand down for is a call: it is when the
/// notch opening is most in the way and least likely to be acted on, and it is
/// also the only such state this app can read **without asking for anything**.
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` is a fact about the device,
/// not about what is being recorded, so no microphone consent is involved and
/// no prompt appears.
///
/// What it cannot do is tell a meeting from a voice memo, and it will read true
/// for as long as any app holds the input open — a voice assistant that never
/// lets go would silence every reminder for good. So this is a switch rather
/// than a law, it errs toward *speaking* when the answer cannot be read, and a
/// held reminder is written to the log so a silence has somewhere to be traced.
enum Attention {

    /// Nil when the question cannot be answered, which is treated as "not in a
    /// call" by every caller: an unreadable device must not be able to switch
    /// the reminders off.
    static func micInUse() -> Bool? {
        guard let device = defaultInput() else { return nil }
        return running(device)
    }

    private static func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func running(_ device: AudioDeviceID) -> Bool? {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value != 0 : nil
    }
}
