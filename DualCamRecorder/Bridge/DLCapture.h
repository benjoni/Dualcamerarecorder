//
//  DLCapture.h
//  DualCamRecorder
//
//  Thin Objective-C interface over the Blackmagic DeckLink SDK (implemented in DLCapture.mm).
//  This header must stay free of C++ so it can be imported from Swift via the bridging header.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Host clock used for all cross-device timestamps (nanoseconds, CLOCK_UPTIME_RAW == mach_absolute_time in ns).
FOUNDATION_EXPORT uint64_t DLHostTimeNanos(void);

#pragma mark - Device discovery

@interface DLDeviceDescriptor : NSObject
/// Stable identifier (BMDDeckLinkPersistentID / TopologicalID when available, display name otherwise).
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, copy) NSString *modelName;
@property (nonatomic, readonly) BOOL supportsCapture;
/// Has a video output (UltraStudio Monitor 3G, HD Mini …) – usable for a monitor.
@property (nonatomic, readonly) BOOL supportsPlayback;
@property (nonatomic, readonly) BOOL supportsFormatDetection;
@property (nonatomic, readonly) NSInteger maxAudioChannels;
@end

@class DLDeviceBrowser;

@protocol DLDeviceBrowserDelegate <NSObject>
/// Always called on the main queue.
- (void)deviceBrowser:(DLDeviceBrowser *)browser didUpdateDevices:(NSArray<DLDeviceDescriptor *> *)devices
    NS_SWIFT_NAME(deviceBrowser(_:didUpdateDevices:));
@end

@interface DLDeviceBrowser : NSObject
/// YES when the app was compiled against the DeckLink SDK headers.
@property (class, nonatomic, readonly) BOOL isSDKCompiledIn;
/// YES when /Library/Frameworks/DeckLinkAPI.framework (Desktop Video driver) could be loaded.
@property (class, nonatomic, readonly) BOOL isDriverInstalled;
/// Driver/API version string ("12.x" etc.), nil when unavailable.
@property (class, nonatomic, readonly, nullable) NSString *driverVersion;
/// SDK header version the app was compiled with, nil when not compiled in.
@property (class, nonatomic, readonly, nullable) NSString *compiledSDKVersion;

@property (nonatomic, weak, nullable) id<DLDeviceBrowserDelegate> delegate;
@property (nonatomic, readonly, copy) NSArray<DLDeviceDescriptor *> *devices;

- (void)start;
- (void)stop;
@end

#pragma mark - Capture

/// Information about the detected / active input signal.
@interface DLFormatInfo : NSObject
@property (nonatomic, readonly, copy) NSString *modeName;     // e.g. "1080p25"
@property (nonatomic, readonly) int32_t width;
@property (nonatomic, readonly) int32_t height;
@property (nonatomic, readonly) int64_t frameDuration;        // in timeScale units
@property (nonatomic, readonly) int64_t timeScale;
@property (nonatomic, readonly) BOOL interlaced;
@property (nonatomic, readonly) BOOL rgb444;
@property (nonatomic, readonly) int32_t bitDepth;             // 8 / 10 / 12 (detected, 0 = unknown)
@property (nonatomic, readonly) OSType pixelFormat;           // CoreVideo pixel format of delivered buffers
@end

@class DLAncillaryPacket;

/// One captured frame. Pixel data is already copied out of DeckLink memory.
@interface DLCaptureFrame : NSObject
@property (nonatomic, readonly) CVPixelBufferRef pixelBuffer;
/// Stream time (same timeline as audio packet time).
@property (nonatomic, readonly) int64_t streamTime;
@property (nonatomic, readonly) int64_t frameDuration;
@property (nonatomic, readonly) int64_t timeScale;
/// Hardware reference timestamp of the frame converted to the host clock (ns). Comparable between devices.
@property (nonatomic, readonly) uint64_t hostTimeNanos;
@property (nonatomic, readonly) BOOL hasSignal;
/// Frames lost by the input since the previous delivered frame (stream-time gap).
@property (nonatomic, readonly) uint32_t droppedBefore;

/// Interleaved signed 32-bit integer PCM, 48 kHz. nil if audio is disabled / not delivered.
@property (nonatomic, readonly, nullable) NSData *audioData;
@property (nonatomic, readonly) int32_t audioSampleFrames;
@property (nonatomic, readonly) int32_t audioChannels;
/// Audio packet time in 48 kHz units (same stream timeline as streamTime).
@property (nonatomic, readonly) int64_t audioPacketTime;

