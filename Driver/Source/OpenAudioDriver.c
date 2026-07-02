/*
 * OpenAudioDriver.c
 *
 * OpenAudio 16-channel loopback virtual audio device(s).
 *
 * A minimal but complete AudioServerPlugIn (Core Audio HAL plugin) that
 * publishes between 1 and kOpenAudioMaxDevices (8) virtual devices, each
 * presenting 16 input and 16 output channels of native-packed Float32 PCM.
 * Samples written to a device's output stream are pushed into that device's
 * lock-free ring buffer and returned on its input stream, forming a bit-exact
 * loopback bus. Each device owns an independent ring, clock anchor, streams and
 * volume/mute controls.
 *
 * The number of published devices is controlled at runtime through the custom
 * plug-in property kOpenAudioPropertyDeviceCount ('OAdc', see
 * OpenAudioControl.h). Changing it publishes/unpublishes devices, notifies the
 * host and persists the value to host storage; devices that keep running are
 * not disturbed.
 *
 * This file is an original implementation of the published
 * AudioServerPlugInDriverInterface. It follows the same COM-style plugin
 * architecture that Apple documents in its NullAudio.c sample, but shares no
 * code with that sample or with any GPL-licensed driver (e.g. BlackHole).
 *
 * Realtime discipline: the IO entry points (GetZeroTimeStamp,
 * BeginIOOperation, DoIOOperation, EndIOOperation, WillDoIOOperation) perform
 * no allocation, no locking, no syscalls and touch no Objective-C. All ring
 * memory is statically allocated (BSS) once at plugin load — never on the IO
 * path. State-change locking (a plain pthread_mutex) is used ONLY outside the
 * IO path.
 */

#include "OpenAudioControl.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>

/* ======================================================================== */
#pragma mark Compile-time configuration
/* ======================================================================== */

#define kPlugIn_BundleID                "com.openaudio.driver"

#define kDevice_Manufacturer            "OpenAudio"
#define kBox_Name                       "OpenAudio Box"
#define kBox_UID                        "OpenAudioBox-1"
#define kBox_ModelUID                   "OpenAudioBox-Model-1"

enum
{
    kNumberOfChannels           = 16,
    kBitsPerChannel             = 32,
    kBytesPerSample             = 4,
    kBytesPerFrame              = kBytesPerSample * kNumberOfChannels,

    /* Ring buffer: a power of two number of frames so that indexing can use a
       cheap bit-mask instead of a modulo. 131072 frames is > 1.36 s at 96 kHz,
       comfortably above the required 1 second at 96 kHz / 16ch / Float32. */
    kRingBufferFrameSize        = 131072,
    kRingBufferFrameMask        = kRingBufferFrameSize - 1,

    /* GetZeroTimeStamp advances the anchor sample time by this many frames each
       cycle. Fixed, monotonic. (F-D5) */
    kZeroTimestampPeriod        = 16384
};

/* Number of bytes in one device ring buffer. */
#define kRingBufferBytes ((size_t)kRingBufferFrameSize * kNumberOfChannels * sizeof(Float32))

/* Supported nominal sample rates. */
static const Float64 kSupportedSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
enum { kNumberOfSupportedSampleRates = 4 };
#define kDefaultSampleRate              48000.0

/* Volume control range in decibels. */
#define kVolume_MinDB                   (-96.0f)
#define kVolume_MaxDB                   (0.0f)

/* Host storage key used to persist the published device count. */
#define kStorageKey_DeviceCount         CFSTR("deviceCount")

/* ======================================================================== */
#pragma mark Object IDs
/* ======================================================================== */

/*
 * Fixed objects:
 *   kAudioObjectPlugInObject (== 1)  the plug-in object
 *   2                                the box
 *
 * Per-device objects use a deterministic scheme so that IDs are unique within
 * the plug-in and stable while published:
 *
 *   base(d) = kFirstDeviceObjectID + d * kObjectsPerDevice     (d is 0-based)
 *   device      = base + 0
 *   inStream    = base + 1
 *   outStream   = base + 2
 *   volControl  = base + 3
 *   muteControl = base + 4
 *
 * Device #1 (d == 0) therefore occupies IDs 3..7, byte-identical to the Phase 0
 * driver, so existing clients and looptest keep working.
 */
enum
{
    kObjectID_PlugIn                    = kAudioObjectPlugInObject, /* == 1 */
    kObjectID_Box                       = 2,
    kFirstDeviceObjectID                = 3,
    kObjectsPerDevice                   = 5
};

static inline AudioObjectID OA_DeviceID(UInt32 d)    { return (AudioObjectID)(kFirstDeviceObjectID + d * kObjectsPerDevice + 0); }
static inline AudioObjectID OA_InStreamID(UInt32 d)  { return (AudioObjectID)(kFirstDeviceObjectID + d * kObjectsPerDevice + 1); }
static inline AudioObjectID OA_OutStreamID(UInt32 d) { return (AudioObjectID)(kFirstDeviceObjectID + d * kObjectsPerDevice + 2); }
static inline AudioObjectID OA_VolID(UInt32 d)       { return (AudioObjectID)(kFirstDeviceObjectID + d * kObjectsPerDevice + 3); }
static inline AudioObjectID OA_MuteID(UInt32 d)      { return (AudioObjectID)(kFirstDeviceObjectID + d * kObjectsPerDevice + 4); }

typedef enum
{
    kObjectKind_Unknown = 0,
    kObjectKind_PlugIn,
    kObjectKind_Box,
    kObjectKind_Device,
    kObjectKind_StreamInput,
    kObjectKind_StreamOutput,
    kObjectKind_Volume,
    kObjectKind_Mute
} OAObjectKind;

/* ======================================================================== */
#pragma mark Global driver state
/* ======================================================================== */

/* The COM interface plumbing. */
static HRESULT      OpenAudio_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG        OpenAudio_AddRef(void* inDriver);
static ULONG        OpenAudio_Release(void* inDriver);

static OSStatus     OpenAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus     OpenAudio_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus     OpenAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus     OpenAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus     OpenAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus     OpenAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus     OpenAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean      OpenAudio_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus     OpenAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus     OpenAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus     OpenAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus     OpenAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus     OpenAudio_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus     OpenAudio_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus     OpenAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus     OpenAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus     OpenAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus     OpenAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus     OpenAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

/* The interface itself and the two-level ref that the factory hands back. */
static AudioServerPlugInDriverInterface gAudioServerPlugInDriverInterface =
{
    NULL,
    OpenAudio_QueryInterface,
    OpenAudio_AddRef,
    OpenAudio_Release,
    OpenAudio_Initialize,
    OpenAudio_CreateDevice,
    OpenAudio_DestroyDevice,
    OpenAudio_AddDeviceClient,
    OpenAudio_RemoveDeviceClient,
    OpenAudio_PerformDeviceConfigurationChange,
    OpenAudio_AbortDeviceConfigurationChange,
    OpenAudio_HasProperty,
    OpenAudio_IsPropertySettable,
    OpenAudio_GetPropertyDataSize,
    OpenAudio_GetPropertyData,
    OpenAudio_SetPropertyData,
    OpenAudio_StartIO,
    OpenAudio_StopIO,
    OpenAudio_GetZeroTimeStamp,
    OpenAudio_WillDoIOOperation,
    OpenAudio_BeginIOOperation,
    OpenAudio_DoIOOperation,
    OpenAudio_EndIOOperation
};
static AudioServerPlugInDriverInterface*    gAudioServerPlugInDriverInterfacePtr    = &gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef           gAudioServerPlugInDriverRef             = &gAudioServerPlugInDriverInterfacePtr;
static UInt32                               gAudioServerPlugInDriverRefCount        = 1;

/* Host reference, set in Initialize. */
static AudioServerPlugInHostRef             gPlugIn_Host                            = NULL;

/* State-change mutex. NEVER taken on the IO path. */
static pthread_mutex_t                      gStateMutex                             = PTHREAD_MUTEX_INITIALIZER;

/* Box acquisition state. */
static bool                                 gBox_Acquired                           = true;

/* Per-device state. gDevices[d] is meaningful for d < gDeviceCount (published);
   slots >= gDeviceCount are inactive but kept sane so re-publishing is clean. */
typedef struct OADevice
{
    /* Configuration (guarded by gStateMutex for writers). */
    Float64     sampleRate;
    UInt64      ioRunningCount;
    bool        inputStreamActive;
    bool        outputStreamActive;
    Float32     volumeValue;
    bool        muteValue;

    /* Clock anchor for GetZeroTimeStamp. Once IO is running these are written
       only by that device's single IO thread. */
    Float64     hostTicksPerFrame;
    UInt64      anchorHostTime;
    UInt64      numberTimeStamps;

    /* Points at the statically-allocated ring for this slot; never reallocated
       and never touched on the IO path except read/write of samples. */
    Float32*    ring;
} OADevice;

