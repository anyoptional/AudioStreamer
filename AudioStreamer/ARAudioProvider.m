//
//  ARAudioProvider.m
//  AudioStreamer
//
//  Created by Archer on 2017/6/2.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import "ARAudioProvider.h"
#import "ARAudioDownloader.h"
#import "NSData+ARMappedFile.h"
#import <MobileCoreServices/UTType.h>
#import <CommonCrypto/CommonDigest.h>
#import <AVFoundation/AVFoundation.h>

@interface ARAudioProvider ()
{
    // 定义成protected，方便子类直接访问
    @protected
    
    id <ARAudioFile> _audioFile;
    ARAudioProviderEventBlock _eventBlock;
    NSString *_cachedPath;
    NSUInteger _expectedLength;
    NSUInteger _receivedLength;
    NSString *_fileExtension;
    NSString *_mimeType;
    NSData *_mappedData;
    BOOL _failed;
    NSUInteger _downloadSpeed;
}

- (instancetype)initWithAudioFile:(id<ARAudioFile>)audioFile;
@end


///=====================================================================
///     本地音频的数据源
///=====================================================================
@interface _ARLocalAudioProvider : ARAudioProvider

@end

@implementation _ARLocalAudioProvider

- (instancetype)initWithAudioFile:(id<ARAudioFile>)audioFile
{
    self = [super initWithAudioFile:audioFile];
    if (self) {
        _cachedPath = [[audioFile audioURL] path];
        _fileExtension = [_cachedPath pathExtension];
        
        // 判断一下文件是否真实存在
        BOOL isDirectory = YES;
        BOOL isExists = [[NSFileManager defaultManager] fileExistsAtPath:_cachedPath isDirectory:&isDirectory];
        // 如果文件不存在 或者 给定的路径是文件夹，返回nil
        if (!isExists || isDirectory) return nil;
        
        // 获取映射的数据。对于本地音频来说，就是整个音频数据
        _mappedData = [NSData yo_dataWithMappedContentsOfFile:_cachedPath];
        
        _expectedLength = [_mappedData length];
        _receivedLength = _expectedLength;
    }
    return self;
}

// 获取文件的mimeType
- (NSString *)mimeType
{
    if (!_mimeType && _fileExtension ) {
        // fileExtension --> UTType
        CFStringRef utType = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)_fileExtension, NULL);
        if (utType != NULL) {
            // UTType --> mimeType
            _mimeType = CFBridgingRelease(UTTypeCopyPreferredTagWithClass(utType, kUTTagClassMIMEType));
            CFRelease(utType);
        }
    }
    return _mimeType;
}

/// Override methods
// 对本地本文来讲，这几个属性一目了然
- (NSUInteger)downloadSpeed
{
    return _receivedLength;
}

- (BOOL)isReady
{
    return YES;
}

- (BOOL)isFinished
{
    return YES;
}

@end

///========================================================================
/// iPod音乐
///========================================================================
@interface _ARiPodAudioProvider : ARAudioProvider
// 用来导出iPod中的音频
@property (nonatomic, strong) AVAssetExportSession *exportSession;
// 导出是否已经完成
@property (nonatomic, assign) BOOL exportComplete;
@end

@implementation _ARiPodAudioProvider

- (instancetype)initWithAudioFile:(id<ARAudioFile>)audioFile
{
    self = [super initWithAudioFile:audioFile];
    if (self) {
        // 开始导出音频
        [self _startExporting];
    }
    return self;
}

- (void)dealloc
{
    @synchronized(self) {
        // 取消导出
        [self _cancelExporting];
    }
    [[NSFileManager defaultManager] removeItemAtPath:[self cachedPath]
                                               error:NULL];
}

- (void)_startExporting
{
    if (_exportSession) return;
    
    AVURLAsset *asset = [AVURLAsset assetWithURL:[_audioFile audioURL]];
    // 如果初始化失败
    if (!asset) {
        _failed = YES;
        return;
    }
    // 创建 exportSession，准备导出音频
    _exportSession = [AVAssetExportSession exportSessionWithAsset:asset
                                                       presetName:AVAssetExportPresetPassthrough];
    if (_exportSession == nil) {
        _failed = YES;
        return;
    }
    // 设置输出格式为.caf
    [_exportSession setOutputFileType:AVFileTypeCoreAudioFormat];
    // 设置导出的路径
    [_exportSession setOutputURL:[NSURL fileURLWithPath:[self cachedPath]]];
    
    __weak typeof(self) weakSelf = self;
    [_exportSession exportAsynchronouslyWithCompletionHandler:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf _exportSessionDidFinishExporting];
    }];
}

