/*
 * Synthetic Dock swipe posting and real-swipe suppression.
 *
 * The event format, the macOS 27 IOHID payload, and the tap pass-through rules
 * are adapted from InstantSpaceSwitcher (https://github.com/jurplel/InstantSpaceSwitcher).
 *
 * MIT License
 *
 * Copyright (c) 2026 jurplel
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#include "include/dockswipe.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>

// MARK: - Private event constants

static const CGEventField kCGSEventTypeField = (CGEventField)55;
static const CGEventField kCGEventGestureHIDType = (CGEventField)110;
static const CGEventField kCGEventGestureSwipeMask = (CGEventField)115;
static const CGEventField kCGEventGestureSwipeMotion = (CGEventField)123;
static const CGEventField kCGEventGestureSwipeProgress = (CGEventField)124;
static const CGEventField kCGEventGestureSwipePositionX = (CGEventField)125;
static const CGEventField kCGEventGestureSwipePositionY = (CGEventField)126;
static const CGEventField kCGEventGestureSwipeVelocityX = (CGEventField)129;
static const CGEventField kCGEventGestureSwipeVelocityY = (CGEventField)130;
static const CGEventField kCGEventGesturePhase = (CGEventField)132;
static const CGEventField kCGEventGesturePhaseAlias = (CGEventField)134;
static const CGEventField kCGEventGestureZoomDeltaY = (CGEventField)138;
static const CGEventField kCGEventSourceUnixProcessIDAlias = (CGEventField)169;

static const uint32_t kIOHIDEventTypeDockSwipe = 23;
static const uint32_t kIOHIDEventTypeVelocity = 9;
static const uint32_t kIOHIDEventTypeFluidTouchGesture = 23;
static const uint16_t kIOHIDGestureFlavorDockPrimary = 3;

enum {
    kCGSEventGesture = 29,
    kCGSEventDockControl = 30,
};

enum {
    kCGSGesturePhaseBegan = 1,
    kCGSGesturePhaseChanged = 2,
    kCGSGesturePhaseEnded = 4,
    kCGSGesturePhaseCancelled = 8,
};

static const uint16_t kCGGestureMotionHorizontal = 1;

// Smallest non-zero 16.16 progress: keeps the direction, leaves the Dock nothing to animate.
static const double kMinimalProgress = 0.000016;
// The fling on the ended phase is what commits the switch on macOS 27 (16.16 fixed point, max ~32767).
static const double kModernFlingVelocity = 9999.0;
static const double kLegacyVelocity = 2000.0;
static const uint64_t kNanosecondsPerSecond = 1000000000ull;
// Our own events come back through the tap within milliseconds of being posted.
static const uint64_t kSyntheticWindow = kNanosecondsPerSecond;
// A real swipe that is being swallowed sends an event every few milliseconds while the fingers move.
static const uint64_t kTrackingStale = kNanosecondsPerSecond / 2;
// Our own events carry this in kCGEventSourceUserData, so the tap can tell them from the user's.
static const int64_t kOwnEventMark = 0x49535043; // "ISPC"
// The progress of our own swipes is kMinimalProgress, or that rounded to 16.16 fixed point. A real swipe
// that has moved is never this close to zero.
static const double kOwnProgressLimit = 0.00004;

// MARK: - State

// The gesture tap is on a thread of its own, so a busy main thread never holds back the gesture events
// of other apps. The main thread posts the swipes and sets `gSuppress`; the tap thread reads them.
// Everything the two threads share is atomic.
static CFMachPortRef gTap = NULL;
static atomic_bool gSuppress = false;
static atomic_bool gTracking = false;
// When the tap last swallowed an event of the real swipe it tracks. See kTrackingStale.
static _Atomic(uint64_t) gTrackedAt = 0;
// Our own events posted and not back through the tap yet, of each kind. One count for each kind, so an
// event of one kind never uses up the count of the other.
static atomic_uint gDockToPass = 0;
static atomic_uint gCompanionToPass = 0;
static _Atomic(uint64_t) gLastPostAt = 0;
// Set when an event of ours of that kind came back and could be told apart from the user's. From then on
// an event of that kind passes as ours only when it is ours, and a real event that comes in between our
// own can no longer take the place of one of them. Until then, the counts decide, as they always did.
static atomic_bool gOwnDockKnown = false;
static atomic_bool gOwnCompanionKnown = false;
// Set when an event of ours came back with its mark. From then on only the mark tells our events apart.
static atomic_bool gMarkSeen = false;
// Tap thread only.
static uint64_t gLastInterleaveLog = 0;
static os_log_t gLog = NULL;
// Main thread only.
static int gNaturalScrolling = -1;

static uint64_t now_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

// MARK: - macOS 27 payload

#pragma pack(push, 1)

typedef struct {
    uint32_t size;
    uint32_t type;
    uint32_t options;
    uint8_t depth;
    uint8_t reserved[3];
} IOHIDEventBase;

typedef struct {
    IOHIDEventBase base;
    int32_t position_x;
    int32_t position_y;
    int32_t position_z;
    uint32_t swipe_mask;
    uint16_t gesture_motion;
    uint16_t gesture_flavor;
    int32_t swipe_progress;
} IOHIDFluidTouchGestureData;

typedef struct {
    IOHIDEventBase base;
    int32_t velocity_x;
    int32_t velocity_y;
    int32_t velocity_z;
} IOHIDVelocityEventData;

typedef struct {
    uint64_t timestamp;
    uint64_t sender_id;
    uint32_t options;
    uint32_t attribute_length;
    uint32_t event_count;
} IOHIDSystemQueueElementHeader;

#pragma pack(pop)

_Static_assert(sizeof(IOHIDEventBase) == 16, "unexpected IOHID event base layout");
_Static_assert(sizeof(IOHIDFluidTouchGestureData) == 40, "unexpected IOHID fluid gesture layout");
_Static_assert(sizeof(IOHIDVelocityEventData) == 28, "unexpected IOHID velocity layout");
_Static_assert(sizeof(IOHIDSystemQueueElementHeader) == 28, "unexpected IOHID queue header layout");

static int32_t to_fixed1616(double value) {
    int32_t fixed = (int32_t)(value * 65536.0);
    if (fixed == 0 && value != 0.0) {
        return value > 0.0 ? 1 : -1;
    }
    return fixed;
}

static uint8_t *make_iohid_payload(CGEventRef event, size_t *outLength) {
    int64_t phase = CGEventGetIntegerValueField(event, kCGEventGesturePhase);
    int64_t motion = CGEventGetIntegerValueField(event, kCGEventGestureSwipeMotion);
    double progress = CGEventGetDoubleValueField(event, kCGEventGestureSwipeProgress);
    double posX = CGEventGetDoubleValueField(event, kCGEventGestureSwipePositionX);
    double posY = CGEventGetDoubleValueField(event, kCGEventGestureSwipePositionY);
    double velX = CGEventGetDoubleValueField(event, kCGEventGestureSwipeVelocityX);
    double velY = CGEventGetDoubleValueField(event, kCGEventGestureSwipeVelocityY);
    int64_t swipeMask = CGEventGetIntegerValueField(event, kCGEventGestureSwipeMask);

    bool includeVelocity = (velX != 0.0 || velY != 0.0 || phase == kCGSGesturePhaseEnded);
    size_t length = sizeof(IOHIDSystemQueueElementHeader) + sizeof(IOHIDFluidTouchGestureData);
    if (includeVelocity) {
        length += sizeof(IOHIDVelocityEventData);
    }

    uint8_t *payload = (uint8_t *)calloc(1, length);
    if (!payload) {
        return NULL;
    }

    IOHIDSystemQueueElementHeader *header = (IOHIDSystemQueueElementHeader *)payload;
    uint64_t timestamp = CGEventGetTimestamp(event);
    header->timestamp = timestamp != 0 ? timestamp : mach_absolute_time();
    header->event_count = includeVelocity ? 2 : 1;

    IOHIDFluidTouchGestureData *fluid =
        (IOHIDFluidTouchGestureData *)(payload + sizeof(IOHIDSystemQueueElementHeader));
    fluid->base.size = sizeof(IOHIDFluidTouchGestureData);
    fluid->base.type = kIOHIDEventTypeFluidTouchGesture;
    fluid->base.options = (uint32_t)((phase & 0xFF) << 24);
    fluid->position_x = to_fixed1616(posX);
    fluid->position_y = to_fixed1616(posY);
    fluid->swipe_mask = (uint32_t)swipeMask;
    fluid->gesture_motion = (uint16_t)motion;
    fluid->gesture_flavor = kIOHIDGestureFlavorDockPrimary;
    fluid->swipe_progress = to_fixed1616(progress);

    if (includeVelocity) {
        IOHIDVelocityEventData *velocity = (IOHIDVelocityEventData *)(
            payload + sizeof(IOHIDSystemQueueElementHeader) + sizeof(IOHIDFluidTouchGestureData));
        velocity->base.size = sizeof(IOHIDVelocityEventData);
        velocity->base.type = kIOHIDEventTypeVelocity;
        velocity->base.depth = 1;
        velocity->velocity_x = to_fixed1616(velX);
        velocity->velocity_y = to_fixed1616(velY);
    }

    *outLength = length;
    return payload;
}

/// Appends the IOHID payload (field 4205) to the serialized event. Returns a retained event.
static CGEventRef augment_event(CGEventRef event) {
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
    if (!data) {
        return NULL;
    }

    const uint8_t *bytes = CFDataGetBytePtr(data);
    CFIndex length = CFDataGetLength(data);

    // Serialized format version 2 only.
    if (length < 4 || bytes[0] != 0 || bytes[1] != 0 || bytes[2] != 0 || bytes[3] != 2) {
        CFRelease(data);
        return NULL;
    }

    size_t payloadLength = 0;
    uint8_t *payload = make_iohid_payload(event, &payloadLength);
    if (!payload) {
        CFRelease(data);
        return NULL;
    }

    size_t newLength = (size_t)length + 4 + payloadLength;
    uint8_t *newBytes = (uint8_t *)malloc(newLength);
    if (!newBytes) {
        free(payload);
        CFRelease(data);
        return NULL;
    }

    memcpy(newBytes, bytes, (size_t)length);
    // 4-byte tag: payload size, then field ID 4205, both big-endian.
    newBytes[length] = (uint8_t)((payloadLength >> 8) & 0xFF);
    newBytes[length + 1] = (uint8_t)(payloadLength & 0xFF);
    newBytes[length + 2] = (uint8_t)((4205 >> 8) & 0xFF);
    newBytes[length + 3] = (uint8_t)(4205 & 0xFF);
    memcpy(newBytes + length + 4, payload, payloadLength);

    free(payload);
    CFRelease(data);

    CFDataRef newData = CFDataCreate(kCFAllocatorDefault, newBytes, (CFIndex)newLength);
    free(newBytes);
    if (!newData) {
        return NULL;
    }

    CGEventRef result = CGEventCreateFromData(kCFAllocatorDefault, newData);
    CFRelease(newData);
    return result;
}

bool ds_requires_event_augmentation(void) {
    // The main thread and the tap thread both ask.
    static atomic_int cached = -1;
    int value = atomic_load(&cached);
    if (value != -1) {
        return value;
    }

    char version[32] = {0};
    size_t size = sizeof(version);
    int major = 0;
    if (sysctlbyname("kern.osproductversion", version, &size, NULL, 0) != 0 ||
        sscanf(version, "%d", &major) < 1) {
        atomic_store(&cached, 0);
        return false;
    }

    value = (major >= 27) ? 1 : 0;
    atomic_store(&cached, value);
    return value;
}

// MARK: - Posting

static void natural_scrolling_changed(CFNotificationCenterRef center, void *observer,
                                      CFNotificationName name, const void *object,
                                      CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    gNaturalScrolling = -1;
}

// On macOS 27 "right" is negative, and the Dock reads the posted sign through the
// natural scrolling preference, so it flips again with natural scrolling off.
static double modern_swipe_sign(DSDirection direction) {
    if (gNaturalScrolling < 0) {
        Boolean valid = false;
        Boolean natural = CFPreferencesGetAppBooleanValue(CFSTR("com.apple.swipescrolldirection"),
                                                          kCFPreferencesAnyApplication, &valid);
        gNaturalScrolling = (!valid || natural) ? 1 : 0;
    }
    const double sign = (direction == DSDirectionRight) ? -1.0 : 1.0;
    return gNaturalScrolling ? sign : -sign;
}

static bool post_modern(int phase, DSDirection direction) {
    const double sign = modern_swipe_sign(direction);

    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) {
        return false;
    }
    CGEventSetIntegerValueField(ev, kCGSEventTypeField, kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase, phase);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion, kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeProgress, sign * kMinimalProgress);
    // Fields a real trackpad swipe carries.
    CGEventSetIntegerValueField(ev, kCGEventGesturePhaseAlias, phase);
    CGEventSetDoubleValueField(ev, kCGEventGestureZoomDeltaY, 3.0);
    CGEventSetDoubleValueField(ev, kCGEventSourceUnixProcessIDAlias, (double)mach_absolute_time());
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipePositionX, 0.1);
    if (phase == kCGSGesturePhaseEnded) {
        CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityX, sign * kModernFlingVelocity);
    }

    CGEventRef augmented = augment_event(ev);
    CFRelease(ev);
    if (!augmented) {
        return false;
    }

    // The Dock ignores a DockControl event without a companion gesture event.
    CGEventRef companion = CGEventCreate(NULL);
    if (!companion) {
        CFRelease(augmented);
        return false;
    }
    CGEventSetIntegerValueField(companion, kCGSEventTypeField, kCGSEventGesture);
    // Marked as ours for the tap, on the events as they are posted: after the serialization above.
    CGEventSetIntegerValueField(augmented, kCGEventSourceUserData, kOwnEventMark);
    CGEventSetIntegerValueField(companion, kCGEventSourceUserData, kOwnEventMark);

    if (gTap) {
        // Before the events are posted: the tap thread can get them at once.
        atomic_fetch_add(&gDockToPass, 1);
        atomic_fetch_add(&gCompanionToPass, 1);
    }
    CGEventPost(kCGSessionEventTap, augmented);
    CGEventPost(kCGSessionEventTap, companion);
    CFRelease(augmented);
    CFRelease(companion);
    return true;
}

static bool post_legacy(int phase, DSDirection direction) {
    const bool isRight = (direction == DSDirectionRight);
    const double velocity = isRight ? kLegacyVelocity : -kLegacyVelocity;

    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) {
        return false;
    }
    CGEventSetIntegerValueField(ev, kCGSEventTypeField, kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase, phase);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeProgress, isRight ? kMinimalProgress : -kMinimalProgress);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion, kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityX, velocity);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityY, velocity);
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
    return true;
}

static bool post_phase(int phase, DSDirection direction) {
    return ds_requires_event_augmentation() ? post_modern(phase, direction)
                                            : post_legacy(phase, direction);
}

bool ds_post_switch(DSDirection direction) {
    // All three phases are needed; with only began + ended Mission Control breaks.
    // The time is set before the counts go up: see `expire_count`.
    atomic_store(&gLastPostAt, now_ns());
    return post_phase(kCGSGesturePhaseBegan, direction)
        && post_phase(kCGSGesturePhaseChanged, direction)
        && post_phase(kCGSGesturePhaseEnded, direction);
}

// MARK: - Tap

// A count left over after the burst would let real swipes slip past the suppression.
// The count is read before the time, and the time before now. If the main thread posts a new swipe between
// the reads, the time is new and nothing is cleared. If it posts after them, the count has changed and the
// exchange fails. So a swipe that is being posted now never loses its count.
static void expire_count(atomic_uint *count) {
    unsigned int pending = atomic_load(count);
    if (pending == 0) return;
    uint64_t posted = atomic_load(&gLastPostAt);
    uint64_t now = now_ns();
    if (now > posted && now - posted > kSyntheticWindow) {
        atomic_compare_exchange_strong(count, &pending, 0);
    }
}

static bool take_one(atomic_uint *count) {
    unsigned int pending = atomic_load(count);
    while (pending > 0) {
        // On failure `pending` gets the current count, and the loop tries again.
        if (atomic_compare_exchange_weak(count, &pending, pending - 1)) {
            return true;
        }
    }
    return false;
}

/// True for an event we posted. The mark is the sure sign. If the mark does not come back through the
/// window server, a Dock event of ours still has the tiny progress of our swipes. That sign is used only
/// while no mark has been seen, and only while Dock events of ours are on their way: the first changed
/// event of a real swipe can have a progress that small. Before macOS 27 our events are never counted,
/// so it is never used there.
static bool is_own_event(CGEventRef event, bool isDock, bool *byMark) {
    *byMark = CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kOwnEventMark;
    if (*byMark) {
        atomic_store(&gMarkSeen, true);
        return true;
    }
    if (!isDock || atomic_load(&gMarkSeen) || atomic_load(&gDockToPass) == 0) return false;
    if ((uint32_t)CGEventGetIntegerValueField(event, kCGEventGestureHIDType) != kIOHIDEventTypeDockSwipe) return false;
    double progress = fabs(CGEventGetDoubleValueField(event, kCGEventGestureSwipeProgress));
    return progress > 0.0 && progress <= kOwnProgressLimit;
}

static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy;
    (void)refcon;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gTap) CGEventTapEnable(gTap, true);
        // Anything posted while the tap was disabled never reaches us.
        atomic_store(&gDockToPass, 0);
        atomic_store(&gCompanionToPass, 0);
        return event;
    }

    uint32_t eventType = (uint32_t)CGEventGetIntegerValueField(event, kCGSEventTypeField);
    bool isDock = (eventType == kCGSEventDockControl);
    bool isGestureEvent = isDock || eventType == kCGSEventGesture;

    // On macOS 27 our own swipes re-enter the tap with sourcePid == 0, as the user's do. They pass.
    if (isGestureEvent) {
        atomic_uint *count = isDock ? &gDockToPass : &gCompanionToPass;
        atomic_bool *known = isDock ? &gOwnDockKnown : &gOwnCompanionKnown;
        expire_count(count);
        bool byMark = false;
        if (is_own_event(event, isDock, &byMark)) {
            take_one(count);
            if (!atomic_exchange(known, true)) {
                os_log(gLog, "the tap tells our own %{public}s events from the user's, %{public}s",
                       isDock ? "Dock" : "gesture", byMark ? "by their mark" : "by their progress");
            }
            return event;
        }
        if (atomic_load(count) > 0) {
            if (!atomic_load(known)) {
                // It is not known yet if our events of this kind can be told apart: count them out.
                if (take_one(count)) return event;
            } else {
                // The case that used to let a real event take the place of one of ours.
                uint64_t now = now_ns();
                if (now - gLastInterleaveLog > kNanosecondsPerSecond) {
                    gLastInterleaveLog = now;
                    os_log(gLog, "a real %{public}s event came between our own, and is handled as the user's",
                           isDock ? "Dock" : "gesture");
                }
            }
        }
    }

    if (!atomic_load(&gSuppress)) {
        atomic_store(&gTracking, false);
        return event;
    }

    // Real trackpad gesture events have sourcePid == 0 (HID). Leave other synthetic events alone.
    if (isGestureEvent) {
        pid_t sourcePid = (pid_t)CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
        if (sourcePid != 0) return event;
    }

    if (eventType == kCGSEventDockControl) {
        uint32_t hidType = (uint32_t)CGEventGetIntegerValueField(event, kCGEventGestureHIDType);
        if (hidType != kIOHIDEventTypeDockSwipe) return event;

        uint16_t motion = (uint16_t)CGEventGetIntegerValueField(event, kCGEventGestureSwipeMotion);
        if (motion != kCGGestureMotionHorizontal) return event;

        int64_t phase = CGEventGetIntegerValueField(event, kCGEventGesturePhase);
        switch (phase) {
        case kCGSGesturePhaseBegan:
            atomic_store(&gTracking, true);
            atomic_store(&gTrackedAt, now_ns());
            return NULL;

        case kCGSGesturePhaseEnded:
            if (!atomic_exchange(&gTracking, false)) return event;
            if (ds_requires_event_augmentation()) {
                // On macOS 27 the Dock needs the real ended event to close its gesture
                // state. Zero the motion so it does not switch by itself.
                CGEventSetDoubleValueField(event, kCGEventGestureSwipeProgress, 0.0);
                CGEventSetDoubleValueField(event, kCGEventGestureSwipeVelocityX, 0.0);
                CGEventSetDoubleValueField(event, kCGEventGestureSwipeVelocityY, 0.0);
                return event;
            }
            return NULL;

        case kCGSGesturePhaseCancelled:
            if (!atomic_exchange(&gTracking, false)) return event;
            return NULL;

        default:
            if (!atomic_load(&gTracking)) return event;
            atomic_store(&gTrackedAt, now_ns());
            return NULL;
        }
    }

    // Companion gesture events of a swipe we are swallowing. Only while that swipe is alive: a tracking
    // state whose ended event was lost must not swallow the pinches, rotations and swipes that come after.
    if (eventType == kCGSEventGesture && atomic_load(&gTracking)) {
        uint64_t tracked = atomic_load(&gTrackedAt);
        uint64_t now = now_ns();
        if (now < tracked || now - tracked < kTrackingStale) {
            atomic_store(&gTrackedAt, now);
            return NULL;
        }
    }

    return event;
}

static void *gesture_tap_thread(void *context) {
    CFRunLoopSourceRef source = (CFRunLoopSourceRef)context;
    pthread_setname_np("com.cnrad.interspace.gestures");
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    CGEventTapEnable(gTap, true);
    CFRunLoopRun();
    return NULL;
}

bool ds_tap_install(void) {
    if (gTap) {
        return true;
    }

    CGEventMask mask = (1ULL << kCGSEventGesture) | (1ULL << kCGSEventDockControl);
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                         mask, tap_callback, NULL);
    if (!tap) {
        return false;
    }

    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    if (!source) {
        CFRelease(tap);
        return false;
    }
    gTap = tap;
    if (!gLog) {
        gLog = os_log_create("com.cnrad.interspace", "tap");
    }

    pthread_t thread;
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    // The gestures of the user, in every app, wait for this thread.
    pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_USER_INTERACTIVE, 0);
    int failed = pthread_create(&thread, &attributes, gesture_tap_thread, (void *)source);
    pthread_attr_destroy(&attributes);
    if (failed) {
        CFRelease(source);
        CFRelease(tap);
        gTap = NULL;
        return false;
    }

    gNaturalScrolling = -1;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), &gNaturalScrolling,
                                    natural_scrolling_changed,
                                    CFSTR("SwipeScrollDirectionDidChangeNotification"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    return true;
}

void ds_tap_set_suppress(bool suppress) {
    atomic_store(&gSuppress, suppress);
    if (!suppress) {
        atomic_store(&gTracking, false);
    }
}

// MARK: - Keyboard shortcuts

// The tap is on a thread of its own. Every key press of the user waits for this callback, so it must
// never wait for the main thread. The state it reads is atomic and the callback only compares numbers.

static const CGEventFlags kShortcutModifiers =
    kCGEventFlagMaskShift | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand;

static CFMachPortRef gKeyTap = NULL;
static DSKeyHandler gKeyHandler = NULL;
static atomic_bool gKeysEnabled = false;
// Index 0 is left, 1 is right, as in DSDirection.
static atomic_int gKeyCode[2] = {-1, -1};
static atomic_ullong gKeyFlags[2] = {0, 0};
// The key down was swallowed, so its key up must be too.
static atomic_bool gKeyHeld[2] = {false, false};

static CGEventRef key_tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy;
    (void)refcon;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gKeyTap) CGEventTapEnable(gKeyTap, true);
        // A key up that came while the tap was off went to the system. Waiting for it would swallow the
        // key up of a later press that is not ours.
        atomic_store(&gKeyHeld[0], false);
        atomic_store(&gKeyHeld[1], false);
        return event;
    }
    if (type != kCGEventKeyDown && type != kCGEventKeyUp) {
        return event;
    }

    int code = (int)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);

    if (type == kCGEventKeyUp) {
        for (int direction = 0; direction < 2; direction++) {
            if (code == atomic_load(&gKeyCode[direction]) && atomic_exchange(&gKeyHeld[direction], false)) {
                return NULL;
            }
        }
        return event;
    }

    if (!atomic_load(&gKeysEnabled)) {
        return event;
    }
    unsigned long long flags = (unsigned long long)(CGEventGetFlags(event) & kShortcutModifiers);
    for (int direction = 0; direction < 2; direction++) {
        int wanted = atomic_load(&gKeyCode[direction]);
        if (wanted < 0 || code != wanted || flags != atomic_load(&gKeyFlags[direction])) {
            continue;
        }
        atomic_store(&gKeyHeld[direction], true);
        // A key that is held down sends the press again and again. Only the first one is a step.
        bool isRepeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
        if (!isRepeat && gKeyHandler) {
            gKeyHandler(direction == 0 ? DSDirectionLeft : DSDirectionRight);
        }
        return NULL;
    }
    return event;
}

static void *key_tap_thread(void *context) {
    CFRunLoopSourceRef source = (CFRunLoopSourceRef)context;
    pthread_setname_np("com.cnrad.interspace.keys");
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    CGEventTapEnable(gKeyTap, true);
    CFRunLoopRun();
    return NULL;
}

bool ds_keys_install(DSKeyHandler handler) {
    if (gKeyTap) {
        return true;
    }
    gKeyHandler = handler;

    // Where key events enter the window server: before macOS reads them as its own shortcuts.
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    CFMachPortRef tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                         mask, key_tap_callback, NULL);
    if (!tap) {
        return false;
    }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    if (!source) {
        CFRelease(tap);
        return false;
    }
    gKeyTap = tap;

    pthread_t thread;
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    // Key presses of the user wait for this thread.
    pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_USER_INTERACTIVE, 0);
    int failed = pthread_create(&thread, &attributes, key_tap_thread, (void *)source);
    pthread_attr_destroy(&attributes);
    if (failed) {
        CFRelease(source);
        CFRelease(tap);
        gKeyTap = NULL;
        return false;
    }
    return true;
}

void ds_keys_configure(bool enabled, int leftKeyCode, unsigned long long leftFlags,
                       int rightKeyCode, unsigned long long rightFlags) {
    atomic_store(&gKeyCode[0], leftKeyCode);
    atomic_store(&gKeyFlags[0], leftFlags & kShortcutModifiers);
    atomic_store(&gKeyCode[1], rightKeyCode);
    atomic_store(&gKeyFlags[1], rightFlags & kShortcutModifiers);
    atomic_store(&gKeysEnabled, enabled);
}
