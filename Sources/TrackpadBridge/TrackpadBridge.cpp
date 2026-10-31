#include "TrackpadBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <future>
#include <map>
#include <memory>
#include <mutex>
#include <pthread.h>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace {
// Measured modern MTContact ABI. Keep the unexposed fields to preserve stride.
// See README for provenance and the limits of this private interface.
struct NativeContact {
    uint64_t frame;
    double timestamp;
    int32_t pathID;
    uint32_t stage, classification;
    int32_t hand;
    float x, y, vx, vy, proximity, force, angle, major, minor;
    float physicalX, physicalY, physicalVX, physicalVY;
    uint16_t flags, unknown;
    float tilt, density;
};
static_assert(sizeof(NativeContact) == 96);
static_assert(offsetof(NativeContact, x) == 0x20);
static_assert(offsetof(NativeContact, major) == 0x3c);
using DeviceRef = CFTypeRef;
using Callback = int (*)(void *, const NativeContact *, int, double, uint64_t, void *);

double uptime() {
    static const double secondsPerTick = [] {
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        return double(timebase.numer) / double(timebase.denom) / 1e9;
    }();
    return double(mach_absolute_time()) * secondsPerTick;
}

struct RecordingBuffer {
    bool enabled = false;
    uint64_t dropped = 0;
    size_t capacity = 2048;
    std::deque<TPRecordedFrame> frames;

    void append(uint64_t deviceID, const TPFrame &frame) {
        if (!enabled) return;
        if (frames.size() >= capacity) { frames.pop_front(); ++dropped; }
        frames.push_back({deviceID, frame});
    }
};

struct Device {
    DeviceRef ref = nullptr;
    TPDeviceInfo info = {};
    TPFrame frame = {};
    uintptr_t token = 0;
    bool registered = false;
    bool started = false;
    std::shared_ptr<RecordingBuffer> recording;
    std::shared_ptr<RecordingBuffer> recognition;
    ~Device() { if (ref) CFRelease(ref); }
};

std::mutex registryLock;
std::map<uintptr_t, std::shared_ptr<Device>> registry;
uintptr_t nextToken = 0;

int receiveFrame(void *ref, const NativeContact *contacts, int count,
                 double timestamp, uint64_t sourceFrame, void *context) {
    const double callbackAt = uptime();
    if (count < 0 || count > TP_MAX_CONTACTS || (count && !contacts) || !std::isfinite(timestamp)) return 0;
    std::lock_guard<std::mutex> lock(registryLock);
    auto found = registry.find(reinterpret_cast<uintptr_t>(context));
    if (found == registry.end() || found->second->ref != ref) return 0;
    auto &frame = found->second->frame;
    frame.count = 0;
    frame.receivedAt = uptime();
    frame.callbackAt = callbackAt;
    frame.streamID = found->second->token;
    frame.sourceTimestamp = timestamp;
    frame.sourceFrame = sourceFrame;
    ++frame.sequence;
    for (int i = 0; i < count; ++i) {
        const auto &c = contacts[i];
        if (c.pathID < 0 || c.stage > 7 || !std::isfinite(c.x) || !std::isfinite(c.y) ||
            !std::isfinite(c.major) || !std::isfinite(c.minor) || !std::isfinite(c.angle)) continue;
        auto &out = frame.contacts[frame.count++];
        out = {c.pathID, c.stage, std::clamp(c.x, 0.0f, 1.0f), std::clamp(c.y, 0.0f, 1.0f),
               std::clamp(c.major, 0.5f, 35.0f), std::clamp(c.minor, 0.5f, 35.0f),
               c.angle, std::isfinite(c.force) ? std::max(0.0f, c.force) : 0.0f,
               std::isfinite(c.vx) ? c.vx : 0.0f, std::isfinite(c.vy) ? c.vy : 0.0f,
               std::isfinite(c.proximity) ? c.proximity : 0.0f,
               std::isfinite(c.tilt) ? c.tilt : 0.0f,
               std::isfinite(c.density) ? c.density : 0.0f, c.classification};
    }
    auto &recording = found->second->recording;
    if (recording) recording->append(found->second->info.id, frame);
    auto &recognition = found->second->recognition;
    if (recognition) recognition->append(found->second->info.id, frame);
    return 0;
}

