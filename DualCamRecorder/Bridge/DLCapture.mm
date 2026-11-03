//
//  DLCapture.mm
//  DualCamRecorder
//
//  Objective-C++ bridge to the Blackmagic DeckLink SDK.
//
//  API usage follows the SDK headers (DeckLinkAPI.h, DeckLinkAPIModes.h, DeckLinkAPIConfiguration.h)
//  and the pattern of the SDK "CapturePreview"/"Capture" samples:
//    discovery  : CreateDeckLinkDiscoveryInstance() + IDeckLinkDeviceNotificationCallback
//    capture    : IDeckLink -> QueryInterface(IID_IDeckLinkInput) -> EnableVideoInput(..., bmdVideoInputEnableFormatDetection)
//                 -> EnableAudioInput(48kHz, 32bit) -> SetCallback -> StartStreams
//    auto format: IDeckLinkInputCallback::VideoInputFormatChanged -> PauseStreams -> EnableVideoInput(newMode)
//                 -> FlushStreams -> StartStreams
//
//  SDK 14.3+ removed IDeckLinkVideoFrame::GetBytes in favour of IDeckLinkVideoBuffer. Like FFmpeg's
//  decklink device, we use the legacy *_v14_2_1 interfaces shipped with those SDKs, so the same code
//  compiles with SDK 12.x – 15.x.
//
//  If the SDK headers are not found (./DeckLinkSDK/Mac/include not present) the bridge compiles to a stub
//  that reports "no devices", so the app can still be built and used in simulated-input mode.
//

#import "DLCapture.h"
#import <CoreVideo/CoreVideo.h>
#include <time.h>
#include <atomic>
#include <mutex>
#include <map>
#include <vector>
#include <string>
#include <cmath>

uint64_t DLHostTimeNanos(void)
{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

#if __has_include("DeckLinkAPI.h")
#define DL_HAS_SDK 1
#include "DeckLinkAPI.h"
#include "DeckLinkAPIVersion.h"

#if BLACKMAGIC_DECKLINK_API_VERSION < 0x0b000000
#error "DeckLink SDK 11.0 or newer is required (IDeckLinkProfileAttributes)."
#endif

#if BLACKMAGIC_DECKLINK_API_VERSION >= 0x0e030000
#include "DeckLinkAPI_v14_2_1.h"
typedef IDeckLinkInput_v14_2_1            DLInputInterface;
typedef IDeckLinkInputCallback_v14_2_1    DLInputCallbackInterface;
typedef IDeckLinkVideoInputFrame_v14_2_1  DLVideoInputFrame;
#define DL_IID_INPUT                      IID_IDeckLinkInput_v14_2_1
#define DL_IID_INPUT_CALLBACK             IID_IDeckLinkInputCallback_v14_2_1
#else
typedef IDeckLinkInput                    DLInputInterface;
typedef IDeckLinkInputCallback            DLInputCallbackInterface;
typedef IDeckLinkVideoInputFrame          DLVideoInputFrame;
#define DL_IID_INPUT                      IID_IDeckLinkInput
#define DL_IID_INPUT_CALLBACK             IID_IDeckLinkInputCallback
#endif

// The dispatch file dynamically loads /Library/Frameworks/DeckLinkAPI.framework.
// Including it here keeps the Xcode project independent of the SDK folder layout.
#include "DeckLinkAPIDispatch.cpp"

#else
#define DL_HAS_SDK 0
#warning "DeckLink SDK headers not found (DeckLinkSDK/Mac/include) - building with simulated input only."
#endif

static NSString *const DLErrorDomain = @"DLCaptureErrorDomain";

static NSError *DLMakeError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:DLErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - Model objects

@interface DLDeviceDescriptor ()
@property (nonatomic, readwrite, copy) NSString *identifier;
@property (nonatomic, readwrite, copy) NSString *displayName;
@property (nonatomic, readwrite, copy) NSString *modelName;
@property (nonatomic, readwrite) BOOL supportsCapture;
@property (nonatomic, readwrite) BOOL supportsPlayback;
@property (nonatomic, readwrite) BOOL supportsFormatDetection;
@property (nonatomic, readwrite) NSInteger maxAudioChannels;
@end

@implementation DLDeviceDescriptor
- (BOOL)isEqual:(id)object
{
    return [object isKindOfClass:[DLDeviceDescriptor class]] && [((DLDeviceDescriptor *)object).identifier isEqualToString:self.identifier];
}
- (NSUInteger)hash { return self.identifier.hash; }
@end

@interface DLFormatInfo ()
@property (nonatomic, readwrite, copy) NSString *modeName;
@property (nonatomic, readwrite) int32_t width;
@property (nonatomic, readwrite) int32_t height;
@property (nonatomic, readwrite) int64_t frameDuration;
@property (nonatomic, readwrite) int64_t timeScale;
@property (nonatomic, readwrite) BOOL interlaced;
@property (nonatomic, readwrite) BOOL rgb444;
@property (nonatomic, readwrite) int32_t bitDepth;
@property (nonatomic, readwrite) OSType pixelFormat;
@end

@implementation DLFormatInfo
@end

@interface DLCaptureFrame () {
    CVPixelBufferRef _pixelBuffer;
}
@property (nonatomic, readwrite) int64_t streamTime;
@property (nonatomic, readwrite) int64_t frameDuration;
@property (nonatomic, readwrite) int64_t timeScale;
@property (nonatomic, readwrite) uint64_t hostTimeNanos;
@property (nonatomic, readwrite) BOOL hasSignal;
@property (nonatomic, readwrite) uint32_t droppedBefore;
@property (nonatomic, readwrite, nullable) NSData *audioData;
@property (nonatomic, readwrite) int32_t audioSampleFrames;
@property (nonatomic, readwrite) int32_t audioChannels;
@property (nonatomic, readwrite) int64_t audioPacketTime;
@property (nonatomic, readwrite) BOOL hasTimecode;
@property (nonatomic, readwrite) uint8_t tcHours;
@property (nonatomic, readwrite) uint8_t tcMinutes;
@property (nonatomic, readwrite) uint8_t tcSeconds;
@property (nonatomic, readwrite) uint8_t tcFrames;
@property (nonatomic, readwrite) BOOL tcDropFrame;
@property (nonatomic, readwrite) uint32_t tcUserBits;
@property (nonatomic, readwrite) int8_t recordTrigger;
@property (nonatomic, readwrite) BOOL blackmagicTally;
@property (nonatomic, readwrite, nullable) NSArray<DLAncillaryPacket *> *ancillaryPackets;
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer;
@end

@interface DLAncillaryPacket ()
@property (nonatomic, readwrite) uint8_t did;
@property (nonatomic, readwrite) uint8_t sdid;
@property (nonatomic, readwrite) uint32_t lineNumber;
@property (nonatomic, readwrite) uint8_t dataStreamIndex;
@property (nonatomic, readwrite, copy) NSData *data;
@end

@implementation DLAncillaryPacket
@end

@implementation DLCaptureFrame
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    if ((self = [super init])) {
        _pixelBuffer = CVPixelBufferRetain(pixelBuffer);
        _recordTrigger = -1;
    }
    return self;
}
- (void)dealloc { CVPixelBufferRelease(_pixelBuffer); }
- (CVPixelBufferRef)pixelBuffer { return _pixelBuffer; }
@end

