//
//  ARAudioFileInfo.m
//  AudioStreamer
//
//  Created by Archer on 2017/6/2.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import "ARAudioFileInfo.h"
#import "ARAudioProvider.h"
#import <AudioToolbox/AudioFile.h>
#import <AudioToolbox/AudioFormat.h>

@interface ARAudioFileInfo ()
@property (nonatomic, strong) ARAudioProvider *fileProvider;
// 代表AudioFile对象
@property (nonatomic) AudioFileID audioFileID;
@end

@implementation ARAudioFileInfo

+ (instancetype)fileInfoWithProvider:(ARAudioProvider *)fileProvider
{
    return [[self alloc] initWithProvider:fileProvider];
}

- (instancetype)initWithProvider:(ARAudioProvider *)fileProvider
{
    self = [super init];
    if (self) {
        _fileProvider = fileProvider;
        [self _openAudioFile];
        [self _fillAudioInfo];
    }
    return self;
}

- (void)dealloc
{
    [self _closeAudioFile];
}

#pragma mark  --  properties

- (BOOL)isAvailable
{
    // AudioFile是否可用
    return _audioFileID != NULL;
}

- (NSData *)magicCookie
{
    if ([self isAvailable]) {
        // 获取magic cookie
        UInt32 cookieSize;
        OSStatus status = AudioFileGetPropertyInfo(_audioFileID, kAudioFilePropertyMagicCookieData, &cookieSize, NULL);
        if (status != noErr) {
            return nil;
        }
        
        void *cookieData = malloc(cookieSize);
        status = AudioFileGetProperty(_audioFileID, kAudioFilePropertyMagicCookieData, &cookieSize, cookieData);
        if (status != noErr) {
            return nil;
        }
        if (cookieData != NULL &&
            cookieSize > 0) {
            NSData *magicCookie = [NSData dataWithBytes:cookieData length:cookieSize];
            free(cookieData);
            return magicCookie;
        }
        
        return nil;
    }
    
    return nil;
}

#pragma mark  --  open AudioFile

- (void)_openAudioFile
{
    // 在不明确AudioFIleTypeID的情况下传0尝试初始化AudioFile，
    // 如果失败就去获取所有可能的AudioFileTypeID逐一尝试
    if (![self _openWithFileTypeHint:0] &&
        ![self _openWithFallbacks]) {
        _audioFileID = NULL;
    }
}

- (BOOL)_openWithFileTypeHint:(AudioFileTypeID)inFileTypeHint
{
    /** 
     初始化AudioFile，通过回调函数提供音频数据
    
     mAudioFile_ReadProc：在AudioFile需要音频数据的时候提供给它
     mAudioFile_GetSizeProc：告诉AudioFile总音频数据的大小（包括音频头信息和所以可播放的音频数据，dataOffset + audioDataByteCount）
    */
    OSStatus status = AudioFileOpenWithCallbacks((__bridge void * _Nonnull)(self), mAudioFile_ReadProc, NULL, mAudioFile_GetSizeProc, NULL, inFileTypeHint, &_audioFileID);
    return status == noErr;
}

- (BOOL)_openWithFallbacks
{
    // 用获取到的AudioFileTypeID逐一尝试
    NSArray *fallbackTypeIDs = [self _fallbackTypeIDs];
    for (NSNumber *typeIDNumber in fallbackTypeIDs) {
        AudioFileTypeID typeID = (AudioFileTypeID)[typeIDNumber unsignedLongValue];
        if ([self _openWithFileTypeHint:typeID]) {
            return YES;
        }
    }
    
    return NO;
}