static OADevice     gDevices[kOpenAudioMaxDevices];

/* Ring buffers (interleaved Float32, [frame*channels + channel]). Statically
   allocated at load time; the IO path only reads/writes them. */
static Float32      gRingStorage[kOpenAudioMaxDevices][kRingBufferFrameSize * kNumberOfChannels];

/* Number of currently-published devices, 1...kOpenAudioMaxDevices. Written only
   under gStateMutex; read elsewhere as a single aligned word (benign race — any
   observed value is a valid in-range bound). */
static UInt32       gDeviceCount                                                    = 1;

/* ======================================================================== */
#pragma mark Small helpers
/* ======================================================================== */

static inline UInt32 OA_GetDeviceCount(void)
{
    /* Single aligned 32-bit read; see note on gDeviceCount. */
    return gDeviceCount;
}

/* Initialize a device slot to defaults. Called under gStateMutex (or before any
   IO thread exists, in Initialize). */
static void OA_InitDeviceSlot(UInt32 d)
{
    OADevice* dev = &gDevices[d];
    dev->sampleRate         = kDefaultSampleRate;
    dev->ioRunningCount     = 0;
    dev->inputStreamActive  = true;
    dev->outputStreamActive = true;
    dev->volumeValue        = 1.0f;
    dev->muteValue          = false;
    dev->hostTicksPerFrame  = 0.0;
    dev->anchorHostTime     = 0;
    dev->numberTimeStamps   = 0;
    dev->ring               = gRingStorage[d];
}

/* Device identity strings. n is 1-based. Callers own the returned reference. */
static CFStringRef OA_CopyDeviceUID(UInt32 n)
{
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("OpenAudioDevice-%u"), (unsigned)n);
}

static CFStringRef OA_CopyDeviceModelUID(UInt32 n)
{
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("OpenAudioDevice-Model-%u"), (unsigned)n);
}

static CFStringRef OA_CopyDeviceName(UInt32 n)
{
    /* Device 1 keeps the pre-Phase-2 name for compatibility. */
    if(n <= 1)
    {
        return CFStringCreateWithFormat(NULL, NULL, CFSTR("OpenAudio 16ch"));
    }
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("OpenAudio 16ch %u"), (unsigned)n);
}

static void OA_PersistDeviceCount(UInt32 count)
{
    if((gPlugIn_Host == NULL) || (gPlugIn_Host->WriteToStorage == NULL)) { return; }
    SInt32 value = (SInt32)count;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
    if(number != NULL)
    {
        gPlugIn_Host->WriteToStorage(gPlugIn_Host, kStorageKey_DeviceCount, number);
        CFRelease(number);
    }
}

/* Resolve an AudioObjectID to its kind. If requirePublished is true, per-device
   objects belonging to slots >= gDeviceCount resolve to Unknown (they are not
   published). IO-path callers pass false so that in-flight teardown of a
   just-removed device is tolerated without consulting the state. */
static OAObjectKind OA_Resolve(AudioObjectID inObjectID, bool requirePublished, UInt32* outDeviceIndex)
{
    if(outDeviceIndex != NULL) { *outDeviceIndex = 0; }

    if(inObjectID == kObjectID_PlugIn) { return kObjectKind_PlugIn; }
    if(inObjectID == kObjectID_Box)    { return kObjectKind_Box; }
    if(inObjectID < (AudioObjectID)kFirstDeviceObjectID) { return kObjectKind_Unknown; }

    UInt32 offset = (UInt32)inObjectID - (UInt32)kFirstDeviceObjectID;
    UInt32 d      = offset / (UInt32)kObjectsPerDevice;
    UInt32 role   = offset % (UInt32)kObjectsPerDevice;

    if(d >= (UInt32)kOpenAudioMaxDevices) { return kObjectKind_Unknown; }
    if(requirePublished && (d >= OA_GetDeviceCount())) { return kObjectKind_Unknown; }

    if(outDeviceIndex != NULL) { *outDeviceIndex = d; }

    switch(role)
    {
        case 0: return kObjectKind_Device;
        case 1: return kObjectKind_StreamInput;
        case 2: return kObjectKind_StreamOutput;
        case 3: return kObjectKind_Volume;
        case 4: return kObjectKind_Mute;
        default: return kObjectKind_Unknown;
    }
}

static inline Float32 OpenAudio_VolumeScalarToDB(Float32 inScalar)
{
    if(inScalar <= 0.0f)
    {
        return kVolume_MinDB;
    }
    Float32 theDB = 20.0f * log10f(inScalar);
    if(theDB < kVolume_MinDB) { theDB = kVolume_MinDB; }
    if(theDB > kVolume_MaxDB) { theDB = kVolume_MaxDB; }
    return theDB;
}

static inline Float32 OpenAudio_VolumeDBToScalar(Float32 inDB)
{
    if(inDB <= kVolume_MinDB) { return 0.0f; }
    if(inDB > kVolume_MaxDB)  { inDB = kVolume_MaxDB; }
    return powf(10.0f, inDB / 20.0f);
}

static inline bool OpenAudio_IsSupportedSampleRate(Float64 inRate)
{
    for(UInt32 i = 0; i < kNumberOfSupportedSampleRates; ++i)
    {
        if(kSupportedSampleRates[i] == inRate) { return true; }
    }
    return false;
}

/* Fill an AudioStreamBasicDescription for our fixed 16ch Float32 format. */
static void OpenAudio_FillFormat(AudioStreamBasicDescription* outFormat, Float64 inSampleRate)
{
    outFormat->mSampleRate          = inSampleRate;
    outFormat->mFormatID            = kAudioFormatLinearPCM;
    outFormat->mFormatFlags         = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    outFormat->mBytesPerPacket      = kBytesPerFrame;
    outFormat->mFramesPerPacket     = 1;
    outFormat->mBytesPerFrame       = kBytesPerFrame;
    outFormat->mChannelsPerFrame    = kNumberOfChannels;
    outFormat->mBitsPerChannel      = kBitsPerChannel;
    outFormat->mReserved            = 0;
}

/* ======================================================================== */
#pragma mark Factory + COM plumbing
/* ======================================================================== */

/* Named to match CFPlugInFactories in OpenAudioDriver-Info.plist. */
void*   OpenAudioDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void*   OpenAudioDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    #pragma unused(inAllocator)
    void* theAnswer = NULL;
    if(CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID))
    {
        theAnswer = gAudioServerPlugInDriverRef;
    }
    return theAnswer;
}

static HRESULT  OpenAudio_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if((inDriver != gAudioServerPlugInDriverRef) || (outInterface == NULL))
    {
        return kAudioHardwareBadObjectError;
    }

    CFUUIDRef theRequestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if(theRequestedUUID == NULL)
    {
        return kAudioHardwareIllegalOperationError;
    }

    HRESULT theResult;
    if(CFEqual(theRequestedUUID, IUnknownUUID) || CFEqual(theRequestedUUID, kAudioServerPlugInDriverInterfaceUUID))
    {
        pthread_mutex_lock(&gStateMutex);
        ++gAudioServerPlugInDriverRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gAudioServerPlugInDriverRef;
        theResult = 0; /* S_OK */
    }
    else
    {
        theResult = (HRESULT)E_NOINTERFACE;
    }

    CFRelease(theRequestedUUID);
    return theResult;
}

static ULONG    OpenAudio_AddRef(void* inDriver)
{
    if(inDriver != gAudioServerPlugInDriverRef) { return 0; }
    pthread_mutex_lock(&gStateMutex);
    if(gAudioServerPlugInDriverRefCount < UINT32_MAX) { ++gAudioServerPlugInDriverRefCount; }
    ULONG theCount = gAudioServerPlugInDriverRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return theCount;
}

static ULONG    OpenAudio_Release(void* inDriver)
{
    if(inDriver != gAudioServerPlugInDriverRef) { return 0; }
    pthread_mutex_lock(&gStateMutex);
    if(gAudioServerPlugInDriverRefCount > 0) { --gAudioServerPlugInDriverRefCount; }
    ULONG theCount = gAudioServerPlugInDriverRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return theCount;
}

/* ======================================================================== */
#pragma mark Lifecycle
/* ======================================================================== */