#if DL_HAS_SDK

#pragma mark - Helpers (SDK)

static NSString *DLStringFromCF(CFStringRef str)
{
    if (str == NULL) return @"";
    return (__bridge_transfer NSString *)str;
}

static OSType DLCVPixelFormat(BMDPixelFormat pf)
{
    switch (pf) {
        case bmdFormat8BitYUV:  return kCVPixelFormatType_422YpCbCr8;   // '2vuy'
        case bmdFormat10BitYUV: return kCVPixelFormatType_422YpCbCr10;  // 'v210'
        case bmdFormat8BitBGRA: return kCVPixelFormatType_32BGRA;
        default:                return 0;
    }
}

static bool DLGuidEqual(REFIID a, REFIID b) { return memcmp(&a, &b, sizeof(REFIID)) == 0; }

/// Global registry of present devices (identifier -> IDeckLink*). Each entry holds one reference.
static std::mutex gRegistryMutex;
static std::map<std::string, IDeckLink *> gRegistry;

static IDeckLink *DLCopyDevice(NSString *identifier)
{
    std::lock_guard<std::mutex> lock(gRegistryMutex);
    auto it = gRegistry.find(identifier.UTF8String);
    if (it == gRegistry.end()) return nullptr;
    it->second->AddRef();
    return it->second;
}

static DLDeviceDescriptor *DLDescribe(IDeckLink *deckLink, NSString **outIdentifier)
{
    DLDeviceDescriptor *d = [DLDeviceDescriptor new];
    CFStringRef cf = NULL;
    if (deckLink->GetDisplayName(&cf) == S_OK) d.displayName = DLStringFromCF(cf); else d.displayName = @"DeckLink";
    cf = NULL;
    if (deckLink->GetModelName(&cf) == S_OK) d.modelName = DLStringFromCF(cf); else d.modelName = d.displayName;

    NSString *identifier = nil;
    IDeckLinkProfileAttributes *attributes = nullptr;
    if (deckLink->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attributes) == S_OK && attributes) {
        int64_t value = 0;
        if (attributes->GetInt(BMDDeckLinkPersistentID, &value) == S_OK) {
            identifier = [NSString stringWithFormat:@"pid-%llx", (unsigned long long)value];
        } else if (attributes->GetInt(BMDDeckLinkTopologicalID, &value) == S_OK) {
            identifier = [NSString stringWithFormat:@"tid-%llx", (unsigned long long)value];
        }
        if (attributes->GetInt(BMDDeckLinkVideoIOSupport, &value) == S_OK) {
            d.supportsCapture = (value & bmdDeviceSupportsCapture) != 0;
            d.supportsPlayback = (value & bmdDeviceSupportsPlayback) != 0;
        } else {
            d.supportsCapture = YES;
            IDeckLinkOutput *output = nullptr;
            if (deckLink->QueryInterface(IID_IDeckLinkOutput, (void **)&output) == S_OK && output) {
                d.supportsPlayback = YES;
                output->Release();
            }
        }
        bool flag = false;
        d.supportsFormatDetection = (attributes->GetFlag(BMDDeckLinkSupportsInputFormatDetection, &flag) == S_OK) && flag;
        if (attributes->GetInt(BMDDeckLinkMaximumAudioChannels, &value) == S_OK) d.maxAudioChannels = (NSInteger)value;
        attributes->Release();
    }
    if (identifier == nil) {
        identifier = [NSString stringWithFormat:@"ptr-%p", deckLink];
    }
    d.identifier = identifier;
    if (outIdentifier) *outIdentifier = identifier;
    return d;
}

#pragma mark - Discovery callback (C++)