CFTypeRef property(io_service_t service, CFStringRef key) {
    if (!service) return nullptr;
    return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key, kCFAllocatorDefault,
                                           kIORegistryIterateRecursively | kIORegistryIterateParents);
}

std::string stringProperty(io_service_t service, CFStringRef key) {
    CFTypeRef value = property(service, key);
    char text[256] = {};
    if (value && CFGetTypeID(value) == CFStringGetTypeID())
        CFStringGetCString(static_cast<CFStringRef>(value), text, sizeof(text), kCFStringEncodingUTF8);
    if (value) CFRelease(value);
    return text;
}

bool readColor(io_service_t service, TPDeviceInfo &info) {
    // Only use explicit RGB metadata; numeric model/color codes are not RGB.
    for (CFStringRef key : {CFSTR("DeviceColor"), CFSTR("device-color"), CFSTR("enclosure-color")}) {
        CFTypeRef value = property(service, key);
        if (!value) continue;
        unsigned r = 0, g = 0, b = 0;
        bool valid = false;
        if (CFGetTypeID(value) == CFStringGetTypeID()) {
            char text[80] = {};
            CFStringGetCString(static_cast<CFStringRef>(value), text, sizeof(text), kCFStringEncodingUTF8);
            valid = std::sscanf(text, "#%2x%2x%2x", &r, &g, &b) == 3;
        } else if (CFGetTypeID(value) == CFDataGetTypeID()) {
            auto data = static_cast<CFDataRef>(value);
            if (CFDataGetLength(data) == 3) {
                const auto *bytes = CFDataGetBytePtr(data);
                r = bytes[0]; g = bytes[1]; b = bytes[2]; valid = true;
            }
        }
        CFRelease(value);
        if (valid) {
            info.red = r / 255.0f; info.green = g / 255.0f; info.blue = b / 255.0f;
            info.hasColor = true;
            return true;
        }
    }
    return false;
}
}

struct TPMonitor {
    void *library = nullptr;
    CFArrayRef (*createList)() = nullptr;
    int (*getID)(DeviceRef, uint64_t *) = nullptr;
    bool (*isBuiltIn)(DeviceRef) = nullptr;
    int (*getDimensions)(DeviceRef, unsigned *, unsigned *) = nullptr;
    io_service_t (*getService)(DeviceRef) = nullptr;
    bool (*registerFrame)(DeviceRef, Callback, void *) = nullptr;
    int (*unregisterFrame)(DeviceRef, Callback) = nullptr;
    int (*start)(DeviceRef, int) = nullptr;
    int (*stop)(DeviceRef) = nullptr;
    std::vector<std::shared_ptr<Device>> devices;
    std::shared_ptr<RecordingBuffer> recording = std::make_shared<RecordingBuffer>();
    std::shared_ptr<RecordingBuffer> recognition = [] {
        auto buffer = std::make_shared<RecordingBuffer>();
        buffer->enabled = true;
        buffer->capacity = TP_RECOGNITION_CAPACITY;
        return buffer;
    }();
    std::mutex devicesLock;
    std::string error;
    std::thread worker;
    CFRunLoopRef runLoop = nullptr;
    CFRunLoopSourceRef jobsSource = nullptr;
    std::mutex jobsLock;
    std::deque<std::function<void()>> jobs;

    void drainJobs() {
        for (;;) {
            std::function<void()> job;
            {
                std::lock_guard<std::mutex> lock(jobsLock);
                if (jobs.empty()) return;
                job = std::move(jobs.front());
                jobs.pop_front();
            }
            job();
        }
    }

    void startWorker() {
        std::promise<void> ready;
        auto started = ready.get_future();
        worker = std::thread([this, &ready] {
            pthread_setname_np("Trackcard Capture");
            runLoop = CFRunLoopGetCurrent();
            CFRunLoopSourceContext context = {};
            context.info = this;
            context.perform = [](void *info) { static_cast<TPMonitor *>(info)->drainJobs(); };
            jobsSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
            CFRunLoopAddSource(runLoop, jobsSource, kCFRunLoopDefaultMode);
            ready.set_value();
            CFRunLoopRun();
            CFRunLoopRemoveSource(runLoop, jobsSource, kCFRunLoopDefaultMode);
            CFRelease(jobsSource);
        });
        started.wait();
    }