static OSStatus OpenAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }

    gPlugIn_Host = inHost;

    /* Restore the persisted device count (defaults to 1 when absent/invalid). */
    UInt32 theCount = 1;
    if((inHost != NULL) && (inHost->CopyFromStorage != NULL))
    {
        CFPropertyListRef theStored = NULL;
        OSStatus theStatus = inHost->CopyFromStorage(inHost, kStorageKey_DeviceCount, &theStored);
        if((theStatus == 0) && (theStored != NULL))
        {
            if(CFGetTypeID(theStored) == CFNumberGetTypeID())
            {
                SInt32 theValue = 0;
                if(CFNumberGetValue((CFNumberRef)theStored, kCFNumberSInt32Type, &theValue))
                {
                    if((theValue >= 1) && (theValue <= kOpenAudioMaxDevices))
                    {
                        theCount = (UInt32)theValue;
                    }
                }
            }
            CFRelease(theStored);
        }
    }

    /* All slots start from a clean, sane state. Ring storage lives in BSS and is
       therefore already zero-initialized; StartIO re-clears a device's ring on
       its first client, so we do not touch the (possibly large) ring pages
       here. */
    for(UInt32 d = 0; d < (UInt32)kOpenAudioMaxDevices; ++d)
    {
        OA_InitDeviceSlot(d);
    }

    gDeviceCount = theCount;
    gBox_Acquired = true;

    return 0;
}

static OSStatus OpenAudio_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    #pragma unused(inDescription, inClientInfo, outDeviceObjectID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    /* Devices are published statically and controlled via kOpenAudioPropertyDeviceCount;
       host-driven dynamic creation is not supported. */
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus OpenAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    #pragma unused(inDeviceObjectID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus OpenAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    #pragma unused(inClientInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(OA_Resolve(inDeviceObjectID, true, NULL) != kObjectKind_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

static OSStatus OpenAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    #pragma unused(inClientInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    /* Tolerate a device that has just been unpublished. */
    if(OA_Resolve(inDeviceObjectID, false, NULL) != kObjectKind_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

static OSStatus OpenAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inChangeInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }

    UInt32 d = 0;
    if(OA_Resolve(inDeviceObjectID, false, &d) != kObjectKind_Device) { return kAudioHardwareBadObjectError; }

    /* The only configuration change we request is a sample-rate change, where
       inChangeAction carries the new rate. */
    Float64 theNewRate = (Float64)inChangeAction;
    if(!OpenAudio_IsSupportedSampleRate(theNewRate))
    {
        return kAudioHardwareIllegalOperationError;
    }

    pthread_mutex_lock(&gStateMutex);
    gDevices[d].sampleRate = theNewRate;
    pthread_mutex_unlock(&gStateMutex);

    return 0;
}

static OSStatus OpenAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inChangeAction, inChangeInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(OA_Resolve(inDeviceObjectID, false, NULL) != kObjectKind_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

/* ======================================================================== */
#pragma mark Property dispatch — HasProperty
/* ======================================================================== */

static bool PlugIn_HasProperty(AudioObjectPropertySelector inSelector)
{
    switch(inSelector)
    {
        case kAudioObjectPropertySelectorWildcard:
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kOpenAudioPropertyDeviceCount:
            return true;
        default:
            return false;
    }
}

static bool Box_HasProperty(AudioObjectPropertySelector inSelector)
{
    switch(inSelector)
    {
        case kAudioObjectPropertySelectorWildcard:
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyIdentify:
        case kAudioObjectPropertySerialNumber:
        case kAudioObjectPropertyFirmwareVersion:
        case kAudioBoxPropertyBoxUID:
        case kAudioBoxPropertyTransportType:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquired:
        case kAudioBoxPropertyAcquisitionFailed:
        case kAudioBoxPropertyDeviceList:
            return true;
        default:
            return false;
    }
}

static bool Device_HasProperty(AudioObjectPropertySelector inSelector)
{
    switch(inSelector)
    {
        case kAudioObjectPropertySelectorWildcard:
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyIdentify:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
        case kAudioDevicePropertyConfigurationApplication:
            return true;
        default:
            return false;
    }
}

static bool Stream_HasProperty(AudioObjectPropertySelector inSelector)
{
    switch(inSelector)
    {
        case kAudioObjectPropertySelectorWildcard:
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static bool Volume_HasProperty(AudioObjectPropertySelector inSelector)
{
    switch(inSelector)
    {
        case kAudioObjectPropertySelectorWildcard:
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyDecibelRange:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            return true;
        default:
            return false;
    }
}

static bool Mute_HasProperty(AudioObjectPropertySelector inSelector)
{
    switch(inSelector)
    {
        case kAudioObjectPropertySelectorWildcard:
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
        case kAudioBooleanControlPropertyValue:
            return true;
        default:
            return false;
    }
}

static Boolean OpenAudio_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inClientProcessID)
    if((inDriver != gAudioServerPlugInDriverRef) || (inAddress == NULL)) { return false; }

    switch(OA_Resolve(inObjectID, true, NULL))
    {
        case kObjectKind_PlugIn:        return PlugIn_HasProperty(inAddress->mSelector);
        case kObjectKind_Box:           return Box_HasProperty(inAddress->mSelector);
        case kObjectKind_Device:        return Device_HasProperty(inAddress->mSelector);
        case kObjectKind_StreamInput:
        case kObjectKind_StreamOutput:  return Stream_HasProperty(inAddress->mSelector);
        case kObjectKind_Volume:        return Volume_HasProperty(inAddress->mSelector);
        case kObjectKind_Mute:          return Mute_HasProperty(inAddress->mSelector);
        default:                        return false;
    }
}

/* ======================================================================== */
#pragma mark Property dispatch — IsPropertySettable
/* ======================================================================== */

static OSStatus OpenAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inClientProcessID)
    if((inDriver != gAudioServerPlugInDriverRef) || (inAddress == NULL) || (outIsSettable == NULL))
    {
        return kAudioHardwareIllegalOperationError;
    }

    if(!OpenAudio_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress))
    {
        return kAudioHardwareUnknownPropertyError;
    }

    Boolean theSettable = false;
    switch(OA_Resolve(inObjectID, true, NULL))
    {
        case kObjectKind_PlugIn:
            theSettable = (inAddress->mSelector == kOpenAudioPropertyDeviceCount);
            break;

        case kObjectKind_Box:
            theSettable = (inAddress->mSelector == kAudioObjectPropertyName) ||
                          (inAddress->mSelector == kAudioObjectPropertyIdentify) ||
                          (inAddress->mSelector == kAudioBoxPropertyAcquired);
            break;

        case kObjectKind_Device:
            theSettable = (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate);
            break;

        case kObjectKind_StreamInput:
        case kObjectKind_StreamOutput:
            theSettable = (inAddress->mSelector == kAudioStreamPropertyIsActive) ||
                          (inAddress->mSelector == kAudioStreamPropertyVirtualFormat) ||
                          (inAddress->mSelector == kAudioStreamPropertyPhysicalFormat);
            break;

        case kObjectKind_Volume:
            theSettable = (inAddress->mSelector == kAudioLevelControlPropertyScalarValue) ||
                          (inAddress->mSelector == kAudioLevelControlPropertyDecibelValue);
            break;

        case kObjectKind_Mute:
            theSettable = (inAddress->mSelector == kAudioBooleanControlPropertyValue);
            break;

        default:
            break;
    }

    *outIsSettable = theSettable;
    return 0;
}

/* ======================================================================== */
#pragma mark Property dispatch — GetPropertyDataSize
/* ======================================================================== */