@class DLDeviceBrowser;
@interface DLDeviceBrowser ()
- (void)_deviceArrived:(DLDeviceDescriptor *)descriptor;
- (void)_deviceRemoved:(NSString *)identifier;
@end

class DLDiscoveryCallback final : public IDeckLinkDeviceNotificationCallback
{
public:
    explicit DLDiscoveryCallback(DLDeviceBrowser *browser) : mBrowser(browser), mRefCount(1) {}

    HRESULT DeckLinkDeviceArrived(IDeckLink *deckLink) override
    {
        NSString *identifier = nil;
        DLDeviceDescriptor *descriptor = DLDescribe(deckLink, &identifier);
        {
            std::lock_guard<std::mutex> lock(gRegistryMutex);
            auto key = std::string(identifier.UTF8String);
            auto it = gRegistry.find(key);
            if (it != gRegistry.end()) it->second->Release();
            deckLink->AddRef();
            gRegistry[key] = deckLink;
        }
        DLDeviceBrowser *browser = mBrowser;
        dispatch_async(dispatch_get_main_queue(), ^{ [browser _deviceArrived:descriptor]; });
        return S_OK;
    }

    HRESULT DeckLinkDeviceRemoved(IDeckLink *deckLink) override
    {
        NSString *identifier = nil;
        {
            std::lock_guard<std::mutex> lock(gRegistryMutex);
            for (auto it = gRegistry.begin(); it != gRegistry.end(); ++it) {
                if (it->second == deckLink) {
                    identifier = [NSString stringWithUTF8String:it->first.c_str()];
                    it->second->Release();
                    gRegistry.erase(it);
                    break;
                }
            }
        }
        if (identifier) {
            DLDeviceBrowser *browser = mBrowser;
            dispatch_async(dispatch_get_main_queue(), ^{ [browser _deviceRemoved:identifier]; });
        }
        return S_OK;
    }

    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override
    {
        *ppv = nullptr;
        CFUUIDBytes unknown = CFUUIDGetUUIDBytes(IUnknownUUID);
        if (DLGuidEqual(iid, unknown) || DLGuidEqual(iid, IID_IDeckLinkDeviceNotificationCallback)) {
            *ppv = static_cast<IDeckLinkDeviceNotificationCallback *>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++mRefCount; }
    ULONG Release() override
    {
        ULONG r = --mRefCount;
        if (r == 0) delete this;
        return r;
    }

private:
    __weak DLDeviceBrowser *mBrowser;
    std::atomic<ULONG> mRefCount;
};

#endif // DL_HAS_SDK

#pragma mark - DLDeviceBrowser

@implementation DLDeviceBrowser {
    NSMutableArray<DLDeviceDescriptor *> *_devices;
#if DL_HAS_SDK
    IDeckLinkDiscovery *_discovery;
    DLDiscoveryCallback *_callback;
#endif
}

+ (BOOL)isSDKCompiledIn { return DL_HAS_SDK ? YES : NO; }

+ (BOOL)isDriverInstalled
{
#if DL_HAS_SDK
    IDeckLinkAPIInformation *info = CreateDeckLinkAPIInformationInstance();
    if (info) { info->Release(); return YES; }
#endif
    return NO;
}

+ (NSString *)driverVersion
{
#if DL_HAS_SDK
    IDeckLinkAPIInformation *info = CreateDeckLinkAPIInformationInstance();
    if (!info) return nil;
    CFStringRef cf = NULL;
    NSString *result = nil;
    if (info->GetString(BMDDeckLinkAPIVersion, &cf) == S_OK) result = DLStringFromCF(cf);
    info->Release();
    return result;
#else
    return nil;
#endif
}

+ (NSString *)compiledSDKVersion
{
#if DL_HAS_SDK
    return @BLACKMAGIC_DECKLINK_API_VERSION_STRING;
#else
    return nil;
#endif
}

- (instancetype)init
{
    if ((self = [super init])) {
        _devices = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc { [self stop]; }

- (NSArray<DLDeviceDescriptor *> *)devices { return [_devices copy]; }

- (void)start
{
#if DL_HAS_SDK
    if (_discovery) return;
    _discovery = CreateDeckLinkDiscoveryInstance();
    if (!_discovery) {
        // Driver (Desktop Video) not installed – report an empty list.
        [self.delegate deviceBrowser:self didUpdateDevices:@[]];
        return;
    }
    _callback = new DLDiscoveryCallback(self);
    if (_discovery->InstallDeviceNotifications(_callback) != S_OK) {
        _callback->Release();
        _callback = nullptr;
        _discovery->Release();
        _discovery = nullptr;
    }
#else
    [self.delegate deviceBrowser:self didUpdateDevices:@[]];
#endif
}

- (void)stop
{
#if DL_HAS_SDK
    if (_discovery) {
        _discovery->UninstallDeviceNotifications();
        _discovery->Release();
        _discovery = nullptr;
    }
    if (_callback) {
        _callback->Release();
        _callback = nullptr;
    }
#endif
}

- (void)_deviceArrived:(DLDeviceDescriptor *)descriptor
{
    [_devices removeObject:descriptor];
    [_devices addObject:descriptor];
    [_devices sortUsingComparator:^NSComparisonResult(DLDeviceDescriptor *a, DLDeviceDescriptor *b) {
        return [a.identifier compare:b.identifier];
    }];
    [self.delegate deviceBrowser:self didUpdateDevices:self.devices];
}

- (void)_deviceRemoved:(NSString *)identifier
{
    NSIndexSet *idx = [_devices indexesOfObjectsPassingTest:^BOOL(DLDeviceDescriptor *d, NSUInteger i, BOOL *stop) {
        return [d.identifier isEqualToString:identifier];
    }];
    [_devices removeObjectsAtIndexes:idx];
    [self.delegate deviceBrowser:self didUpdateDevices:self.devices];
}

@end

#pragma mark - Capture engine (C++)

@interface DLCaptureDevice ()
- (void)_deliverFrame:(DLCaptureFrame *)frame;
- (void)_formatChanged:(DLFormatInfo *)format;
- (void)_fail:(NSString *)message;
@end

#if DL_HAS_SDK

static const BMDTimeScale kHostScale = 1000000000LL; // ns

class DLCaptureEngine final : public DLInputCallbackInterface
{
public:
    DLCaptureEngine(DLCaptureDevice *owner, IDeckLink *deckLink)
        : mOwner(owner), mDeckLink(deckLink), mRefCount(1)
    {
        mDeckLink->AddRef();
    }

    bool Start(int32_t audioChannels, bool forceEightBit, bool forceSDI, NSError **error)
    {
        mAudioChannels = audioChannels;
        mForceEightBit = forceEightBit;

        if (mDeckLink->QueryInterface(DL_IID_INPUT, (void **)&mInput) != S_OK || !mInput) {
            if (error) *error = DLMakeError(1, @"The device does not support input (IDeckLinkInput).");
            return false;
        }

        if (forceSDI) {
            IDeckLinkConfiguration *config = nullptr;
            if (mDeckLink->QueryInterface(IID_IDeckLinkConfiguration, (void **)&config) == S_OK && config) {
                config->SetInt(bmdDeckLinkConfigVideoInputConnection, bmdVideoConnectionSDI);
                config->Release();
            }
        }

        bool detection = false;
        IDeckLinkProfileAttributes *attributes = nullptr;
        if (mDeckLink->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attributes) == S_OK && attributes) {
            bool flag = false;
            detection = (attributes->GetFlag(BMDDeckLinkSupportsInputFormatDetection, &flag) == S_OK) && flag;
            attributes->Release();
        }

        // Start with 1080p25 and let format detection switch to whatever the camera sends.
        BMDDisplayMode mode = bmdModeHD1080p25;
        BMDPixelFormat pf = mForceEightBit ? bmdFormat8BitYUV : bmdFormat10BitYUV;
        BMDVideoInputFlags flags = detection ? bmdVideoInputEnableFormatDetection : bmdVideoInputFlagDefault;

        HRESULT hr = mInput->EnableVideoInput(mode, pf, flags);
        if (hr != S_OK && pf != bmdFormat8BitYUV) {
            pf = bmdFormat8BitYUV;
            hr = mInput->EnableVideoInput(mode, pf, flags);
        }
        if (hr != S_OK) {
            if (error) *error = DLMakeError(2, @"EnableVideoInput failed (the device may be in use by another application).");
            Teardown();
            return false;
        }
        mPixelFormat = pf;

        IDeckLinkDisplayMode *displayMode = nullptr;
        if (mInput->GetDisplayMode(mode, &displayMode) == S_OK && displayMode) {
            ApplyDisplayMode(displayMode, 0);
            displayMode->Release();
        }

        if (mAudioChannels > 0) {
            if (mInput->EnableAudioInput(bmdAudioSampleRate48kHz, bmdAudioSampleType32bitInteger, (uint32_t)mAudioChannels) != S_OK) {
                mAudioChannels = 0; // continue without audio
            }
        }

        mInput->SetCallback(this);
        if (mInput->StartStreams() != S_OK) {
            if (error) *error = DLMakeError(3, @"StartStreams failed.");
            Teardown();
            return false;
        }
        return true;
    }

    void Stop() { Teardown(); }

    // MARK: IDeckLinkInputCallback

    HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents events,
                                    IDeckLinkDisplayMode *newMode,
                                    BMDDetectedVideoInputFormatFlags detected) override
    {
        if (!mInput || !newMode) return S_OK;

        BMDPixelFormat next = mPixelFormat;
        const BMDDetectedVideoInputFormatFlags highBit = bmdDetectedVideoInput10BitDepth | bmdDetectedVideoInput12BitDepth;
        if (detected & bmdDetectedVideoInputRGB444) {
            next = bmdFormat8BitBGRA;
        } else if (detected & bmdDetectedVideoInputYCbCr422) {
            next = ((detected & highBit) && !mForceEightBit) ? bmdFormat10BitYUV : bmdFormat8BitYUV;
        }

        int32_t depth = 0;
        if (detected & bmdDetectedVideoInput12BitDepth) depth = 12;
        else if (detected & bmdDetectedVideoInput10BitDepth) depth = 10;
        else if (detected & bmdDetectedVideoInput8BitDepth) depth = 8;

        if (next != mPixelFormat || (events & bmdVideoInputDisplayModeChanged)) {
            mInput->PauseStreams();
            HRESULT hr = mInput->EnableVideoInput(newMode->GetDisplayMode(), next, bmdVideoInputEnableFormatDetection);
            if (hr != S_OK && next == bmdFormat10BitYUV) {
                next = bmdFormat8BitYUV;
                hr = mInput->EnableVideoInput(newMode->GetDisplayMode(), next, bmdVideoInputEnableFormatDetection);
            }
            if (hr != S_OK) {
                DLCaptureDevice *owner = mOwner;
                dispatch_async(dispatch_get_main_queue(), ^{ [owner _fail:@"Could not switch to the detected format."]; });
                return S_OK;
            }
            mPixelFormat = next;
            mInput->FlushStreams();
            mInput->StartStreams();
        }
        ApplyDisplayMode(newMode, depth, (detected & bmdDetectedVideoInputRGB444) != 0);
        return S_OK;
    }

    HRESULT VideoInputFrameArrived(DLVideoInputFrame *videoFrame, IDeckLinkAudioInputPacket *audioPacket) override
    {
        if (!videoFrame) return S_OK; // audio-only callbacks are ignored (audio always arrives with video for SDI)

        @autoreleasepool {
            // 1) Host-clock conversion of the hardware reference timestamp.
            BMDTimeValue hwFrameTime = 0, hwFrameDuration = 0;
            const bool haveHW = videoFrame->GetHardwareReferenceTimestamp(kHostScale, &hwFrameTime, &hwFrameDuration) == S_OK;
            UpdateClockOffset();
            uint64_t hostTime = DLHostTimeNanos();
            if (haveHW && mOffsetValid) {
                hostTime = (uint64_t)((double)hwFrameTime + mClockOffset);
            }

            // 2) Stream time + drop detection.
            int64_t timeScale = mTimeScale.load();
            BMDTimeValue streamTime = 0, frameDuration = 0;
            videoFrame->GetStreamTime(&streamTime, &frameDuration, timeScale);
            uint32_t dropped = 0;
            if (mHaveLast && frameDuration > 0) {
                int64_t delta = streamTime - mLastStreamTime;
                if (delta > frameDuration + frameDuration / 2) {
                    dropped = (uint32_t)llround((double)delta / (double)frameDuration) - 1;
                }
            }
            mLastStreamTime = streamTime;
            mHaveLast = true;

            // 3) Copy pixels into an IOSurface-backed pool buffer.
            CVPixelBufferRef pb = CopyFrame(videoFrame);
            if (!pb) return S_OK;

            DLCaptureFrame *frame = [[DLCaptureFrame alloc] initWithPixelBuffer:pb];
            CVPixelBufferRelease(pb);
            frame.streamTime = streamTime;
            frame.frameDuration = frameDuration;
            frame.timeScale = timeScale;
            frame.hostTimeNanos = hostTime;
            frame.hasSignal = (videoFrame->GetFlags() & bmdFrameHasNoInputSource) == 0;
            frame.droppedBefore = dropped;

            // 4) Timecode from the camera (RP188 ATC / LTC, else VITC) and its record trigger.
            IDeckLinkTimecode *tc = nullptr;
            if ((videoFrame->GetTimecode(bmdTimecodeRP188Any, &tc) == S_OK && tc) ||
                (videoFrame->GetTimecode(bmdTimecodeVITC, &tc) == S_OK && tc)) {
                uint8_t h = 0, m = 0, sec = 0, f = 0;
                if (tc->GetComponents(&h, &m, &sec, &f) == S_OK) {
                    frame.hasTimecode = YES;
                    frame.tcHours = h; frame.tcMinutes = m; frame.tcSeconds = sec; frame.tcFrames = f;
                    BMDTimecodeFlags flags = tc->GetFlags();
                    frame.tcDropFrame = (flags & bmdTimecodeIsDropFrame) != 0;
                    if (flags & bmdTimecodeEmbedRecordingTrigger) {
                        frame.recordTrigger = (flags & bmdTimecodeRecordingTriggered) ? 1 : 0;
                    }
                    BMDTimecodeUserBits bits = 0;
                    if (tc->GetTimecodeUserBits(&bits) == S_OK) frame.tcUserBits = bits;
                }
                tc->Release();
            }

            // 5) Ancillary packets: the Blackmagic tally packet is looked for in every frame; all packets are
            //    copied only for the SDI data log.
            {
                const BOOL capture = mOwner.captureAncillary;
                NSMutableArray<DLAncillaryPacket *> *packets = capture ? [NSMutableArray array] : nil;
                IDeckLinkVideoFrameAncillaryPackets *anc = nullptr;
                if (videoFrame->QueryInterface(IID_IDeckLinkVideoFrameAncillaryPackets, (void **)&anc) == S_OK && anc) {
                    IDeckLinkAncillaryPacketIterator *it = nullptr;
                    if (anc->GetPacketIterator(&it) == S_OK && it) {
                        IDeckLinkAncillaryPacket *packet = nullptr;
                        while (it->Next(&packet) == S_OK && packet) {
                            if (packet->GetDID() == 0x51 && packet->GetSDID() == 0x52) frame.blackmagicTally = YES;
                            if (capture) {
                                const void *bytes = nullptr;
                                uint32_t size = 0;
                                DLAncillaryPacket *p = [DLAncillaryPacket new];
                                p.did = packet->GetDID();
                                p.sdid = packet->GetSDID();
                                p.lineNumber = packet->GetLineNumber();
                                p.dataStreamIndex = packet->GetDataStreamIndex();
                                p.data = (packet->GetBytes(bmdAncillaryPacketFormatUInt8, &bytes, &size) == S_OK && bytes)
                                    ? [NSData dataWithBytes:bytes length:size] : [NSData data];
                                [packets addObject:p];
                            }
                            packet->Release();
                            packet = nullptr;
                        }
                        it->Release();
                    }
                    anc->Release();
                }
                frame.ancillaryPackets = packets;
            }

            // 6) Embedded audio.
            if (audioPacket && mAudioChannels > 0) {
                long sampleFrames = audioPacket->GetSampleFrameCount();
                void *bytes = nullptr;
                if (sampleFrames > 0 && audioPacket->GetBytes(&bytes) == S_OK && bytes) {
                    BMDTimeValue packetTime = 0;
                    audioPacket->GetPacketTime(&packetTime, bmdAudioSampleRate48kHz);
                    frame.audioData = [NSData dataWithBytes:bytes length:(NSUInteger)sampleFrames * (NSUInteger)mAudioChannels * sizeof(int32_t)];
                    frame.audioSampleFrames = (int32_t)sampleFrames;
                    frame.audioChannels = mAudioChannels;
                    frame.audioPacketTime = packetTime;
                }
            }

            [mOwner _deliverFrame:frame];
        }
        return S_OK;
    }

    // MARK: IUnknown

    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override
    {
        *ppv = nullptr;
        CFUUIDBytes unknown = CFUUIDGetUUIDBytes(IUnknownUUID);
        if (DLGuidEqual(iid, unknown) || DLGuidEqual(iid, DL_IID_INPUT_CALLBACK)) {
            *ppv = static_cast<DLInputCallbackInterface *>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++mRefCount; }
    ULONG Release() override
    {
        ULONG r = --mRefCount;
        if (r == 0) delete this;
        return r;
    }

private:
    ~DLCaptureEngine()
    {
        Teardown();
        if (mPool) CVPixelBufferPoolRelease(mPool);
        if (mDeckLink) mDeckLink->Release();
    }

    void Teardown()
    {
        if (mInput) {
            mInput->StopStreams();
            mInput->SetCallback(nullptr);
            if (mAudioChannels > 0) mInput->DisableAudioInput();
            mInput->DisableVideoInput();
            mInput->Release();
            mInput = nullptr;
        }
    }

    /// Estimates (host clock − hardware clock) by sampling both clocks back to back.
    void UpdateClockOffset()
    {
        if (!mInput) return;
        BMDTimeValue hwNow = 0, inFrame = 0, ticksPerFrame = 0;
        uint64_t before = DLHostTimeNanos();
        HRESULT hr = mInput->GetHardwareReferenceClock(kHostScale, &hwNow, &inFrame, &ticksPerFrame);
        uint64_t after = DLHostTimeNanos();
        if (hr != S_OK) return;
        uint64_t span = after - before;
        if (span > 2000000ULL) return; // >2 ms – preempted, ignore sample
        double sample = (double)(before + span / 2) - (double)hwNow;
        if (!mOffsetValid) {
            mClockOffset = sample;
            mOffsetValid = true;
        } else {
            mClockOffset += 0.05 * (sample - mClockOffset); // slow low-pass, rejects jitter, follows drift
        }
    }

    void ApplyDisplayMode(IDeckLinkDisplayMode *mode, int32_t depth, bool rgb = false)
    {
        BMDTimeValue duration = 0;
        BMDTimeScale scale = 0;
        mode->GetFrameRate(&duration, &scale);
        if (scale > 0) mTimeScale = scale;
        mHaveLast = false;

        DLFormatInfo *info = [DLFormatInfo new];
        CFStringRef cfName = NULL;
        info.modeName = (mode->GetName(&cfName) == S_OK) ? DLStringFromCF(cfName) : @"?";
        info.width = (int32_t)mode->GetWidth();
        info.height = (int32_t)mode->GetHeight();
        info.frameDuration = duration;
        info.timeScale = scale;
        BMDFieldDominance fd = mode->GetFieldDominance();
        info.interlaced = (fd == bmdLowerFieldFirst || fd == bmdUpperFieldFirst);
        mUpperFieldFirst = (fd == bmdUpperFieldFirst);
        mInterlaced = info.interlaced;
        info.rgb444 = rgb;
        info.bitDepth = depth;
        info.pixelFormat = DLCVPixelFormat(mPixelFormat);

        DLCaptureDevice *owner = mOwner;
        dispatch_async(dispatch_get_main_queue(), ^{ [owner _formatChanged:info]; });
    }

    CVPixelBufferRef CopyFrame(DLVideoInputFrame *videoFrame)
    {
        const long width = videoFrame->GetWidth();
        const long height = videoFrame->GetHeight();
        const long srcRowBytes = videoFrame->GetRowBytes();
        const OSType cvFormat = DLCVPixelFormat(videoFrame->GetPixelFormat());
        if (cvFormat == 0 || width <= 0 || height <= 0) return nullptr;

        if (!mPool || mPoolWidth != width || mPoolHeight != height || mPoolFormat != cvFormat) {
            if (mPool) CVPixelBufferPoolRelease(mPool);
            mPool = nullptr;
            NSDictionary *poolAttrs = @{ (id)kCVPixelBufferPoolMinimumBufferCountKey: @12 };
            NSDictionary *pbAttrs = @{
                (id)kCVPixelBufferWidthKey: @(width),
                (id)kCVPixelBufferHeightKey: @(height),
                (id)kCVPixelBufferPixelFormatTypeKey: @(cvFormat),
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            };
            if (CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttrs,
                                        (__bridge CFDictionaryRef)pbAttrs, &mPool) != kCVReturnSuccess) {
                mPool = nullptr;
                return nullptr;
            }
            mPoolWidth = width;
            mPoolHeight = height;
            mPoolFormat = cvFormat;
        }

        CVPixelBufferRef pb = nullptr;
        if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, mPool, &pb) != kCVReturnSuccess || !pb) return nullptr;