- (void)_cancelExporting
{
    if (!_exportSession) return;
    
    [_exportSession cancelExport];
    _exportSession = nil;
}

- (void)_exportSessionDidFinishExporting
{
    // 如果导出失败
    if ([_exportSession status] != AVAssetExportSessionStatusCompleted ||
        [_exportSession error] != nil) {
        _failed = YES;
        return;
    }
    
    // mmap 映射的数据
    _mappedData = [NSData yo_dataWithMappedContentsOfFile:_cachedPath];
    _expectedLength = [_mappedData length];
    _receivedLength = [_mappedData length];
    
    if (_eventBlock) {
        _eventBlock();
    }
}

- (NSString *)mimeType
{
    return AVFileTypeCoreAudioFormat;
}

- (NSString *)fileExtension
{
    return @"caf";
}

- (NSString *)cachedPath
{
    if (!_cachedPath) {
        // 设置导出位置
        NSString *filename = [NSString stringWithFormat:@"archer-%@.%@", sha256ForURL([_audioFile audioURL]), [self fileExtension]];
        _cachedPath = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:_cachedPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:_cachedPath error:NULL];
        }
    }
    return _cachedPath;
}

static inline NSString *sha256ForURL(NSURL *url)
{
    NSString *string = [url absoluteString];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256([string UTF8String], (CC_LONG)[string lengthOfBytesUsingEncoding:NSUTF8StringEncoding], hash);
    
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
        [result appendFormat:@"%02x", hash[i]];
    }
    
    return result;
}

- (NSUInteger)downloadSpeed
{
    return _receivedLength;
}

- (BOOL)isReady
{
    return !_failed;
}

- (BOOL)isFinished
{
    return !_failed;
}

@end

///========================================================================
/// 云音乐
///========================================================================
@interface _ARRemoteAudioProvider : ARAudioProvider
@property (nonatomic, strong) ARAudioDownloader *audioDownloder;
@property (nonatomic, strong) NSURL *audioURL;
@property (nonatomic, assign) AudioFileStreamID audioFileStreamID;
// 有些音频不能用于流播，只能下载完整个文件才能播放
@property (nonatomic, assign) BOOL requiresCompleteFile;
@property (nonatomic, assign) BOOL readyToProducePackets;
@property (nonatomic, getter=isFinished, assign) BOOL finished;
@end

@implementation _ARRemoteAudioProvider
@synthesize finished = _requestCompleted;

- (instancetype)initWithAudioFile:(id<ARAudioFile>)audioFile
{
    if (self = [super initWithAudioFile:audioFile]) {
        _audioURL = [audioFile audioURL];
        if (![self _openAudioFileStream]) return nil;
        [self _buildAudioDownloder];
        [_audioDownloder start];
    }
    return self;
}

- (BOOL)_openAudioFileStream
{
    // AudioFileTypeID 不清楚时传入0
    return [self _openAudioFileStreamWithFileTypeHint:0];
}

- (BOOL)_openAudioFileStreamWithFileTypeHint:(AudioFileTypeID)inFileTypeHint
{
    OSStatus status = AudioFileStreamOpen((__bridge void * _Nullable)(self), ARAudioFileStream_PropertyListenerProc, ARAudioFileStream_PacketsProc, inFileTypeHint, &_audioFileStreamID);
    if (status != noErr) {
        _audioFileStreamID = NULL;
        return NO;
    }
    return YES;
}

- (void)_closeAudioFileStream
{
    if (_audioFileStreamID != NULL) {
        AudioFileStreamClose(_audioFileStreamID);
        _audioFileStreamID = NULL;
    }
}

- (void)_buildAudioDownloder
{
    _audioDownloder = [ARAudioDownloader loaderWithAudioURL:_audioURL];
    
    [_audioDownloder updateDidReceiveResponseBlock:^{
        [self _downloderDidRecieveResponse];
    }];
    [_audioDownloder updateDidRecievedDataBlock:^(NSData *data) {
        [self _downloaderDidRecieveData:data];
    }];
    [_audioDownloder updateProgressBlock:^(double downloadProgress) {
        [self _downloaderDidUpdateProgress:downloadProgress];
    }];
    [_audioDownloder updateCompletedBlock:^{
        [self _downloderDidFinishLoading];
    }];
}