    void performSync(std::function<void()> job) {
        auto task = std::make_shared<std::packaged_task<void()>>(std::move(job));
        auto complete = task->get_future();
        {
            std::lock_guard<std::mutex> lock(jobsLock);
            jobs.push_back([task] { (*task)(); });
        }
        CFRunLoopSourceSignal(jobsSource);
        CFRunLoopWakeUp(runLoop);
        complete.get();
    }

    void refresh();

    template<typename T> bool load(T &destination, const char *name) {
        destination = reinterpret_cast<T>(dlsym(library, name));
        return destination != nullptr;
    }

    void detach(const std::shared_ptr<Device> &device) {
        {
            std::lock_guard<std::mutex> lock(registryLock);
            registry.erase(device->token);
        }
        if (device->registered) unregisterFrame(device->ref, receiveFrame);
        if (device->started) stop(device->ref);
        device->registered = device->started = false;
    }
};

TPMonitor *TPMonitorCreate() {
    auto *monitor = new TPMonitor;
    monitor->library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                              RTLD_NOW | RTLD_LOCAL);
    if (!monitor->library) {
        monitor->error = "MultitouchSupport is unavailable on this Mac.";
        return monitor;
    }
    if (!monitor->load(monitor->createList, "MTDeviceCreateList") ||
        !monitor->load(monitor->getID, "MTDeviceGetDeviceID") ||
        !monitor->load(monitor->isBuiltIn, "MTDeviceIsBuiltIn") ||
        !monitor->load(monitor->getDimensions, "MTDeviceGetSensorSurfaceDimensions") ||
        !monitor->load(monitor->getService, "MTDeviceGetService") ||
        !monitor->load(monitor->registerFrame, "MTRegisterContactFrameCallbackWithRefcon") ||
        !monitor->load(monitor->unregisterFrame, "MTUnregisterContactFrameCallback") ||
        !monitor->load(monitor->start, "MTDeviceStart") ||
        !monitor->load(monitor->stop, "MTDeviceStop")) {
        monitor->error = "This macOS version is missing a required multitouch interface.";
    }
    // Open and service devices on a dedicated run loop. AppKit can enter a
    // tracking or system-gesture mode without starving the capture lifecycle.
    if (monitor->error.empty()) monitor->startWorker();
    return monitor;
}

void TPMonitorDestroy(TPMonitor *monitor) {
    if (!monitor) return;
    if (monitor->worker.joinable()) {
        monitor->performSync([monitor] {
            std::lock_guard<std::mutex> lock(monitor->devicesLock);
            for (const auto &device : monitor->devices) monitor->detach(device);
            monitor->devices.clear();
            CFRunLoopStop(CFRunLoopGetCurrent());
        });
        monitor->worker.join();
    }
    // Keep the framework loaded: callback code may still be unwinding after stop.
    delete monitor;
}

const char *TPMonitorError(TPMonitor *monitor) { return monitor->error.c_str(); }

void TPMonitorRefresh(TPMonitor *monitor) {
    if (!monitor || !monitor->error.empty()) return;
    monitor->performSync([monitor] { monitor->refresh(); });
}