        void *src = nullptr;
        if (videoFrame->GetBytes(&src) != S_OK || !src) {
            CVPixelBufferRelease(pb);
            return nullptr;
        }

        CVPixelBufferLockBaseAddress(pb, 0);
        uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
        const size_t dstRowBytes = CVPixelBufferGetBytesPerRow(pb);
        const size_t copyBytes = MIN((size_t)srcRowBytes, dstRowBytes);
        const uint8_t *s = (const uint8_t *)src;
        if ((size_t)srcRowBytes == dstRowBytes) {
            memcpy(dst, s, dstRowBytes * (size_t)height);
        } else {
            for (long y = 0; y < height; y++) {
                memcpy(dst + (size_t)y * dstRowBytes, s + (size_t)y * (size_t)srcRowBytes, copyBytes);
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, 0);

        // HD SDI = Rec.709
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        if (mInterlaced) {
            CVBufferSetAttachment(pb, kCVImageBufferFieldCountKey, (__bridge CFTypeRef)@2, kCVAttachmentMode_ShouldPropagate);
            CVBufferSetAttachment(pb, kCVImageBufferFieldDetailKey,
                                  mUpperFieldFirst ? kCVImageBufferFieldDetailTemporalTopFirst : kCVImageBufferFieldDetailTemporalBottomFirst,
                                  kCVAttachmentMode_ShouldPropagate);
        }
        return pb;
    }