- (void)_downloderDidRecieveResponse
{
    // 获取文件长度
    _expectedLength = [_audioDownloder responseContentLength];
    // 缓存目录
    _cachedPath = [self _cachedPathForAudioURL:_audioURL];
    // 在缓存目录创建文件
    [[NSFileManager defaultManager] createFileAtPath:_cachedPath contents:nil attributes:nil];
    // 保证在锁屏状态下仍可缓冲音频
    [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone}
                                     ofItemAtPath:_cachedPath
                                            error:NULL];
    // 设置缓存大小为音频大小
    [[NSFileHandle fileHandleForWritingAtPath:_cachedPath] truncateFileAtOffset:_expectedLength];
    
    // 获取音频的MIMEType
    _mimeType = [[_audioDownloder responseHeaders] objectForKey:@"Content-Type"];
    // 获取音频的映射数据
    _mappedData = [NSData yo_modifiableDataWithMappedContentsOfFile:_cachedPath];
}

- (NSString *)_cachedPathForAudioURL:(NSURL *)audioURL
{
    NSString *filename = [NSString stringWithFormat:@"Archer-remote.tmp"];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
}

- (void)_downloaderDidRecieveData:(NSData *)data
{
    // 映射失败,返回
    if (!_mappedData) return;
    
    // 剩余的数据长度
    NSUInteger spaceRemaining = _expectedLength - _receivedLength;
    // 本次写入的数据长度
    NSUInteger bytesToWrite = MIN(spaceRemaining, [data length]);
    
    // [_mappedData bytes] mmap映射的bytes的首地址
    // 加上 _receivedLength，相当于地址偏移sizeOf(Char)+_receivedLength
    // 往里面写的数据是返回的data
    // 数据长度是bytesToWrite 如果bytesToWrite < data.length,data会被截断，只cpybytesToWrite长度
    memcpy((uint8_t *)[_mappedData bytes] + _receivedLength, [data bytes], bytesToWrite);
    // 接收的数据长度累加
    _receivedLength += bytesToWrite;
    
    // 开始解析音频数据
    if (!_readyToProducePackets && !_failed && !_requiresCompleteFile) {
        // 首先确定音频格式
        OSStatus status = kAudioFileStreamError_UnsupportedFileType;
        if (_audioFileStreamID != NULL) {
            // 解析数据
            status = AudioFileStreamParseBytes(_audioFileStreamID, (UInt32)[data length], [data bytes], 0);
        }
        
        // 若不是因为无法流播导致的错误
        if (status != noErr && status != kAudioFileStreamError_NotOptimized) {
            // 获取音频文件类型
            NSArray *fallbackTypeIDs = [self _fallbackTypeIDs];
            for (NSNumber *fileTypeIDNumber in fallbackTypeIDs) {
                // 取出类型
                AudioFileTypeID typeID = (AudioFileTypeID)[fileTypeIDNumber unsignedLongLongValue];
                // 用已经确定的类型再次尝试
                [self _closeAudioFileStream];
                [self _openAudioFileStreamWithFileTypeHint:typeID];
                // 重新解析已经接收到的数据
                if (_audioFileStreamID != NULL) {
                    status = AudioFileStreamParseBytes(_audioFileStreamID, (UInt32)_receivedLength, [_mappedData bytes], 0);
                    // 若一切正常或此音频无法流播
                    if (status == noErr ||
                        status == kAudioFileStreamError_NotOptimized) {
                        break;
                    }
                }
            }
            // 若是出错
            if (status != noErr &&
                status != kAudioFileStreamError_NotOptimized) {
                _failed = YES;
            }
        }
        // 确定音频文件无法流播
        if (status == kAudioFileStreamError_NotOptimized) {
            [self _closeAudioFileStream];
            _requiresCompleteFile = YES;
        }
    }
}

- (NSArray *)_fallbackTypeIDs
{
    NSMutableArray *fallbackTypeIDArray = [NSMutableArray array];
    NSMutableSet *fallbackTypeIDSet = [NSMutableSet set];
    
    // 类型对应的propertyID
    struct {
        CFStringRef specifier;
        AudioFilePropertyID propertyID;
    }properties[] = {
        {(__bridge CFStringRef)([self mimeType]), kAudioFileGlobalInfo_TypesForMIMEType},
        {(__bridge CFStringRef)([self fileExtension]), kAudioFileGlobalInfo_TypesForExtension}
    };// 我们能用于确定文件类型的除了MIMEType就是fileExtension了
    
    const size_t numberOfProperties = sizeof(properties) / sizeof(properties[0]);
    for (size_t i = 0; i < numberOfProperties; i++) {
        // 跳过获取不到specifier的情况
        // 很多云音乐并没有文件扩展名
        if (properties[i].specifier == NULL) continue;
        
        // 获取一个AudioFilePropertyID对应的大小
        UInt32 outSize = 0;
        OSStatus status = AudioFileGetGlobalInfoSize(properties[i].propertyID, sizeof(properties[i].specifier), &properties[i].specifier, &outSize);
        // 跳过出错的情况
        if (status != noErr) continue;
        
        size_t count = outSize / sizeof(AudioFileTypeID);
        
        AudioFileTypeID *buffer = malloc(sizeof(AudioFileTypeID) * count);
        if (buffer == NULL) continue;
        
        // 往buffer里写数据,即确定音频文件类型
        AudioFileGetGlobalInfo(properties[i].propertyID, sizeof(properties[i].specifier), &properties[i].specifier, &outSize, buffer);
        
        // 越过出错情况，释放内存
        if (status != noErr) {
            free(buffer);
            continue;
        }
        
        // 使用set保证唯一性
        for (size_t j = 0; j < count; ++j) {
            NSNumber *tid = [NSNumber numberWithUnsignedLong:buffer[j]];
            if ([fallbackTypeIDSet containsObject:tid]) {
                continue;
            }
            
            [fallbackTypeIDArray addObject:tid];
            [fallbackTypeIDSet addObject:tid];
        }
        
        free(buffer);
    }
    return [fallbackTypeIDArray copy];
}

