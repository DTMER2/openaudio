/*
 * OpenAudioDriver.c
 *
 * OpenAudio 16-channel loopback virtual audio device.
 *
 * A minimal but complete AudioServerPlugIn (Core Audio HAL plugin) that
 * publishes a single virtual device presenting 16 input and 16 output
 * channels of native-packed Float32 PCM. Samples written to the output
 * stream are pushed into a lock-free ring buffer and returned on the input
 * stream, forming a bit-exact loopback bus.
 *
 * This file is an original implementation of the published
 * AudioServerPlugInDriverInterface. It follows the same COM-style plugin
 * architecture that Apple documents in its NullAudio.c sample, but shares no
 * code with that sample or with any GPL-licensed driver (e.g. BlackHole).
 *
 * Realtime discipline: the IO entry points (GetZeroTimeStamp,
 * BeginIOOperation, DoIOOperation, EndIOOperation, WillDoIOOperation) perform
 * no allocation, no locking, no syscalls and touch no Objective-C. All memory
 * is allocated once at plugin load. State-change locking (a plain
 * pthread_mutex) is used ONLY outside the IO path.
 */

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

#define kDevice_Name                    "OpenAudio 16ch"
#define kDevice_Manufacturer            "OpenAudio"
#define kDevice_UID                     "OpenAudioDevice-1"
#define kDevice_ModelUID                "OpenAudioDevice-Model-1"
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

/* Supported nominal sample rates. */
static const Float64 kSupportedSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
enum { kNumberOfSupportedSampleRates = 4 };
#define kDefaultSampleRate              48000.0

/* Volume control range in decibels. */
#define kVolume_MinDB                   (-96.0f)
#define kVolume_MaxDB                   (0.0f)

/* ======================================================================== */
#pragma mark Object IDs
/* ======================================================================== */

enum
{
    kObjectID_PlugIn                    = kAudioObjectPlugInObject, /* == 1 */
    kObjectID_Box                       = 2,
    kObjectID_Device                    = 3,
    kObjectID_Stream_Input              = 4,
    kObjectID_Stream_Output             = 5,
    kObjectID_Volume_Output_Master      = 6,
    kObjectID_Mute_Output_Master        = 7
};

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

/* Device configuration state (guarded by gStateMutex for writers). */
static Float64                              gDevice_SampleRate                      = kDefaultSampleRate;
static UInt64                               gDevice_IORunningCount                  = 0;
static bool                                 gStream_Input_Active                    = true;
static bool                                 gStream_Output_Active                   = true;

/* Control state. */
static Float32                              gVolume_Output_Master_Value             = 1.0f;
static bool                                 gMute_Output_Master_Value               = false;

/* Ring buffer (interleaved Float32, [frame*channels + channel]). Allocated at
   load time; the IO path only reads/writes it. */
static Float32                              gRingBuffer[kRingBufferFrameSize * kNumberOfChannels];

/* Clock anchor for GetZeroTimeStamp. Written on the IO thread only. */
static Float64                              gDevice_HostTicksPerFrame               = 0.0;
static UInt64                               gDevice_AnchorHostTime                  = 0;
static UInt64                               gDevice_NumberTimeStamps                = 0;

/* ======================================================================== */
#pragma mark Small helpers
/* ======================================================================== */

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

    /* Ring buffer lives in BSS and is therefore already zero-initialized; make
       the intent explicit and cover any hypothetical re-initialization. */
    memset(gRingBuffer, 0, sizeof(gRingBuffer));

    gDevice_SampleRate = kDefaultSampleRate;
    gDevice_IORunningCount = 0;
    gBox_Acquired = true;

    return 0;
}

static OSStatus OpenAudio_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    #pragma unused(inDescription, inClientInfo, outDeviceObjectID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    /* We publish a single static device; dynamic creation is not supported. */
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
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

static OSStatus OpenAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    #pragma unused(inClientInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

static OSStatus OpenAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inChangeInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    /* The only configuration change we request is a sample-rate change, where
       inChangeAction carries the new rate. */
    Float64 theNewRate = (Float64)inChangeAction;
    if(!OpenAudio_IsSupportedSampleRate(theNewRate))
    {
        return kAudioHardwareIllegalOperationError;
    }

    pthread_mutex_lock(&gStateMutex);
    gDevice_SampleRate = theNewRate;
    pthread_mutex_unlock(&gStateMutex);

    return 0;
}