    __weak DLCaptureDevice *mOwner;
    IDeckLink *mDeckLink = nullptr;
    DLInputInterface *mInput = nullptr;
    std::atomic<ULONG> mRefCount;

    int32_t mAudioChannels = 0;
    bool mForceEightBit = false;
    BMDPixelFormat mPixelFormat = bmdFormat10BitYUV;
    std::atomic<int64_t> mTimeScale { 25 };
    bool mInterlaced = false;
    bool mUpperFieldFirst = true;

    // drop detection
    int64_t mLastStreamTime = 0;
    bool mHaveLast = false;

    // hw → host clock
    double mClockOffset = 0;
    bool mOffsetValid = false;

    CVPixelBufferPoolRef mPool = nullptr;
    long mPoolWidth = 0, mPoolHeight = 0;
    OSType mPoolFormat = 0;
};

#endif // DL_HAS_SDK

#pragma mark - DLCaptureDevice

@implementation DLCaptureDevice {
#if DL_HAS_SDK
    IDeckLink *_deckLink;
    DLCaptureEngine *_engine;
#endif
    DLFormatInfo *_currentFormat;
}

- (nullable instancetype)initWithIdentifier:(NSString *)identifier
{
#if DL_HAS_SDK
    IDeckLink *deckLink = DLCopyDevice(identifier);
    if (!deckLink) return nil;
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _deckLink = deckLink;
        _audioChannels = 2;
        _forceSDIInput = YES;
    } else {
        deckLink->Release();
    }
    return self;