static OSStatus OpenAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    if((inDriver != gAudioServerPlugInDriverRef) || (inAddress == NULL) || (outDataSize == NULL))
    {
        return kAudioHardwareIllegalOperationError;
    }

    UInt32 d = 0;
    OAObjectKind theKind = OA_Resolve(inObjectID, true, &d);

    switch(theKind)
    {
        /* ---- PlugIn ---- */
        case kObjectKind_PlugIn:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:                     *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:                     *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyManufacturer:              *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyOwnedObjects:              *outDataSize = (1 + OA_GetDeviceCount()) * sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyBoxList:                   *outDataSize = 1 * sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyTranslateUIDToBox:         *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyDeviceList:                *outDataSize = OA_GetDeviceCount() * sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyTranslateUIDToDevice:      *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyResourceBundle:            *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyCustomPropertyInfoList:    *outDataSize = 1 * sizeof(AudioServerPlugInCustomPropertyInfo); return 0;
                case kOpenAudioPropertyDeviceCount:                 *outDataSize = sizeof(CFPropertyListRef); return 0;
                default:                                            return kAudioHardwareUnknownPropertyError;
            }

        /* ---- Box ---- */
        case kObjectKind_Box:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:                     *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:                     *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyModelName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertySerialNumber:
                case kAudioObjectPropertyFirmwareVersion:
                case kAudioBoxPropertyBoxUID:                       *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyOwnedObjects:              *outDataSize = 0; return 0;
                case kAudioObjectPropertyIdentify:                  *outDataSize = sizeof(UInt32); return 0;
                case kAudioBoxPropertyTransportType:                *outDataSize = sizeof(UInt32); return 0;
                case kAudioBoxPropertyHasAudio:
                case kAudioBoxPropertyHasVideo:
                case kAudioBoxPropertyHasMIDI:
                case kAudioBoxPropertyIsProtected:
                case kAudioBoxPropertyAcquired:
                case kAudioBoxPropertyAcquisitionFailed:            *outDataSize = sizeof(UInt32); return 0;
                case kAudioBoxPropertyDeviceList:                   *outDataSize = (gBox_Acquired ? OA_GetDeviceCount() : 0) * sizeof(AudioObjectID); return 0;
                default:                                            return kAudioHardwareUnknownPropertyError;
            }

        /* ---- Device ---- */
        case kObjectKind_Device:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:                     *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:                     *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyModelName:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyConfigurationApplication: *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyOwnedObjects:              *outDataSize = 4 * sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyIdentify:                  *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyTransportType:             *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyRelatedDevices:            *outDataSize = 1 * sizeof(AudioObjectID); return 0;
                case kAudioDevicePropertyClockDomain:               *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyDeviceIsAlive:             *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyDeviceIsRunning:           *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:  *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyLatency:                   *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyStreams:
                {
                    UInt32 theCount = 0;
                    if((inAddress->mScope == kAudioObjectPropertyScopeGlobal) || (inAddress->mScope == kAudioObjectPropertyScopeInput))  { theCount += 1; }
                    if((inAddress->mScope == kAudioObjectPropertyScopeGlobal) || (inAddress->mScope == kAudioObjectPropertyScopeOutput)) { theCount += 1; }
                    *outDataSize = theCount * sizeof(AudioObjectID);
                    return 0;
                }
                case kAudioObjectPropertyControlList:               *outDataSize = 2 * sizeof(AudioObjectID); return 0;
                case kAudioDevicePropertySafetyOffset:              *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyNominalSampleRate:         *outDataSize = sizeof(Float64); return 0;
                case kAudioDevicePropertyAvailableNominalSampleRates: *outDataSize = kNumberOfSupportedSampleRates * sizeof(AudioValueRange); return 0;
                case kAudioDevicePropertyIsHidden:                  *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyZeroTimeStampPeriod:       *outDataSize = sizeof(UInt32); return 0;
                case kAudioDevicePropertyPreferredChannelsForStereo: *outDataSize = 2 * sizeof(UInt32); return 0;
                case kAudioDevicePropertyPreferredChannelLayout:    *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (kNumberOfChannels * sizeof(AudioChannelDescription)); return 0;
                default:                                            return kAudioHardwareUnknownPropertyError;
            }

        /* ---- Streams ---- */
        case kObjectKind_StreamInput:
        case kObjectKind_StreamOutput:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:                     *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:                     *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyOwnedObjects:              *outDataSize = 0; return 0;
                case kAudioStreamPropertyIsActive:                  *outDataSize = sizeof(UInt32); return 0;
                case kAudioStreamPropertyDirection:                 *outDataSize = sizeof(UInt32); return 0;
                case kAudioStreamPropertyTerminalType:              *outDataSize = sizeof(UInt32); return 0;
                case kAudioStreamPropertyStartingChannel:           *outDataSize = sizeof(UInt32); return 0;
                case kAudioStreamPropertyLatency:                   *outDataSize = sizeof(UInt32); return 0;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:            *outDataSize = sizeof(AudioStreamBasicDescription); return 0;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:  *outDataSize = kNumberOfSupportedSampleRates * sizeof(AudioStreamRangedDescription); return 0;
                default:                                            return kAudioHardwareUnknownPropertyError;
            }

        /* ---- Volume control ---- */
        case kObjectKind_Volume:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:                     *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:                     *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyOwnedObjects:              *outDataSize = 0; return 0;
                case kAudioControlPropertyScope:                    *outDataSize = sizeof(AudioObjectPropertyScope); return 0;
                case kAudioControlPropertyElement:                  *outDataSize = sizeof(AudioObjectPropertyElement); return 0;
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                case kAudioLevelControlPropertyConvertDecibelsToScalar: *outDataSize = sizeof(Float32); return 0;
                case kAudioLevelControlPropertyDecibelRange:        *outDataSize = sizeof(AudioValueRange); return 0;
                default:                                            return kAudioHardwareUnknownPropertyError;
            }

        /* ---- Mute control ---- */
        case kObjectKind_Mute:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:                     *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:                     *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyOwnedObjects:              *outDataSize = 0; return 0;
                case kAudioControlPropertyScope:                    *outDataSize = sizeof(AudioObjectPropertyScope); return 0;
                case kAudioControlPropertyElement:                  *outDataSize = sizeof(AudioObjectPropertyElement); return 0;
                case kAudioBooleanControlPropertyValue:             *outDataSize = sizeof(UInt32); return 0;
                default:                                            return kAudioHardwareUnknownPropertyError;
            }

        default:
            return kAudioHardwareBadObjectError;
    }
}

/* ======================================================================== */
#pragma mark Property dispatch — GetPropertyData
/* ======================================================================== */

/* Convenience: bail if the caller's buffer is too small. */
#define REQUIRE_SIZE(need) do { if(inDataSize < (need)) { return kAudioHardwareBadPropertySizeError; } } while(0)