static OSStatus OpenAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inChangeAction, inChangeInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
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

    switch(inObjectID)
    {
        case kObjectID_PlugIn:                   return PlugIn_HasProperty(inAddress->mSelector);
        case kObjectID_Box:                      return Box_HasProperty(inAddress->mSelector);
        case kObjectID_Device:                   return Device_HasProperty(inAddress->mSelector);
        case kObjectID_Stream_Input:             return Stream_HasProperty(inAddress->mSelector);
        case kObjectID_Stream_Output:            return Stream_HasProperty(inAddress->mSelector);
        case kObjectID_Volume_Output_Master:     return Volume_HasProperty(inAddress->mSelector);
        case kObjectID_Mute_Output_Master:       return Mute_HasProperty(inAddress->mSelector);
        default:                                 return false;
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
    switch(inObjectID)
    {
        case kObjectID_Box:
            theSettable = (inAddress->mSelector == kAudioObjectPropertyName) ||
                          (inAddress->mSelector == kAudioObjectPropertyIdentify) ||
                          (inAddress->mSelector == kAudioBoxPropertyAcquired);
            break;

        case kObjectID_Device:
            theSettable = (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate);
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            theSettable = (inAddress->mSelector == kAudioStreamPropertyIsActive) ||
                          (inAddress->mSelector == kAudioStreamPropertyVirtualFormat) ||
                          (inAddress->mSelector == kAudioStreamPropertyPhysicalFormat);
            break;

        case kObjectID_Volume_Output_Master:
            theSettable = (inAddress->mSelector == kAudioLevelControlPropertyScalarValue) ||
                          (inAddress->mSelector == kAudioLevelControlPropertyDecibelValue);
            break;

        case kObjectID_Mute_Output_Master:
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

    switch(inObjectID)
    {
        /* ---- PlugIn ---- */
        case kObjectID_PlugIn:
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:                     *outDataSize = sizeof(AudioClassID); return 0;
                case kAudioObjectPropertyOwner:                     *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioObjectPropertyManufacturer:              *outDataSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyOwnedObjects:              *outDataSize = 2 * sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyBoxList:                   *outDataSize = 1 * sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyTranslateUIDToBox:         *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyDeviceList:                *outDataSize = 1 * sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyTranslateUIDToDevice:      *outDataSize = sizeof(AudioObjectID); return 0;
                case kAudioPlugInPropertyResourceBundle:            *outDataSize = sizeof(CFStringRef); return 0;
                default:                                            return kAudioHardwareUnknownPropertyError;
            }

        /* ---- Box ---- */
        case kObjectID_Box:
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
                case kAudioBoxPropertyDeviceList:                   *outDataSize = (gBox_Acquired ? 1 : 0) * sizeof(AudioObjectID); return 0;
                default:                                            return kAudioHardwareUnknownPropertyError;
            }

        /* ---- Device ---- */
        case kObjectID_Device:
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
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
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
        case kObjectID_Volume_Output_Master:
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
        case kObjectID_Mute_Output_Master:
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
            AudioObjectID theItems[2] = { kObjectID_Box, kObjectID_Device };
            UInt32 theMax = inDataSize / sizeof(AudioObjectID);
            UInt32 theCount = (theMax < 2) ? theMax : 2;
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
            REQUIRE_SIZE(sizeof(AudioObjectID));
            *((AudioObjectID*)outData) = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
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
            if((theUID != NULL) && (CFStringCompare(theUID, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo))
            {
                theID = kObjectID_Device;
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
                REQUIRE_SIZE(sizeof(AudioObjectID));
                *((AudioObjectID*)outData) = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
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

static OSStatus GetDevicePropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
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
            *((CFStringRef*)outData) = CFSTR(kDevice_Name);
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyManufacturer:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer);
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyModelName:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = CFSTR(kDevice_Name);
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioObjectPropertyOwnedObjects:
        {
            AudioObjectID theItems[4] = { kObjectID_Stream_Input, kObjectID_Stream_Output, kObjectID_Volume_Output_Master, kObjectID_Mute_Output_Master };
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
            *((CFStringRef*)outData) = CFSTR(kDevice_UID);
            *outDataSize = sizeof(CFStringRef);
            return 0;

        case kAudioDevicePropertyModelUID:
            REQUIRE_SIZE(sizeof(CFStringRef));
            *((CFStringRef*)outData) = CFSTR(kDevice_ModelUID);
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
            *((AudioObjectID*)outData) = kObjectID_Device;
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
            *((UInt32*)outData) = (gDevice_IORunningCount > 0) ? 1 : 0;
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
                theItems[theCount++] = kObjectID_Stream_Input;
            }
            if((inAddress->mScope == kAudioObjectPropertyScopeGlobal) || (inAddress->mScope == kAudioObjectPropertyScopeOutput))
            {
                theItems[theCount++] = kObjectID_Stream_Output;
            }
            UInt32 theMax = inDataSize / sizeof(AudioObjectID);
            if(theCount > theMax) { theCount = theMax; }
            memcpy(outData, theItems, theCount * sizeof(AudioObjectID));
            *outDataSize = theCount * sizeof(AudioObjectID);
            return 0;
        }

        case kAudioObjectPropertyControlList:
        {
            AudioObjectID theItems[2] = { kObjectID_Volume_Output_Master, kObjectID_Mute_Output_Master };
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
            *((Float64*)outData) = gDevice_SampleRate;
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

static OSStatus GetStreamPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    bool theIsInput = (inObjectID == kObjectID_Stream_Input);

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
            *((AudioObjectID*)outData) = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return 0;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return 0;

        case kAudioStreamPropertyIsActive:
            REQUIRE_SIZE(sizeof(UInt32));
            pthread_mutex_lock(&gStateMutex);
            *((UInt32*)outData) = (theIsInput ? gStream_Input_Active : gStream_Output_Active) ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(UInt32);
            return 0;

        case kAudioStreamPropertyDirection:
            REQUIRE_SIZE(sizeof(UInt32));
            *((UInt32*)outData) = theIsInput ? 1 : 0;
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
            Float64 theRate = gDevice_SampleRate;
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

static OSStatus GetVolumePropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
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
            *((AudioObjectID*)outData) = kObjectID_Device;
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
            *((Float32*)outData) = gVolume_Output_Master_Value;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(Float32);
            return 0;

        case kAudioLevelControlPropertyDecibelValue:
            REQUIRE_SIZE(sizeof(Float32));
            pthread_mutex_lock(&gStateMutex);
            *((Float32*)outData) = OpenAudio_VolumeScalarToDB(gVolume_Output_Master_Value);
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

static OSStatus GetMutePropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
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
            *((AudioObjectID*)outData) = kObjectID_Device;
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
            *((UInt32*)outData) = gMute_Output_Master_Value ? 1 : 0;
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

    switch(inObjectID)
    {
        case kObjectID_PlugIn:                   return GetPlugInPropertyData(inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
        case kObjectID_Box:                      return GetBoxPropertyData(inAddress, inDataSize, outDataSize, outData);
        case kObjectID_Device:                   return GetDevicePropertyData(inAddress, inDataSize, outDataSize, outData);
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:            return GetStreamPropertyData(inObjectID, inAddress, inDataSize, outDataSize, outData);
        case kObjectID_Volume_Output_Master:     return GetVolumePropertyData(inAddress, inDataSize, outDataSize, outData);
        case kObjectID_Mute_Output_Master:       return GetMutePropertyData(inAddress, inDataSize, outDataSize, outData);
        default:                                 return kAudioHardwareBadObjectError;
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

    switch(inObjectID)
    {
        case kObjectID_Box:
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

        case kObjectID_Device:
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
                    Float64 theCurrentRate = gDevice_SampleRate;
                    pthread_mutex_unlock(&gStateMutex);
                    if(theNewRate != theCurrentRate)
                    {
                        /* Ask the host to schedule the change; the actual switch
                           happens in PerformDeviceConfigurationChange. */
                        if(gPlugIn_Host != NULL)
                        {
                            gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, kObjectID_Device, (UInt64)theNewRate, NULL);
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

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch(inAddress->mSelector)
            {
                case kAudioStreamPropertyIsActive:
                {
                    if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
                    bool theActive = (*((const UInt32*)inData) != 0);
                    pthread_mutex_lock(&gStateMutex);
                    if(inObjectID == kObjectID_Stream_Input) { gStream_Input_Active = theActive; }
                    else                                     { gStream_Output_Active = theActive; }
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
                    Float64 theCurrentRate = gDevice_SampleRate;
                    pthread_mutex_unlock(&gStateMutex);
                    if(theFormat->mSampleRate != theCurrentRate)
                    {
                        if(gPlugIn_Host != NULL)
                        {
                            gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, kObjectID_Device, (UInt64)theFormat->mSampleRate, NULL);
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

        case kObjectID_Volume_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioLevelControlPropertyScalarValue:
                {
                    if(inDataSize < sizeof(Float32)) { return kAudioHardwareBadPropertySizeError; }
                    Float32 theValue = *((const Float32*)inData);
                    if(theValue < 0.0f) { theValue = 0.0f; }
                    if(theValue > 1.0f) { theValue = 1.0f; }
                    pthread_mutex_lock(&gStateMutex);
                    gVolume_Output_Master_Value = theValue;
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
                    gVolume_Output_Master_Value = theValue;
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

        case kObjectID_Mute_Output_Master:
            switch(inAddress->mSelector)
            {
                case kAudioBooleanControlPropertyValue:
                    if(inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
                    pthread_mutex_lock(&gStateMutex);
                    gMute_Output_Master_Value = (*((const UInt32*)inData) != 0);
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
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gStateMutex);
    if(gDevice_IORunningCount == 0)
    {
        /* First client: initialize the clock anchor and clear the ring so a
           fresh run starts from silence. */
        struct mach_timebase_info theTimeBaseInfo;
        mach_timebase_info(&theTimeBaseInfo);
        Float64 theHostClockFrequency = ((Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer) * 1000000000.0;
        gDevice_HostTicksPerFrame = theHostClockFrequency / gDevice_SampleRate;
        gDevice_AnchorHostTime = mach_absolute_time();
        gDevice_NumberTimeStamps = 0;
        memset(gRingBuffer, 0, sizeof(gRingBuffer));
        gDevice_IORunningCount = 1;
    }
    else
    {
        ++gDevice_IORunningCount;
    }
    pthread_mutex_unlock(&gStateMutex);

    return 0;
}

static OSStatus OpenAudio_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gStateMutex);
    if(gDevice_IORunningCount > 0) { --gDevice_IORunningCount; }
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
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    /* mach_absolute_time is a userspace read of the timebase register: no
       syscall, safe on the IO thread. gDevice_* clock state is written only by
       this single IO thread once IO is running, so no lock is needed. */
    UInt64 theCurrentHostTime = mach_absolute_time();

    Float64 theHostTicksPerPeriod = gDevice_HostTicksPerFrame * (Float64)kZeroTimestampPeriod;

    /* Advance the anchor if a full period has elapsed since the last one. */
    UInt64 theNextTimeStampNumber = gDevice_NumberTimeStamps + 1;
    UInt64 theNextAnchorHostTime = gDevice_AnchorHostTime + (UInt64)((Float64)theNextTimeStampNumber * theHostTicksPerPeriod);
    if(theCurrentHostTime >= theNextAnchorHostTime)
    {
        ++gDevice_NumberTimeStamps;
    }

    *outSampleTime = (Float64)(gDevice_NumberTimeStamps * kZeroTimestampPeriod);
    *outHostTime = gDevice_AnchorHostTime + (UInt64)((Float64)gDevice_NumberTimeStamps * theHostTicksPerPeriod);
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
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

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
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

static OSStatus OpenAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    #pragma unused(inClientID, inStreamObjectID, ioSecondaryBuffer)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    if((ioMainBuffer == NULL) || (inIOBufferFrameSize == 0)) { return 0; }

    if(inOperationID == kAudioServerPlugInIOOperationWriteMix)
    {
        /* Copy the client's output samples into the ring, indexed by the
           output cycle's sample time. */
        const Float32* theSource = (const Float32*)ioMainBuffer;
        UInt64 theBaseFrame = (UInt64)inIOCycleInfo->mOutputTime.mSampleTime;
        for(UInt32 theFrame = 0; theFrame < inIOBufferFrameSize; ++theFrame)
        {
            UInt64 theRingFrame = (theBaseFrame + theFrame) & kRingBufferFrameMask;
            memcpy(&gRingBuffer[theRingFrame * kNumberOfChannels],
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
                   &gRingBuffer[theRingFrame * kNumberOfChannels],
                   kBytesPerFrame);
        }
    }

    return 0;
}

static OSStatus OpenAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}
