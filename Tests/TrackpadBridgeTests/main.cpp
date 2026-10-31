// Exercise the actual callback and locking/drain APIs without opening hardware.
#include "../../Sources/TrackpadBridge/TrackpadBridge.cpp"
#include <cassert>
#include <atomic>

int main() {
    TPMonitor monitor;
    auto device = std::make_shared<Device>();
    device->info.id = 17;
    device->token = 1001;
    device->recording = monitor.recording;
    device->recognition = monitor.recognition;
    monitor.devices.push_back(device);
    registry[device->token] = device;
    NativeContact contact = {};
    contact.pathID = 7; contact.stage = 4; contact.x = 0.5; contact.y = 0.4;
    contact.major = 6; contact.minor = 4;
    auto send = [&](int count, uint64_t sourceFrame) {
        receiveFrame(nullptr, count ? &contact : nullptr, count, 100 + sourceFrame * 0.008,
                     sourceFrame, reinterpret_cast<void *>(device->token));
    };
    std::vector<TPRecordedFrame> frames(2048);
    uint64_t dropped = 0;

    TPMonitorSetRecording(&monitor, true);
    send(1, 1);
    contact.pathID = 11;
    send(1, 2);
    send(0, 3);
    TPFrame latest = {};
    assert(TPMonitorCopyFrame(&monitor, 17, &latest) && latest.sequence == 3 && latest.count == 0);
    assert(TPMonitorCopyRecognitionFrames(&monitor, frames.data(), 2, &dropped) == 2 && dropped == 0);
    assert(frames[0].frame.contacts[0].id == 7 && frames[1].frame.contacts[0].id == 11);
    assert(frames[0].frame.callbackAt <= frames[0].frame.receivedAt && frames[0].frame.callbackAt > 0);
    assert(frames[0].frame.streamID == device->token && frames[0].deviceID == 17);
    assert(TPMonitorCopyRecognitionFrames(&monitor, frames.data(), 2, &dropped) == 1 && frames[0].frame.count == 0);
    assert(TPMonitorCopyRecognitionFrames(&monitor, frames.data(), 2, &dropped) == 0);
    assert(TPMonitorCopyRecordedFrames(&monitor, frames.data(), 2048, &dropped) == 3 && dropped == 0);

    // Recording start/stop/drain cannot reset or consume recognition frames.
    TPMonitorSetRecording(&monitor, false);
    send(1, 4);
    TPMonitorSetRecording(&monitor, true);
    send(0, 5);
    assert(TPMonitorCopyRecordedFrames(&monitor, frames.data(), 2048, &dropped) == 1);
    assert(TPMonitorCopyRecognitionFrames(&monitor, frames.data(), 2048, &dropped) == 2);
    assert(frames[0].frame.sequence == 4 && frames[1].frame.sequence == 5);

    // Overflow is bounded and observable through both dropped count and sequence.
    for (uint64_t i = 6; i < 1030; ++i) send(1, i);
    assert(TPMonitorCopyRecognitionFrames(&monitor, frames.data(), 2048, &dropped) == TP_RECOGNITION_CAPACITY);
    assert(dropped == 512 && frames[0].frame.sequence == 518 && frames[511].frame.sequence == 1029);
    assert(TPMonitorCopyRecordedFrames(&monitor, frames.data(), 2048, &dropped) == 1024 && dropped == 0);

    // Concurrent capture/draining preserves order and accounts for every frame.
    std::atomic<bool> done{false};
    constexpr uint64_t sent = 10000;
    std::thread producer([&] {
        for (uint64_t i = 1030; i < 1030 + sent; ++i) send(1, i);
        done = true;
    });
    uint64_t delivered = 0, previous = 1029;
    do {
        int count = TPMonitorCopyRecognitionFrames(&monitor, frames.data(), 37, &dropped);
        for (int i = 0; i < count; ++i) {
            assert(frames[i].frame.sequence > previous);
            previous = frames[i].frame.sequence;
        }
        delivered += count;
        std::this_thread::yield();
    } while (!done || previous < 1029 + sent);
    producer.join();
    assert(delivered + (dropped - 512) == sent);
    assert(monitor.recognition->frames.empty());

    auto second = std::make_shared<Device>();
    second->info.id = 18; second->token = 1002;
    second->recording = monitor.recording; second->recognition = monitor.recognition;
    registry[second->token] = second;
    receiveFrame(nullptr, &contact, 1, 10, 1, reinterpret_cast<void *>(second->token));
    send(0, 11030);
    assert(TPMonitorCopyRecognitionFrames(&monitor, frames.data(), 2048, &dropped) == 2);
    assert(frames[0].deviceID == 18 && frames[0].frame.sequence == 1);
    assert(frames[1].deviceID == 17 && frames[1].frame.count == 0);
    registry.erase(second->token);
    registry.erase(device->token);
    send(0, 11030); // A late callback from a detached device is ignored.
    assert(TPMonitorCopyRecognitionFrames(&monitor, frames.data(), 2048, &dropped) == 0);
    puts("Bridge checks passed: FIFO, releases, snapshots, recording independence, bounded loss, concurrent drains, detachment.");
}