static OSStatus GetPlugInPropertyData(pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inClientProcessID)
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            REQUIRE_SIZE(sizeof(AudioClassID));
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyClass:
            REQUIRE_SIZE(sizeof(AudioClassID));
            *((AudioClassID*)outData) = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyOwner:
            REQUIRE_SIZE(sizeof(AudioObjectID));
            *((AudioObjectID*)outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioObjectPropertyManufacturer:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer);
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyOwnedObjects:
        {
            UInt32 theDeviceCount = OA_GetDeviceCount();
            AudioObjectID theItems[1 + kOpenAudioMaxDevices];
            theItems[0] = kObjectID_Box;
            for(UInt32 i = 0; i < theDeviceCount; ++i) { theItems[1 + i] = OA_DeviceID(i); }
            UInt32 theTotal = 1 + theDeviceCount;
            UInt32 theMax = inDataSize / sizeof(AudioObjectID);
            UInt32 theCount = (theMax < theTotal) ? theMax : theTotal;
            memcpy(outData, theItems, theCount * sizeof(AudioObjectID));
            *outDataSize = theCount * sizeof(AudioObjectID);
            return 0;
        }

        case kAudioPlugInPropertyBoxList:
        {
            REQUIRE_SIZE(sizeof(AudioObjectID));
            *((AudioObjectID*)outData) = kObjectID_Box;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        }

        case kAudioPlugInPropertyTranslateUIDToBox:
        {
            REQUIRE_SIZE(sizeof(AudioObjectID));
            if((inQualifierData == NULL) || (inQualifierDataSize != sizeof(CFStringRef)))
            {
                return kAudioHardwareIllegalOperationError;
            }
            CFStringRef theUID = *((CFStringRef*)inQualifierData);
            AudioObjectID theID = kAudioObjectUnknown;
            if((theUID != NULL) && (CFStringCompare(theUID, CFSTR(kBox_UID), 0) == kCFCompareEqualTo))
            {
                theID = kObjectID_Box;
            }
            *((AudioObjectID*)outData) = theID;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        }

        case kAudioPlugInPropertyDeviceList:
        {
            UInt32 theDeviceCount = OA_GetDeviceCount();
            AudioObjectID theItems[kOpenAudioMaxDevices];
            for(UInt32 i = 0; i < theDeviceCount; ++i) { theItems[i] = OA_DeviceID(i); }
            UInt32 theMax = inDataSize / sizeof(AudioObjectID);
            UInt32 theCount = (theMax < theDeviceCount) ? theMax : theDeviceCount;
            memcpy(outData, theItems, theCount * sizeof(AudioObjectID));
            *outDataSize = theCount * sizeof(AudioObjectID);
            return 0;
        }

        case kAudioPlugInPropertyTranslateUIDToDevice:
        {
            REQUIRE_SIZE(sizeof(AudioObjectID));
            if((inQualifierData == NULL) || (inQualifierDataSize != sizeof(CFStringRef)))
            {
                return kAudioHardwareIllegalOperationError;
            }
            CFStringRef theUID = *((CFStringRef*)inQualifierData);
            AudioObjectID theID = kAudioObjectUnknown;
            if(theUID != NULL)
            {
                UInt32 theDeviceCount = OA_GetDeviceCount();
                for(UInt32 i = 0; i < theDeviceCount; ++i)
                {
                    CFStringRef theCandidate = OA_CopyDeviceUID(i + 1);
                    if(theCandidate != NULL)
                    {
                        Boolean theMatch = (CFStringCompare(theUID, theCandidate, 0) == kCFCompareEqualTo);
                        CFRelease(theCandidate);
                        if(theMatch) { theID = OA_DeviceID(i); break; }
                    }
                }
            }
            *((AudioObjectID*)outData) = theID;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        }

        case kAudioPlugInPropertyResourceBundle:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyCustomPropertyInfoList:
        {
            /* Declare our custom properties so the host proxies them to HAL
               clients. Only CFString/CFPropertyList-typed custom properties are
               forwarded by coreaudiod, hence 'OAdc' is a CFPropertyList
               (CFNumber). Honor the host-supplied buffer size: 0 entries when
               it is too small. */
            UInt32 theMax = inDataSize / (UInt32)sizeof(AudioServerPlugInCustomPropertyInfo);
            UInt32 theCount = (theMax < 1) ? theMax : 1;
            if(theCount > 0)
            {
                AudioServerPlugInCustomPropertyInfo* theInfo = (AudioServerPlugInCustomPropertyInfo*)outData;
                theInfo[0].mSelector          = kOpenAudioPropertyDeviceCount;
                theInfo[0].mPropertyDataType  = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
                theInfo[0].mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
            }
            *outDataSize = theCount * (UInt32)sizeof(AudioServerPlugInCustomPropertyInfo);
            return 0;
        }

        case kOpenAudioPropertyDeviceCount:
        {
            /* CFPropertyList-typed custom property: hand back a +1-retained
               CFNumber that the host releases after marshalling it to the
               client. */
            REQUIRE_SIZE(sizeof(CFPropertyListRef));
            pthread_mutex_lock(&gStateMutex);
            SInt32 theCount = (SInt32)gDeviceCount;
            pthread_mutex_unlock(&gStateMutex);
            *((CFPropertyListRef*)outData) = CFNumberCreate(NULL, kCFNumberSInt32Type, &theCount);
            *outDataSize = sizeof(CFPropertyListRef);
            return 0;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetBoxPropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            REQUIRE_SIZE(sizeof(AudioClassID));
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyClass:
            REQUIRE_SIZE(sizeof(AudioClassID));
            *((AudioClassID*)outData) = kAudioBoxClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyOwner:
            REQUIRE_SIZE(sizeof(AudioObjectID));
            *((AudioObjectID*)outData) = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioObjectPropertyName:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = CFSTR(kBox_Name);
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyModelName:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = CFSTR(kBox_ModelUID);
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyManufacturer:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer);
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertySerialNumber:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = CFSTR("OA-0001");
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyFirmwareVersion:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = CFSTR("1.0.0");
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return 0;

        case kAudioObjectPropertyIdentify:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioBoxPropertyBoxUID:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = CFSTR(kBox_UID);
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioBoxPropertyTransportType:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioBoxPropertyHasAudio:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquisitionFailed:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioBoxPropertyAcquired:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = gBox_Acquired ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioBoxPropertyDeviceList:
        {
            if(gBox_Acquired)
            {
                UInt32 theDeviceCount = OA_GetDeviceCount();
                AudioObjectID theItems[kOpenAudioMaxDevices];
                for(UInt32 i = 0; i < theDeviceCount; ++i) { theItems[i] = OA_DeviceID(i); }
                UInt32 theMax = inDataSize / sizeof(AudioObjectID);
                UInt32 theCount = (theMax < theDeviceCount) ? theMax : theDeviceCount;
                memcpy(outData, theItems, theCount * sizeof(AudioObjectID));
                *outDataSize = theCount * sizeof(AudioObjectID);
            }
            else
            {
                *outDataSize = 0;
            }
            return 0;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetDevicePropertyData(UInt32 inDeviceIndex, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            REQUIRE_SIZE(sizeof(AudioClassID));
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyClass:
            REQUIRE_SIZE(sizeof(AudioClassID));
            *((AudioClassID*)outData) = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyOwner:
            REQUIRE_SIZE(sizeof(AudioObjectID));
            *((AudioObjectID*)outData) = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioObjectPropertyName:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = OA_CopyDeviceName(inDeviceIndex + 1);
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyManufacturer:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer);
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyModelName:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = OA_CopyDeviceName(inDeviceIndex + 1);
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyOwnedObjects:
        {
            AudioObjectID theItems[4] = { OA_InStreamID(inDeviceIndex), OA_OutStreamID(inDeviceIndex), OA_VolID(inDeviceIndex), OA_MuteID(inDeviceIndex) };
            UInt32 theMax = inDataSize / sizeof(AudioObjectID);
            UInt32 theCount = (theMax < 4) ? theMax : 4;
            memcpy(outData, theItems, theCount * sizeof(AudioObjectID));
            *outDataSize = theCount * sizeof(AudioObjectID);
            return 0;
        }

        case kAudioObjectPropertyIdentify:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyDeviceUID:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = OA_CopyDeviceUID(inDeviceIndex + 1);
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioDevicePropertyModelUID:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = OA_CopyDeviceModelUID(inDeviceIndex + 1);
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioDevicePropertyConfigurationApplication:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = CFSTR("com.apple.audio.AudioMIDISetup");
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioDevicePropertyTransportType:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyRelatedDevices:
            REQUIRE_SIZE(sizeof(AudioObjectID));
            *((AudioObjectID*)outData) = OA_DeviceID(inDeviceIndex);
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioDevicePropertyClockDomain:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyDeviceIsAlive:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyDeviceIsRunning:
            REQUIRE_SIZE(sizeof(UInt32));
            pthread_mutex_lock(&gStateMutex);
            *((UInt32*)outData) = (gDevices[inDeviceIndex].ioRunningCount > 0) ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyLatency:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyStreams:
        {
            AudioObjectID theItems[2];
            UInt32 theCount = 0;
            if((inAddress->mScope == kAudioObjectPropertyScopeGlobal) || (inAddress->mScope == kAudioObjectPropertyScopeInput))
            {
                theItems[theCount++] = OA_InStreamID(inDeviceIndex);
            }
            if((inAddress->mScope == kAudioObjectPropertyScopeGlobal) || (inAddress->mScope == kAudioObjectPropertyScopeOutput))
            {
                theItems[theCount++] = OA_OutStreamID(inDeviceIndex);
            }
            UInt32 theMax = inDataSize / sizeof(AudioObjectID);
            if(theCount > theMax) { theCount = theMax; }
            memcpy(outData, theItems, theCount * sizeof(AudioObjectID));
            *outDataSize = theCount * sizeof(AudioObjectID);
            return 0;
        }

        case kAudioObjectPropertyControlList:
        {
            AudioObjectID theItems[2] = { OA_VolID(inDeviceIndex), OA_MuteID(inDeviceIndex) };
            UInt32 theMax = inDataSize / sizeof(AudioObjectID);
            UInt32 theCount = (theMax < 2) ? theMax : 2;
            memcpy(outData, theItems, theCount * sizeof(AudioObjectID));
            *outDataSize = theCount * sizeof(AudioObjectID);
            return 0;
        }

        case kAudioDevicePropertySafetyOffset:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyNominalSampleRate:
            REQUIRE_SIZE(sizeof(Float64));
            pthread_mutex_lock(&gStateMutex);
            *((Float64*)outData) = gDevices[inDeviceIndex].sampleRate;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(Float64);
            return 0;

        case kAudioDevicePropertyAvailableNominalSampleRates:
        {
            UInt32 theMax = inDataSize / sizeof(AudioValueRange);
            UInt32 theCount = (theMax < kNumberOfSupportedSampleRates) ? theMax : kNumberOfSupportedSampleRates;
            AudioValueRange* theRanges = (AudioValueRange*)outData;
            for(UInt32 i = 0; i < theCount; ++i)
            {
                theRanges[i].mMinimum = kSupportedSampleRates[i];
                theRanges[i].mMaximum = kSupportedSampleRates[i];
            }
            *outDataSize = theCount * sizeof(AudioValueRange);
            return 0;
        }

        case kAudioDevicePropertyIsHidden:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyZeroTimeStampPeriod:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = kZeroTimestampPeriod;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioDevicePropertyPreferredChannelsForStereo:
        {
            REQUIRE_SIZE(2 * sizeof(UInt32));
            UInt32* thePair = (UInt32*)outData;
            thePair[0] = 1;
            thePair[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return 0;
        }

        case kAudioDevicePropertyPreferredChannelLayout:
        {
            UInt32 theNeed = offsetof(AudioChannelLayout, mChannelDescriptions) + (kNumberOfChannels * sizeof(AudioChannelDescription));
            REQUIRE_SIZE(theNeed);
            AudioChannelLayout* theLayout = (AudioChannelLayout*)outData;
            memset(theLayout, 0, theNeed);
            theLayout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            theLayout->mNumberChannelDescriptions = kNumberOfChannels;
            for(UInt32 i = 0; i < kNumberOfChannels; ++i)
            {
                theLayout->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_Discrete_0 | i;
                theLayout->mChannelDescriptions[i].mChannelFlags = 0;
            }
            *outDataSize = theNeed;
            return 0;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetStreamPropertyData(UInt32 inDeviceIndex, bool inIsInput, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            REQUIRE_SIZE(sizeof(AudioClassID));
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyClass:
            REQUIRE_SIZE(sizeof(AudioClassID));
            *((AudioClassID*)outData) = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyOwner:
            REQUIRE_SIZE(sizeof(AudioObjectID));
            *((AudioObjectID*)outData) = OA_DeviceID(inDeviceIndex);
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return 0;

        case kAudioStreamPropertyIsActive:
            REQUIRE_SIZE(sizeof(UInt32));
            pthread_mutex_lock(&gStateMutex);
            *((UInt32*)outData) = (inIsInput ? gDevices[inDeviceIndex].inputStreamActive : gDevices[inDeviceIndex].outputStreamActive) ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioStreamPropertyDirection:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = inIsInput ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioStreamPropertyTerminalType:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = kAudioStreamTerminalTypeLine;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioStreamPropertyStartingChannel:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioStreamPropertyLatency:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        {
            REQUIRE_SIZE(sizeof(AudioStreamBasicDescription));
            pthread_mutex_lock(&gStateMutex);
            Float64 theRate = gDevices[inDeviceIndex].sampleRate;
            pthread_mutex_unlock(&gStateMutex);
            OpenAudio_FillFormat((AudioStreamBasicDescription*)outData, theRate);
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return 0;
        }

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
        {
            UInt32 theMax = inDataSize / sizeof(AudioStreamRangedDescription);
            UInt32 theCount = (theMax < kNumberOfSupportedSampleRates) ? theMax : kNumberOfSupportedSampleRates;
            AudioStreamRangedDescription* theDescs = (AudioStreamRangedDescription*)outData;
            for(UInt32 i = 0; i < theCount; ++i)
            {
                OpenAudio_FillFormat(&theDescs[i].mFormat, kSupportedSampleRates[i]);
                theDescs[i].mSampleRateRange.mMinimum = kSupportedSampleRates[i];
                theDescs[i].mSampleRateRange.mMaximum = kSupportedSampleRates[i];
            }
            *outDataSize = theCount * sizeof(AudioStreamRangedDescription);
            return 0;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetVolumePropertyData(UInt32 inDeviceIndex, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            REQUIRE_SIZE(sizeof(AudioClassID));
            *((AudioClassID*)outData) = kAudioLevelControlClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyClass:
            REQUIRE_SIZE(sizeof(AudioClassID));
            *((AudioClassID*)outData) = kAudioVolumeControlClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyOwner:
            REQUIRE_SIZE(sizeof(AudioObjectID));
            *((AudioObjectID*)outData) = OA_DeviceID(inDeviceIndex);
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return 0;

        case kAudioControlPropertyScope:
            REQUIRE_SIZE(sizeof(AudioObjectPropertyScope));
            *((AudioObjectPropertyScope*)outData) = kAudioObjectPropertyScopeOutput;
            *outDataSize = sizeof(AudioObjectPropertyScope);
            return 0;

        case kAudioControlPropertyElement:
            REQUIRE_SIZE(sizeof(AudioObjectPropertyElement));
            *((AudioObjectPropertyElement*)outData) = kAudioObjectPropertyElementMain;
            *outDataSize = sizeof(AudioObjectPropertyElement);
            return 0;

        case kAudioLevelControlPropertyScalarValue:
            REQUIRE_SIZE(sizeof(Float32));
            pthread_mutex_lock(&gStateMutex);
            *((Float32*)outData) = gDevices[inDeviceIndex].volumeValue;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(Float32);
            return 0;

        case kAudioLevelControlPropertyDecibelValue:
            REQUIRE_SIZE(sizeof(Float32));
            pthread_mutex_lock(&gStateMutex);
            *((Float32*)outData) = OpenAudio_VolumeScalarToDB(gDevices[inDeviceIndex].volumeValue);
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(Float32);
            return 0;

        case kAudioLevelControlPropertyDecibelRange:
        {
            REQUIRE_SIZE(sizeof(AudioValueRange));
            AudioValueRange* theRange = (AudioValueRange*)outData;
            theRange->mMinimum = kVolume_MinDB;
            theRange->mMaximum = kVolume_MaxDB;
            *outDataSize = sizeof(AudioValueRange);
            return 0;
        }

        case kAudioLevelControlPropertyConvertScalarToDecibels:
            REQUIRE_SIZE(sizeof(Float32));
            *((Float32*)outData) = OpenAudio_VolumeScalarToDB(*((Float32*)outData));
            *outDataSize = sizeof(Float32);
            return 0;

        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            REQUIRE_SIZE(sizeof(Float32));
            *((Float32*)outData) = OpenAudio_VolumeDBToScalar(*((Float32*)outData));
            *outDataSize = sizeof(Float32);
            return 0;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetMutePropertyData(UInt32 inDeviceIndex, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            REQUIRE_SIZE(sizeof(AudioClassID));
            *((AudioClassID*)outData) = kAudioBooleanControlClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyClass:
            REQUIRE_SIZE(sizeof(AudioClassID));
            *((AudioClassID*)outData) = kAudioMuteControlClassID;
            *outDataSize = sizeof(AudioClassID);
            return 0;

        case kAudioObjectPropertyOwner:
            REQUIRE_SIZE(sizeof(AudioObjectID));
            *((AudioObjectID*)outData) = OA_DeviceID(inDeviceIndex);
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return 0;

        case kAudioControlPropertyScope:
            REQUIRE_SIZE(sizeof(AudioObjectPropertyScope));
            *((AudioObjectPropertyScope*)outData) = kAudioObjectPropertyScopeOutput;
            *outDataSize = sizeof(AudioObjectPropertyScope);
            return 0;

        case kAudioControlPropertyElement:
            REQUIRE_SIZE(sizeof(AudioObjectPropertyElement));
            *((AudioObjectPropertyElement*)outData) = kAudioObjectPropertyElementMain;
            *outDataSize = sizeof(AudioObjectPropertyElement);
            return 0;

        case kAudioBooleanControlPropertyValue:
            REQUIRE_SIZE(sizeof(UInt32));
            pthread_mutex_lock(&gStateMutex);
            *((UInt32*)outData) = gDevices[inDeviceIndex].muteValue ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(UInt32);
            return 0;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus OpenAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    if((inDriver != gAudioServerPlugInDriverRef) || (inAddress == NULL) || (outDataSize == NULL) || (outData == NULL))
    {
        return kAudioHardwareIllegalOperationError;
    }

    UInt32 d = 0;
    switch(OA_Resolve(inObjectID, true, &d))
    {
        case kObjectKind_PlugIn:        return GetPlugInPropertyData(inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
        case kObjectKind_Box:           return GetBoxPropertyData(inAddress, inDataSize, outDataSize, outData);
        case kObjectKind_Device:        return GetDevicePropertyData(d, inAddress, inDataSize, outDataSize, outData);
        case kObjectKind_StreamInput:   return GetStreamPropertyData(d, true,  inAddress, inDataSize, outDataSize, outData);
        case kObjectKind_StreamOutput:  return GetStreamPropertyData(d, false, inAddress, inDataSize, outDataSize, outData);
        case kObjectKind_Volume:        return GetVolumePropertyData(d, inAddress, inDataSize, outDataSize, outData);
        case kObjectKind_Mute:          return GetMutePropertyData(d, inAddress, inDataSize, outDataSize, outData);
        default:                        return kAudioHardwareBadObjectError;
    }
}

/* ======================================================================== */
#pragma mark Property dispatch — SetPropertyData
/* ======================================================================== */

static OSStatus OpenAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    if((inDriver != gAudioServerPlugInDriverRef) || (inAddress == NULL) || (inData == NULL))
    {
        return kAudioHardwareIllegalOperationError;
    }

    /* Number of properties that changed, reported to the host afterwards. */
    UInt32 theChangedCount = 0;
    AudioObjectPropertyAddress theChanged[3];

    OSStatus theError = kAudioHardwareUnknownPropertyError;

    UInt32 d = 0;
    OAObjectKind theKind = OA_Resolve(inObjectID, true, &d);

    switch(theKind)
    {
        case kObjectKind_PlugIn:
            switch(inAddress->mSelector)
            {
                case kOpenAudioPropertyDeviceCount:
                {
                    /* CFPropertyList-typed custom property: inData carries a
                       CFPropertyListRef owned by the caller (do not release).
                       Accept only a CFNumber holding 1...kOpenAudioMaxDevices. */
                    if(inDataSize < sizeof(CFPropertyListRef)) { return kAudioHardwareBadPropertySizeError; }
                    CFPropertyListRef thePlist = *((const CFPropertyListRef*)inData);
                    if((thePlist == NULL) || (CFGetTypeID(thePlist) != CFNumberGetTypeID()))
                    {
                        return kAudioHardwareIllegalOperationError;
                    }
                    SInt32 theRequested = 0;
                    if(!CFNumberGetValue((CFNumberRef)thePlist, kCFNumberSInt32Type, &theRequested))
                    {
                        return kAudioHardwareIllegalOperationError;
                    }
                    if((theRequested < 1) || (theRequested > kOpenAudioMaxDevices))
                    {
                        return kAudioHardwareIllegalOperationError;
                    }
                    UInt32 theNewCount = (UInt32)theRequested;

                    bool theChangedFlag = false;
                    pthread_mutex_lock(&gStateMutex);
                    UInt32 theOldCount = gDeviceCount;
                    if(theNewCount > theOldCount)
                    {
                        /* Publish new slots: reset them to fresh defaults. Skip
                           the reset if a slot still has a live IO thread (a
                           device that was just unpublished whose StopIO has not
                           yet arrived). Its clock-anchor fields are read without
                           a lock by that IO thread, so we must not race a write
                           against it; it self-heals on the next StartIO once
                           ioRunningCount has returned to 0. */
                        for(UInt32 i = theOldCount; i < theNewCount; ++i)
                        {
                            if(gDevices[i].ioRunningCount == 0)
                            {
                                OA_InitDeviceSlot(i);
                            }
                        }
                        gDeviceCount = theNewCount;
                        theChangedFlag = true;
                    }
                    else if(theNewCount < theOldCount)
                    {
                        /* Unpublish trailing slots. Their per-device state is left
                           in place; surviving devices (lower indices) and their
                           rings/anchors are untouched. A future re-publish re-inits
                           the slot. */
                        gDeviceCount = theNewCount;
                        theChangedFlag = true;
                    }
                    pthread_mutex_unlock(&gStateMutex);

                    if(theChangedFlag)
                    {
                        /* Persist and notify the host that the device set changed.
                           Done outside the state lock so host callbacks cannot
                           deadlock against it. */
                        OA_PersistDeviceCount(theNewCount);

                        theChanged[theChangedCount].mSelector = kAudioPlugInPropertyDeviceList;
                        theChanged[theChangedCount].mScope    = kAudioObjectPropertyScopeGlobal;
                        theChanged[theChangedCount].mElement  = kAudioObjectPropertyElementMain;
                        ++theChangedCount;
                        theChanged[theChangedCount].mSelector = kAudioObjectPropertyOwnedObjects;
                        theChanged[theChangedCount].mScope    = kAudioObjectPropertyScopeGlobal;
                        theChanged[theChangedCount].mElement  = kAudioObjectPropertyElementMain;
                        ++theChangedCount;
                        theChanged[theChangedCount].mSelector = kOpenAudioPropertyDeviceCount;
                        theChanged[theChangedCount].mScope    = kAudioObjectPropertyScopeGlobal;
                        theChanged[theChangedCount].mElement  = kAudioObjectPropertyElementMain;
                        ++theChangedCount;

                        /* The box also enumerates the devices, so notify it too.
                           This is a separate object from inObjectID (the plug-in),
                           so it needs its own PropertiesChanged call; the generic
                           tail below only fires for inObjectID. */
                        if(gPlugIn_Host != NULL)
                        {
                            AudioObjectPropertyAddress theBoxChanged =
                            {
                                kAudioBoxPropertyDeviceList,
                                kAudioObjectPropertyScopeGlobal,
                                kAudioObjectPropertyElementMain
                            };
                            gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Box, 1, &theBoxChanged);
                        }
                    }
                    theError = 0;
                    break;
                }
                default:
                    theError = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        case kObjectKind_Box:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyIdentify:
                    /* Accepted but no persistent effect. */
                    theError = 0;
                    break;
                case kAudioBoxPropertyAcquired:
                    if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
                    pthread_mutex_lock(&gStateMutex);
                    gBox_Acquired = (*((const UInt32*)inData) != 0);
                    pthread_mutex_unlock(&gStateMutex);
                    theChanged[theChangedCount].mSelector = kAudioBoxPropertyAcquired;
                    theChanged[theChangedCount].mScope = kAudioObjectPropertyScopeGlobal;
                    theChanged[theChangedCount].mElement = kAudioObjectPropertyElementMain;
                    ++theChangedCount;
                    theError = 0;
                    break;
                default:
                    theError = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        case kObjectKind_Device:
            switch(inAddress->mSelector)
            {
                case kAudioDevicePropertyNominalSampleRate:
                {
                    if(inDataSize < sizeof(Float64)) { return kAudioHardwareBadPropertySizeError; }
                    Float64 theNewRate = *((const Float64*)inData);
                    if(!OpenAudio_IsSupportedSampleRate(theNewRate))
                    {
                        return kAudioHardwareIllegalOperationError;
                    }
                    pthread_mutex_lock(&gStateMutex);
                    Float64 theCurrentRate = gDevices[d].sampleRate;
                    pthread_mutex_unlock(&gStateMutex);
                    if(theNewRate != theCurrentRate)
                    {
                        /* Ask the host to schedule the change; the actual switch
                           happens in PerformDeviceConfigurationChange. */
                        if(gPlugIn_Host != NULL)
                        {
                            gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, OA_DeviceID(d), (UInt64)theNewRate, NULL);
                        }
                    }
                    theError = 0;
                    break;
                }
                default:
                    theError = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        case kObjectKind_StreamInput:
        case kObjectKind_StreamOutput:
            switch(inAddress->mSelector)
            {
                case kAudioStreamPropertyIsActive:
                {
                    if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
                    bool theActive = (*((const UInt32*)inData) != 0);
                    pthread_mutex_lock(&gStateMutex);
                    if(theKind == kObjectKind_StreamInput) { gDevices[d].inputStreamActive = theActive; }
                    else                                   { gDevices[d].outputStreamActive = theActive; }
                    pthread_mutex_unlock(&gStateMutex);
                    theChanged[theChangedCount].mSelector = kAudioStreamPropertyIsActive;
                    theChanged[theChangedCount].mScope = kAudioObjectPropertyScopeGlobal;
                    theChanged[theChangedCount].mElement = kAudioObjectPropertyElementMain;
                    ++theChangedCount;
                    theError = 0;
                    break;
                }
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                {
                    if(inDataSize < sizeof(AudioStreamBasicDescription)) { return kAudioHardwareBadPropertySizeError; }
                    const AudioStreamBasicDescription* theFormat = (const AudioStreamBasicDescription*)inData;
                    /* Only the sample rate is negotiable; the channel/format
                       shape is fixed. */
                    if((theFormat->mFormatID != kAudioFormatLinearPCM) ||
                       (theFormat->mChannelsPerFrame != kNumberOfChannels) ||
                       (theFormat->mBitsPerChannel != kBitsPerChannel) ||
                       !OpenAudio_IsSupportedSampleRate(theFormat->mSampleRate))
                    {
                        return kAudioHardwareIllegalOperationError;
                    }
                    pthread_mutex_lock(&gStateMutex);
                    Float64 theCurrentRate = gDevices[d].sampleRate;
                    pthread_mutex_unlock(&gStateMutex);
                    if(theFormat->mSampleRate != theCurrentRate)
                    {
                        if(gPlugIn_Host != NULL)
                        {
                            gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, OA_DeviceID(d), (UInt64)theFormat->mSampleRate, NULL);
                        }
                    }
                    theError = 0;
                    break;
                }
                default:
                    theError = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        case kObjectKind_Volume:
            switch(inAddress->mSelector)
            {
                case kAudioLevelControlPropertyScalarValue:
                {
                    if(inDataSize < sizeof(Float32)) { return kAudioHardwareBadPropertySizeError; }
                    Float32 theValue = *((const Float32*)inData);
                    if(theValue < 0.0f) { theValue = 0.0f; }
                    if(theValue > 1.0f) { theValue = 1.0f; }
                    pthread_mutex_lock(&gStateMutex);
                    gDevices[d].volumeValue = theValue;
                    pthread_mutex_unlock(&gStateMutex);
                    theChanged[theChangedCount].mSelector = kAudioLevelControlPropertyScalarValue; theChanged[theChangedCount].mScope = kAudioObjectPropertyScopeGlobal; theChanged[theChangedCount].mElement = kAudioObjectPropertyElementMain; ++theChangedCount;
                    theChanged[theChangedCount].mSelector = kAudioLevelControlPropertyDecibelValue; theChanged[theChangedCount].mScope = kAudioObjectPropertyScopeGlobal; theChanged[theChangedCount].mElement = kAudioObjectPropertyElementMain; ++theChangedCount;
                    theError = 0;
                    break;
                }
                case kAudioLevelControlPropertyDecibelValue:
                {
                    if(inDataSize < sizeof(Float32)) { return kAudioHardwareBadPropertySizeError; }
                    Float32 theValue = OpenAudio_VolumeDBToScalar(*((const Float32*)inData));
                    pthread_mutex_lock(&gStateMutex);
                    gDevices[d].volumeValue = theValue;
                    pthread_mutex_unlock(&gStateMutex);
                    theChanged[theChangedCount].mSelector = kAudioLevelControlPropertyScalarValue; theChanged[theChangedCount].mScope = kAudioObjectPropertyScopeGlobal; theChanged[theChangedCount].mElement = kAudioObjectPropertyElementMain; ++theChangedCount;
                    theChanged[theChangedCount].mSelector = kAudioLevelControlPropertyDecibelValue; theChanged[theChangedCount].mScope = kAudioObjectPropertyScopeGlobal; theChanged[theChangedCount].mElement = kAudioObjectPropertyElementMain; ++theChangedCount;
                    theError = 0;
                    break;
                }
                default:
                    theError = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        case kObjectKind_Mute:
            switch(inAddress->mSelector)
            {
                case kAudioBooleanControlPropertyValue:
                    if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
                    pthread_mutex_lock(&gStateMutex);
                    gDevices[d].muteValue = (*((const UInt32*)inData) != 0);
                    pthread_mutex_unlock(&gStateMutex);
                    theChanged[theChangedCount].mSelector = kAudioBooleanControlPropertyValue;
                    theChanged[theChangedCount].mScope = kAudioObjectPropertyScopeGlobal;
                    theChanged[theChangedCount].mElement = kAudioObjectPropertyElementMain;
                    ++theChangedCount;
                    theError = 0;
                    break;
                default:
                    theError = kAudioHardwareUnknownPropertyError;
                    break;
            }
            break;

        default:
            return kAudioHardwareBadObjectError;
    }

    if((theError == 0) && (theChangedCount > 0) && (gPlugIn_Host != NULL))
    {
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, inObjectID, theChangedCount, theChanged);
    }

    return theError;
}

/* ======================================================================== */
#pragma mark IO — StartIO / StopIO
/* ======================================================================== */

static OSStatus OpenAudio_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }

    UInt32 d = 0;
    if(OA_Resolve(inDeviceObjectID, true, &d) != kObjectKind_Device) { return kAudioHardwareBadObjectError; }

    OADevice* dev = &gDevices[d];

    pthread_mutex_lock(&gStateMutex);
    if(dev->ioRunningCount == 0)
    {
        /* First client: initialize the clock anchor and clear the ring so a
           fresh run starts from silence. */
        struct mach_timebase_info theTimeBaseInfo;
        mach_timebase_info(&theTimeBaseInfo);
        Float64 theHostClockFrequency = ((Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer) * 1000000000.0;
        dev->hostTicksPerFrame = theHostClockFrequency / dev->sampleRate;
        dev->anchorHostTime = mach_absolute_time();
        dev->numberTimeStamps = 0;
        memset(dev->ring, 0, kRingBufferBytes);
        dev->ioRunningCount = 1;
    }
    else
    {
        ++dev->ioRunningCount;
    }
    pthread_mutex_unlock(&gStateMutex);

    return 0;
}

static OSStatus OpenAudio_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }

    UInt32 d = 0;
    /* Tolerate a device that has just been unpublished (in-flight teardown). */
    if(OA_Resolve(inDeviceObjectID, false, &d) != kObjectKind_Device) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gStateMutex);
    if(gDevices[d].ioRunningCount > 0) { --gDevices[d].ioRunningCount; }
    pthread_mutex_unlock(&gStateMutex);

    return 0;
}

/* ======================================================================== */
#pragma mark IO — GetZeroTimeStamp (realtime-safe, no locks/allocs/syscalls)
/* ======================================================================== */

static OSStatus OpenAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }

    UInt32 d = 0;
    if(OA_Resolve(inDeviceObjectID, false, &d) != kObjectKind_Device) { return kAudioHardwareBadObjectError; }

    OADevice* dev = &gDevices[d];

    /* mach_absolute_time is a userspace read of the timebase register: no
       syscall, safe on the IO thread. This device's clock state is written only
       by its single IO thread once IO is running, so no lock is needed. */
    UInt64 theCurrentHostTime = mach_absolute_time();

    Float64 theHostTicksPerPeriod = dev->hostTicksPerFrame * (Float64)kZeroTimestampPeriod;

    /* Advance the anchor if a full period has elapsed since the last one. */
    UInt64 theNextTimeStampNumber = dev->numberTimeStamps + 1;
    UInt64 theNextAnchorHostTime = dev->anchorHostTime + (UInt64)((Float64)theNextTimeStampNumber * theHostTicksPerPeriod);
    if(theCurrentHostTime >= theNextAnchorHostTime)
    {
        ++dev->numberTimeStamps;
    }

    *outSampleTime = (Float64)(dev->numberTimeStamps * kZeroTimestampPeriod);
    *outHostTime = dev->anchorHostTime + (UInt64)((Float64)dev->numberTimeStamps * theHostTicksPerPeriod);
    *outSeed = 1;

    return 0;
}