- (NSArray *)_fallbackTypeIDs
{
    /** 
     kAudioFileGlobalInfo_TypesForMIMEType，通过给定的mimeType返回所有支持此类型的AudioFileTypeID组成的数组。
     因为是一个数组，我们并不知道大小，所以先调用AudioFileGetGlobalInfoSize()获取大小再调用AudioFileGetGlobalInfo()获取这些AudioFileTypeID
     kAudioFileGlobalInfo_TypesForExtension基本同上，不同之处是通过扩展名来找寻AudioFileTypeID
    */
    
    NSMutableArray *fallbackTypeIDs = [NSMutableArray array];
    NSMutableSet *fallbackTypeIDSet = [NSMutableSet set];
    
    struct {
        CFStringRef specifier;
        AudioFilePropertyID propertyID;
    } properties[] = {
        { (__bridge CFStringRef)[_fileProvider mimeType], kAudioFileGlobalInfo_TypesForMIMEType },
        { (__bridge CFStringRef)[_fileProvider fileExtension], kAudioFileGlobalInfo_TypesForExtension }
    };

    const size_t numberOfProperties = sizeof(properties) / sizeof(properties[0]);
    
    for (size_t i = 0; i < numberOfProperties; ++i) {
        if (properties[i].specifier == NULL) {
            continue;
        }
        
        UInt32 outSize = 0;
        OSStatus status = AudioFileGetGlobalInfoSize(properties[i].propertyID,
                                                     sizeof(properties[i].specifier),
                                                     &properties[i].specifier,
                                                     &outSize);
        if (status != noErr) {
            continue;
        }
        
        // 根据获取的大小分配适当的内存
        size_t count = outSize / sizeof(AudioFileTypeID);
        AudioFileTypeID *buffer = (AudioFileTypeID *)malloc(outSize);
        if (buffer == NULL) {
            continue;
        }
        
        status = AudioFileGetGlobalInfo(properties[i].propertyID,
                                        sizeof(properties[i].specifier),
                                        &properties[i].specifier,
                                        &outSize,
                                        buffer);
        if (status != noErr) {
            free(buffer);
            continue;
        }
        
        // set用来保证唯一性
        for (size_t j = 0; j < count; ++j) {
            NSNumber *tid = [NSNumber numberWithUnsignedLong:buffer[j]];
            if ([fallbackTypeIDSet containsObject:tid]) {
                continue;
            }
            
            [fallbackTypeIDs addObject:tid];
            [fallbackTypeIDSet addObject:tid];
        }
        
        free(buffer);
    }
    
    return [fallbackTypeIDs copy];
}

#pragma mark  --  fill audio info

- (void)_fillAudioInfo
{
    if (![self _fillFormatInfo] ||
        ![self _fillMiscInfo]) {
        [self _closeAudioFile];
    }
}

- (BOOL)_fillFormatInfo
{
    /**
     关于kAudioFilePropertyFormatList和kAudioFilePropertyDataFormat，
     这两个属性都可以获取到AudioStreamBasicDescription，区别在于
     kAudioFilePropertyDataFormat只能获取到最低级别的编码层级。
     
     例如对源文件采用AAC_HE_V2编码格式，44100KHz采样率、双声道，
     第一层:只支持22050，单声道，第二层，支持44100，单声道，第三层支持44100，双声道。
     在这种情况下，用kAudioFilePropertyDataFormat就取不到第三层的格式了，这时，就需要用kAudioFilePropertyFormatList来获取第三层的格式。
     */
    
    
    // 这个属性是为了支持AAC SBR类型的文件
    // kAudioFilePropertyFormatList返回的是AudioFormatListItem数组
    // 同样的，此时并不知道有多少个，所以先获取大小
    
    if (![self isAvailable]) return NO;
    
///=====================================================================
///     kAudioFilePropertyFormatList
///=====================================================================
    UInt32 size = 0;
    OSStatus status = AudioFileGetPropertyInfo(_audioFileID, kAudioFilePropertyFormatList, &size, NULL);
    if (status != noErr) {
        return NO;
    }
    
    // 分配好内存
    AudioFormatListItem *formatList = (AudioFormatListItem *)malloc(size);
    if (formatList == NULL) {
        return NO;
    }
    
    // 根据propertyID取值
    status = AudioFileGetProperty(_audioFileID, kAudioFilePropertyFormatList, &size, formatList);
    if (status != noErr) {
        free(formatList);
        return NO;
    }
    
    // 获取音频文件最高质量可播放格式
    UInt32 itemIndex;
    UInt32 indexSize = sizeof(itemIndex);
    
    //获取第一个可播放格式的索引号,此索引号将用于获取能够播放的最高质量层
    status = AudioFormatGetProperty(kAudioFormatProperty_FirstPlayableFormatFromList, size, formatList, &indexSize, &itemIndex);
    if (status != noErr) {
        free(formatList);
        return NO;
    }
    
    // 此时formatList[itemIndex]就是质量最高的可播放层了
    _highFormat = formatList[itemIndex].mASBD;
    free(formatList);
    
///=====================================================================
///     kAudioFilePropertyDataFormat
///=====================================================================
    // 获取基本的format
    AudioStreamBasicDescription baseFormat = {};
    size = sizeof(baseFormat);
    status = AudioFileGetProperty(_audioFileID, kAudioFilePropertyDataFormat, &size, &baseFormat);
    if (status != noErr) {
        return NO;
    }
    _baseFormat = baseFormat;
    
    return YES;
}