#else
    return nil;
#endif
}

- (void)dealloc
{
    [self stop];
#if DL_HAS_SDK
    if (_deckLink) _deckLink->Release();
#endif
}

- (DLFormatInfo *)currentFormat { return _currentFormat; }

- (BOOL)isRunning
{
#if DL_HAS_SDK
    return _engine != nullptr;
#else
    return NO;
#endif
}

- (BOOL)startAndReturnError:(NSError **)error
{
#if DL_HAS_SDK
    if (_engine) return YES;
    DLCaptureEngine *engine = new DLCaptureEngine(self, _deckLink);
    if (!engine->Start(_audioChannels, _forceEightBit, _forceSDIInput, error)) {
        engine->Release();
        return NO;
    }
    _engine = engine;
    return YES;
#else
    if (error) *error = DLMakeError(100, @"The app was built without the DeckLink SDK.");
    return NO;
#endif
}

- (void)stop
{
#if DL_HAS_SDK
    if (_engine) {
        _engine->Stop();     // StopStreams + SetCallback(NULL): no callbacks after this returns
        _engine->Release();
        _engine = nullptr;
    }
#endif
}

- (void)_deliverFrame:(DLCaptureFrame *)frame
{
    [self.delegate captureDevice:self didCaptureFrame:frame];
}

