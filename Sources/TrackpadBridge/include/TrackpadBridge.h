#ifndef TRACKPAD_BRIDGE_H
#define TRACKPAD_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TP_MAX_DEVICES 8
#define TP_MAX_CONTACTS 32
#define TP_RECOGNITION_CAPACITY 512

typedef struct TPMonitor TPMonitor;

typedef struct {
    uint64_t id;
    double widthMM;
    double heightMM;
    bool builtIn;
    bool hasColor;
    float red, green, blue;
    char name[128];
} TPDeviceInfo;

typedef struct {
    int32_t id;
    uint32_t stage;
    float x, y;
    float majorRadiusMM, minorRadiusMM;
    float angle;
    float force;
    float velocityX, velocityY, proximity, tilt, density;
    uint32_t classification;
} TPContact;

typedef struct {
    uint64_t sequence;
    double receivedAt;
    double callbackAt;
    uint64_t streamID;
    double sourceTimestamp;
    uint64_t sourceFrame;
    int32_t count;
    TPContact contacts[TP_MAX_CONTACTS];
} TPFrame;

typedef struct { uint64_t deviceID; TPFrame frame; } TPRecordedFrame;

// Call lifecycle functions on one thread; they marshal device work to a dedicated
// capture run loop. Frame snapshots are copied under a lock; Apple's borrowed
// callback memory never escapes the callback.
TPMonitor *TPMonitorCreate(void);
void TPMonitorDestroy(TPMonitor *monitor);
const char *TPMonitorError(TPMonitor *monitor);
void TPMonitorRefresh(TPMonitor *monitor);
int TPMonitorCopyDevices(TPMonitor *monitor, TPDeviceInfo *devices, int capacity);
bool TPMonitorCopyFrame(TPMonitor *monitor, uint64_t deviceID, TPFrame *frame);
// Independently consumed FIFO for recognition, including release/identity changes.
// Sequence gaps identify the affected device after bounded overflow. Neither
// snapshot reads nor recording start/stop/drain consume this stream.
int TPMonitorCopyRecognitionFrames(TPMonitor *monitor, TPRecordedFrame *frames, int capacity, uint64_t *dropped);
// Opt-in loss-accounted queue, separate from the preview's latest snapshots.
void TPMonitorSetRecording(TPMonitor *monitor, bool enabled);
int TPMonitorCopyRecordedFrames(TPMonitor *monitor, TPRecordedFrame *frames, int capacity, uint64_t *dropped);

#ifdef __cplusplus
}
#endif
#endif