- (BOOL)_fillMiscInfo
{
    if (![self isAvailable]) return NO;

    UInt32 size;
    OSStatus status;
        
    // 获取音频文件头大小（除去真正音频数据的部分）
    SInt64 dataOffset = 0;
    size = sizeof(dataOffset);
    status = AudioFileGetProperty(_audioFileID, kAudioFilePropertyDataOffset, &size, &dataOffset);
    if (status != noErr) {
        return NO;
    }
    _dataOffset = (NSUInteger)dataOffset;
    
    // 获取音频总时长,单位秒
    Float64 estimatedDuration = 0.0;
    size = sizeof(estimatedDuration);
    status = AudioFileGetProperty(_audioFileID, kAudioFilePropertyEstimatedDuration, &size, &estimatedDuration);
    if (status != noErr) {
        return NO;
    }
    _estimatedDuration = estimatedDuration;
    
    return YES;
}

#pragma mark  --  close AudioFile

- (void)_closeAudioFile
{
    if ([self isAvailable]) {
        AudioFileClose(_audioFileID);
        _audioFileID = NULL;
    }
}

#pragma mark  --  callbacks

/**
 此回调调用的时间点有两个：
 1、AudioFileReadXXX()相关方法，读取音频数据时当然要提供了~~
 2、在调用AudioFileOpenWithCallbacks()初始化AudioFile时就会被调用，此时需要提供足够的音频数据给AudioFile让它确定音频数据的完整性，若是数据不足AudioFileOpenWithCallbacks()就会失败。也就是说，AudioFileOpenWithCallbacks()一旦调用成功，就和AudioFileStream解析音频信息得到kAudioFileStreamProperty_ReadyToProducePackets标志一样。因此在流播时，先用AudioFileStream解析得到ReadyToProducePackets标志，再使用AudioFile相关API就没有问题。
 */
static OSStatus mAudioFile_ReadProc(
                                    void *		inClientData,
                                    SInt64		inPosition,
                                    UInt32		requestCount,
                                    void *		buffer,
                                    UInt32 *	actualCount)
{
    ARAudioFileInfo *fileInfo = (__bridge ARAudioFileInfo *)(inClientData);
    return [fileInfo _hadnleAudioFileReadProcInPosition:inPosition requestCount:requestCount buffer:buffer actualCount:actualCount];
}

- (OSStatus)_hadnleAudioFileReadProcInPosition:(SInt64)inPosition
                                  requestCount:(UInt32)requestCount
                                        buffer:(void *)buffer
                                   actualCount:(UInt32 *)actualCount
{
    /**
     以下均已字节计。
     参数inPosition是从音频数据的哪个位置开始读；
     参数requestCount是要读取的音频数据长度，不是最后读取的量；
     参数buffer用来装载读取的音频数据；
     参数actualCount需要我们设置成真正读取的数据量。
     
     这里解释以下为什么需要我们设置actualCount。
     1、没有充足数据：在流播时，限于网速等外界因素，回调时可能数据不足，此时就只有把手头有的数据拷贝到buffer，最后返回noErr，那么actualCount的大小就是实际拷贝的数据长度。
     2、有充足数据：把从inPosition开始requestCount长度的连续字节拷贝到buffer，这种情况actualCount就等于requestCount，最后返回noErr。
     注意一下actualCount若是等于0是EOF标志。
     */
    
    // 如果需要读取的长度超过拥有的数据长度
    if (inPosition + requestCount > [[self.fileProvider mappedData] length]) {
        // 如果读取起点的位置已经超过或等于拥有的数据长度了
        if (inPosition >= [[self.fileProvider mappedData] length]) {
            // 此时真正读取长度就没有了
            *actualCount = 0;
        }else{
            // 否则总共拥有的数据长度减去起点就是能读到的所有数据了
            *actualCount = (UInt32)([[self.fileProvider mappedData] length] - inPosition);
        }
    }else{
        // 若是不比拥有的数据长度大
        // 真正读取的就是请求的长度
        *actualCount = requestCount;
    }
    
    // EOF
    if (*actualCount == 0) return noErr;
    
    // buffer的内存已经分配
    // 最后将映射数据内存inPosition位置，长度为actualCount的数据 拷贝到 buffer中
    memcpy(buffer, (uint8_t *)[[self.fileProvider mappedData] bytes] + inPosition, *actualCount);
    
    return noErr;
}

static SInt64 mAudioFile_GetSizeProc(void *inClientData)
{
    ARAudioFileInfo *fileInfo = (__bridge ARAudioFileInfo *)(inClientData);
    // mappedData的长度就是音频文件的总长
    return [fileInfo.fileProvider.mappedData length];
}

@end