/// Timecode embedded by the camera (RP188 any, else VITC). hasTimecode = NO when the signal has none.
@property (nonatomic, readonly) BOOL hasTimecode;
@property (nonatomic, readonly) uint8_t tcHours;
@property (nonatomic, readonly) uint8_t tcMinutes;
@property (nonatomic, readonly) uint8_t tcSeconds;
@property (nonatomic, readonly) uint8_t tcFrames;
@property (nonatomic, readonly) BOOL tcDropFrame;
@property (nonatomic, readonly) uint32_t tcUserBits;
/// Camera record trigger carried in the timecode: -1 = not sent, 0 = stopped, 1 = recording.
@property (nonatomic, readonly) int8_t recordTrigger;
/// All ancillary packets of the frame – only when DLCaptureDevice.captureAncillary is on, else nil.
@property (nonatomic, readonly, nullable) NSArray<DLAncillaryPacket *> *ancillaryPackets;
@end

/// One ancillary (VANC) data packet of a frame, 8-bit user data words.
@interface DLAncillaryPacket : NSObject
@property (nonatomic, readonly) uint8_t did;
@property (nonatomic, readonly) uint8_t sdid;
@property (nonatomic, readonly) uint32_t lineNumber;
@property (nonatomic, readonly) uint8_t dataStreamIndex;
@property (nonatomic, readonly, copy) NSData *data;
@end

@class DLCaptureDevice;

@protocol DLCaptureDeviceDelegate <NSObject>
/// Called on the DeckLink capture thread. Must return quickly.
- (void)captureDevice:(DLCaptureDevice *)device didCaptureFrame:(DLCaptureFrame *)frame
    NS_SWIFT_NAME(captureDevice(_:didCaptureFrame:));
/// Called on the main queue.
- (void)captureDevice:(DLCaptureDevice *)device didDetectFormat:(DLFormatInfo *)format
    NS_SWIFT_NAME(captureDevice(_:didDetectFormat:));
/// Called on the main queue.
- (void)captureDevice:(DLCaptureDevice *)device didFailWithMessage:(NSString *)message
    NS_SWIFT_NAME(captureDevice(_:didFailWithMessage:));
@end

@interface DLCaptureDevice : NSObject

/// nil if no device with this identifier is currently present.
- (nullable instancetype)initWithIdentifier:(NSString *)identifier NS_SWIFT_NAME(init(identifier:));
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<DLCaptureDeviceDelegate> delegate;
@property (nonatomic, readonly, copy) NSString *identifier;

/// 0 disables audio, otherwise 2, 8 or 16 embedded SDI channels. Set before -start.
@property (nonatomic) int32_t audioChannels;
/// Capture 8-bit 4:2:2 even if the source is 10-bit. Set before -start.
@property (nonatomic) BOOL forceEightBit;
/// Force the SDI connector as the video input (UltraStudio Recorder 3G also has HDMI). Default YES.
@property (nonatomic) BOOL forceSDIInput;
/// Deliver every frame's ancillary packets (SDI data log). Can be changed while running.
@property (atomic) BOOL captureAncillary;

@property (nonatomic, readonly, nullable) DLFormatInfo *currentFormat;
@property (nonatomic, readonly) BOOL isRunning;

- (BOOL)startAndReturnError:(NSError **)error NS_SWIFT_NAME(start());
- (void)stop;
@end

#pragma mark - Output (monitor)

/// Video output of a DeckLink device (feeds a Blackmagic monitor). Frames are shown as they come (no scheduling).
@interface DLOutputDevice : NSObject

/// nil if no device with this identifier is present or it has no video output.
- (nullable instancetype)initWithIdentifier:(NSString *)identifier NS_SWIFT_NAME(init(identifier:));
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *identifier;
/// Running output mode ("1080p25"), nil when stopped.
@property (nonatomic, readonly, copy, nullable) NSString *modeName;

/// Enables the output in the mode with this size and frame rate (8-bit YUV 4:2:2).
- (BOOL)startWithWidth:(int32_t)width height:(int32_t)height frameDuration:(int64_t)frameDuration
             timeScale:(int64_t)timeScale interlaced:(BOOL)interlaced error:(NSError **)error
    NS_SWIFT_NAME(start(width:height:frameDuration:timeScale:interlaced:));
/// Shows a '2vuy' buffer of the running mode's size as the next frame. Calls must not overlap.
- (BOOL)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer NS_SWIFT_NAME(display(_:));
- (void)stop;
@end

NS_ASSUME_NONNULL_END