- (void)_formatChanged:(DLFormatInfo *)format
{
    _currentFormat = format;
    [self.delegate captureDevice:self didDetectFormat:format];
}

- (void)_fail:(NSString *)message
{
    [self.delegate captureDevice:self didFailWithMessage:message];
}

@end

#pragma mark - DLOutputDevice

@implementation DLOutputDevice {
#if DL_HAS_SDK
    IDeckLink *_deckLink;
    IDeckLinkOutput *_output;
    std::vector<IDeckLinkMutableVideoFrame *> _frames;   // small ring – a frame is not rewritten while it may still be sent
    size_t _nextFrame;
    int32_t _width, _height, _rowBytes;
#endif
    NSString *_modeName;
}

- (nullable instancetype)initWithIdentifier:(NSString *)identifier
{
#if DL_HAS_SDK
    IDeckLink *deckLink = DLCopyDevice(identifier);
    if (!deckLink) return nil;
    IDeckLinkOutput *output = nullptr;
    if (deckLink->QueryInterface(IID_IDeckLinkOutput, (void **)&output) != S_OK || !output) {
        deckLink->Release();
        return nil;
    }
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _deckLink = deckLink;
        _output = output;
    } else {
        output->Release();
        deckLink->Release();
    }
    return self;
#else
    return nil;