- (NSString *)fileExtension
{
    if (_fileExtension == nil) {
        _fileExtension = [[[[self audioFile] audioURL] path] pathExtension];
    }
    
    return _fileExtension;
}

- (void)_downloaderDidUpdateProgress:(double)downloadProgress
{
    [self _invokeEventBlock];
}

- (void)_downloderDidFinishLoading
{
    if ([_audioDownloder isFailed] ||
        !([_audioDownloder statusCode] >= 200 &&
          [_audioDownloder statusCode] < 300)) {
            _failed = YES;
        }
    else {
        _requestCompleted = YES;
        // 将下载的内容同步到磁盘
        [_mappedData yo_synchronizeMappedFile];
    }
    
    [self _invokeEventBlock];
}

- (void)_invokeEventBlock
{
    if (_eventBlock != NULL) {
        _eventBlock();
    }
}

- (NSUInteger)downloadSpeed
{
    return [_audioDownloder downloadSpeed];
}

- (BOOL)isReady
{
    if (!_requiresCompleteFile) {
        //_requiresCompleteFile == NO
        return _readyToProducePackets;
    }
    
    return _requestCompleted;
}

#pragma mark  --  AudioFileStreamCallBack

static void ARAudioFileStream_PropertyListenerProc(
                                                   void *							inClientData,
                                                   AudioFileStreamID				inAudioFileStream,
                                                   AudioFileStreamPropertyID		inPropertyID,
                                                   AudioFileStreamPropertyFlags *	ioFlags)
{
    _ARRemoteAudioProvider *provider = (__bridge _ARRemoteAudioProvider *)(inClientData);
    [provider _handleAudioFileStreamProperty:inPropertyID];
}

- (void)_handleAudioFileStreamProperty:(AudioFileStreamPropertyID)propertyID
{
    if (propertyID == kAudioFileStreamProperty_ReadyToProducePackets) {
        _readyToProducePackets = YES;
    }
}

static void ARAudioFileStream_PacketsProc(
                                          void *							inClientData,
                                          UInt32							inNumberBytes,
                                          UInt32							inNumberPackets,
                                          const void *					inInputData,
                                          AudioStreamPacketDescription	*inPacketDescriptions)
{
    // no need
}

@end

///========================================================================
///     虚拟基类，用来做对外接口
///========================================================================
@implementation ARAudioProvider

+ (instancetype)providerWithAudioFile:(id<ARAudioFile>)audioFile
{
    NSURL *audioURL = [audioFile audioURL];
    if ([audioURL isFileURL]) {
        return [[_ARLocalAudioProvider alloc] initWithAudioFile:audioFile];
    }else if ([[audioURL scheme] hasPrefix:@"ipod"]) {
        return [[_ARiPodAudioProvider alloc] initWithAudioFile:audioFile];
    }
    return [[_ARRemoteAudioProvider alloc] initWithAudioFile:audioFile];
    return nil;
}

- (instancetype)initWithAudioFile:(id<ARAudioFile>)audioFile
{
    self = [super init];
    if (self) {
        _audioFile = audioFile;
    }
    return self;
}

/**
 * 以下方法由子类提供实现
 */
- (NSUInteger)downloadSpeed
{
    [self doesNotRecognizeSelector:_cmd];
    return 0;
}

- (BOOL)isReady
{
    [self doesNotRecognizeSelector:_cmd];
    return NO;
}

- (BOOL)isFinished
{
    [self doesNotRecognizeSelector:_cmd];
    return NO;
}

@end