void TPMonitor::refresh() {
    std::lock_guard<std::mutex> lock(devicesLock);
    auto *monitor = this;
    CFArrayRef list = monitor->createList();
    if (!list) return;
    std::set<uint64_t> present;
    for (CFIndex i = 0; i < CFArrayGetCount(list); ++i) {
        DeviceRef ref = CFArrayGetValueAtIndex(list, i);
        uint64_t id = 0;
        unsigned width = 0, height = 0;
        if (monitor->getID(ref, &id) || !id ||
            monitor->getDimensions(ref, &width, &height) || width < 4000 || height < 3000 ||
            width > 25000 || height > 20000 || width <= height) continue;
        present.insert(id);
        auto existing = std::find_if(monitor->devices.begin(), monitor->devices.end(),
                                     [id](const auto &d) { return d->info.id == id; });
        if (existing != monitor->devices.end() || monitor->devices.size() >= TP_MAX_DEVICES) continue;
        auto device = std::make_shared<Device>();
        device->ref = CFRetain(ref);
        device->info.id = id;
        device->info.builtIn = monitor->isBuiltIn(ref);
        device->info.widthMM = width / 100.0;
        device->info.heightMM = height / 100.0;
        io_service_t service = monitor->getService(ref); // Borrowed service owned by MTDevice.
        std::string name = stringProperty(service, CFSTR("Product"));
        if (name.find("Mouse") != std::string::npos) continue;
        if (device->info.builtIn) name = "Built-in Trackpad";
        else if (name.empty()) name = "Magic Trackpad";
        std::snprintf(device->info.name, sizeof(device->info.name), "%s", name.c_str());
        readColor(service, device->info);
        device->recording = monitor->recording;
        device->recognition = monitor->recognition;
        {
            std::lock_guard<std::mutex> lock(registryLock);
            device->token = ++nextToken;
            registry[device->token] = device;
        }
        device->registered = monitor->registerFrame(ref, receiveFrame, reinterpret_cast<void *>(device->token));
        device->started = device->registered && monitor->start(ref, 0) == 0;
        if (device->started) monitor->devices.push_back(device);
        else monitor->detach(device); // Retry a failed open on the next refresh.
    }
    CFRelease(list);
    auto removed = std::remove_if(monitor->devices.begin(), monitor->devices.end(), [&](const auto &device) {
        if (present.count(device->info.id)) return false;
        monitor->detach(device);
        return true;
    });
    monitor->devices.erase(removed, monitor->devices.end());
}

int TPMonitorCopyDevices(TPMonitor *monitor, TPDeviceInfo *devices, int capacity) {
    if (!monitor || !devices || capacity <= 0) return 0;
    std::lock_guard<std::mutex> lock(monitor->devicesLock);
    int count = static_cast<int>(std::min<size_t>(capacity, monitor->devices.size()));
    for (int i = 0; i < count; ++i) devices[i] = monitor->devices[i]->info;
    return count;
}

bool TPMonitorCopyFrame(TPMonitor *monitor, uint64_t deviceID, TPFrame *frame) {
    if (!monitor || !frame) return false;
    std::lock_guard<std::mutex> devicesLock(monitor->devicesLock);
    std::lock_guard<std::mutex> lock(registryLock);
    for (const auto &device : monitor->devices) {
        if (device->info.id == deviceID) {
            *frame = device->frame;
            return frame->sequence > 0;
        }
    }
    return false;
}

void TPMonitorSetRecording(TPMonitor *monitor, bool enabled) {
    if (!monitor) return;
    std::lock_guard<std::mutex> lock(registryLock);
    monitor->recording->enabled = enabled;
    if (enabled) { monitor->recording->frames.clear(); monitor->recording->dropped = 0; }
}

int TPMonitorCopyRecordedFrames(TPMonitor *monitor, TPRecordedFrame *frames, int capacity, uint64_t *dropped) {
    if (!monitor || !frames || capacity <= 0) return 0;
    std::lock_guard<std::mutex> lock(registryLock);
    auto &buffer = *monitor->recording;
    if (dropped) *dropped = buffer.dropped;
    int count = std::min<int>(capacity, static_cast<int>(buffer.frames.size()));
    for (int i = 0; i < count; ++i) { frames[i] = buffer.frames.front(); buffer.frames.pop_front(); }
    return count;
}

int TPMonitorCopyRecognitionFrames(TPMonitor *monitor, TPRecordedFrame *frames, int capacity, uint64_t *dropped) {
    if (!monitor || !frames || capacity <= 0) return 0;
    std::lock_guard<std::mutex> lock(registryLock);
    auto &buffer = *monitor->recognition;
    if (dropped) *dropped = buffer.dropped;
    int count = std::min<int>(capacity, static_cast<int>(buffer.frames.size()));
    for (int i = 0; i < count; ++i) { frames[i] = buffer.frames.front(); buffer.frames.pop_front(); }
    return count;
}