#endif
}

- (void)dealloc
{
    [self stop];
#if DL_HAS_SDK
    if (_output) _output->Release();
    if (_deckLink) _deckLink->Release();
#endif
}

- (nullable NSString *)modeName { return _modeName; }

- (BOOL)startWithWidth:(int32_t)width height:(int32_t)height frameDuration:(int64_t)frameDuration
             timeScale:(int64_t)timeScale interlaced:(BOOL)interlaced error:(NSError **)error
{
#if DL_HAS_SDK
    [self stop];
    BMDDisplayMode chosen = bmdModeUnknown;
    NSString *name = nil;
    IDeckLinkDisplayModeIterator *iterator = nullptr;
    if (_output->GetDisplayModeIterator(&iterator) == S_OK && iterator) {
        IDeckLinkDisplayMode *mode = nullptr;
        while (chosen == bmdModeUnknown && iterator->Next(&mode) == S_OK) {
            BMDTimeValue duration = 0;
            BMDTimeScale scale = 0;
            mode->GetFrameRate(&duration, &scale);
            BMDFieldDominance field = mode->GetFieldDominance();
            bool modeInterlaced = field == bmdLowerFieldFirst || field == bmdUpperFieldFirst;
            if (mode->GetWidth() == width && mode->GetHeight() == height && modeInterlaced == (bool)interlaced
                && (int64_t)duration * timeScale == frameDuration * (int64_t)scale) {
                bool supported = false;
                BMDDisplayMode actual = bmdModeUnknown;
                if (_output->DoesSupportVideoMode(bmdVideoConnectionUnspecified, mode->GetDisplayMode(), bmdFormat8BitYUV,
                                                  bmdNoVideoOutputConversion, bmdSupportedVideoModeDefault,
                                                  &actual, &supported) == S_OK && supported) {
                    chosen = mode->GetDisplayMode();
                    CFStringRef cf = NULL;
                    name = mode->GetName(&cf) == S_OK ? DLStringFromCF(cf) : nil;
                }
            }
            mode->Release();
        }
        iterator->Release();
    }
    if (chosen == bmdModeUnknown) {
        if (error) *error = DLMakeError(200, [NSString stringWithFormat:@"The output cannot send %d×%d%@ at this frame rate.",
                                              width, height, interlaced ? @"i" : @"p"]);
        return NO;
    }
    if (_output->EnableVideoOutput(chosen, bmdVideoOutputFlagDefault) != S_OK) {
        if (error) *error = DLMakeError(201, @"The output is in use by another application.");
        return NO;
    }
    int32_t rowBytes = 0;
    if (_output->RowBytesForPixelFormat(bmdFormat8BitYUV, width, &rowBytes) != S_OK) rowBytes = width * 2;
    for (int i = 0; i < 3; i++) {
        IDeckLinkMutableVideoFrame *frame = nullptr;
        if (_output->CreateVideoFrame(width, height, rowBytes, bmdFormat8BitYUV, bmdFrameFlagDefault, &frame) != S_OK || !frame) {
            [self stop];
            if (error) *error = DLMakeError(202, @"Could not create output frames.");
            return NO;
        }
        _frames.push_back(frame);
    }
    _width = width;
    _height = height;
    _rowBytes = rowBytes;
    _nextFrame = 0;
    _modeName = name ?: [NSString stringWithFormat:@"%d×%d", width, height];
    return YES;
#else
    if (error) *error = DLMakeError(100, @"The app was built without the DeckLink SDK.");
    return NO;
#endif
}

- (BOOL)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
#if DL_HAS_SDK
    if (_frames.empty() || CVPixelBufferGetPixelFormatType(pixelBuffer) != kCVPixelFormatType_422YpCbCr8
        || (int32_t)CVPixelBufferGetWidth(pixelBuffer) != _width || (int32_t)CVPixelBufferGetHeight(pixelBuffer) != _height) {
        return NO;
    }
    IDeckLinkMutableVideoFrame *frame = _frames[_nextFrame];
    _nextFrame = (_nextFrame + 1) % _frames.size();

    void *bytes = nullptr;
#if BLACKMAGIC_DECKLINK_API_VERSION >= 0x0e030000
    IDeckLinkVideoBuffer *buffer = nullptr;
    if (frame->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&buffer) != S_OK || !buffer) return NO;
    if (buffer->StartAccess(bmdBufferAccessWrite) != S_OK) { buffer->Release(); return NO; }
    buffer->GetBytes(&bytes);
#else
    frame->GetBytes(&bytes);
#endif
    if (bytes) {
        CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);
        size_t copyBytes = MIN(srcRowBytes, (size_t)_rowBytes);
        for (int32_t y = 0; y < _height; y++) {
            memcpy((uint8_t *)bytes + (size_t)y * _rowBytes, src + (size_t)y * srcRowBytes, copyBytes);
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    }
#if BLACKMAGIC_DECKLINK_API_VERSION >= 0x0e030000
    buffer->EndAccess(bmdBufferAccessWrite);
    buffer->Release();
#endif
    return bytes != nullptr && _output->DisplayVideoFrameSync(frame) == S_OK;
#else
    return NO;
#endif
}

- (void)stop
{
#if DL_HAS_SDK
    if (!_frames.empty() || _modeName) {
        _output->DisableVideoOutput();
    }
    for (IDeckLinkMutableVideoFrame *frame : _frames) frame->Release();
    _frames.clear();
#endif
    _modeName = nil;
}

@end