/* ======================================================================== */
#pragma mark IO — operation negotiation and transfer
/* ======================================================================== */

static OSStatus OpenAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(OA_Resolve(inDeviceObjectID, false, NULL) != kObjectKind_Device) { return kAudioHardwareBadObjectError; }

    Boolean theWillDo = false;
    Boolean theWillDoInPlace = true;
    switch(inOperationID)
    {
        case kAudioServerPlugInIOOperationReadInput:
        case kAudioServerPlugInIOOperationWriteMix:
            theWillDo = true;
            theWillDoInPlace = true;
            break;
        default:
            theWillDo = false;
            theWillDoInPlace = true;
            break;
    }

    if(outWillDo != NULL)        { *outWillDo = theWillDo; }
    if(outWillDoInPlace != NULL) { *outWillDoInPlace = theWillDoInPlace; }
    return 0;
}

static OSStatus OpenAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(OA_Resolve(inDeviceObjectID, false, NULL) != kObjectKind_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

static OSStatus OpenAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    #pragma unused(inClientID, inStreamObjectID, ioSecondaryBuffer)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }

    UInt32 d = 0;
    if(OA_Resolve(inDeviceObjectID, false, &d) != kObjectKind_Device) { return kAudioHardwareBadObjectError; }
    if((ioMainBuffer == NULL) || (inIOBufferFrameSize == 0)) { return 0; }

    Float32* theRing = gDevices[d].ring;

    if(inOperationID == kAudioServerPlugInIOOperationWriteMix)
    {
        /* Copy the client's output samples into the ring, indexed by the
           output cycle's sample time. */
        const Float32* theSource = (const Float32*)ioMainBuffer;
        UInt64 theBaseFrame = (UInt64)inIOCycleInfo->mOutputTime.mSampleTime;
        for(UInt32 theFrame = 0; theFrame < inIOBufferFrameSize; ++theFrame)
        {
            UInt64 theRingFrame = (theBaseFrame + theFrame) & kRingBufferFrameMask;
            memcpy(&theRing[theRingFrame * kNumberOfChannels],
                   &theSource[(UInt64)theFrame * kNumberOfChannels],
                   kBytesPerFrame);
        }
    }
    else if(inOperationID == kAudioServerPlugInIOOperationReadInput)
    {
        /* Return the previously written samples from the ring, indexed by the
           input cycle's sample time (which lags output, giving the loopback
           its fixed latency). */
        Float32* theDest = (Float32*)ioMainBuffer;
        UInt64 theBaseFrame = (UInt64)inIOCycleInfo->mInputTime.mSampleTime;
        for(UInt32 theFrame = 0; theFrame < inIOBufferFrameSize; ++theFrame)
        {
            UInt64 theRingFrame = (theBaseFrame + theFrame) & kRingBufferFrameMask;
            memcpy(&theDest[(UInt64)theFrame * kNumberOfChannels],
                   &theRing[theRingFrame * kNumberOfChannels],
                   kBytesPerFrame);
        }
    }

    return 0;
}

static OSStatus OpenAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(OA_Resolve(inDeviceObjectID, false, NULL) != kObjectKind_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}
