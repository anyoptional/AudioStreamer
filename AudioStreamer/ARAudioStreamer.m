//
//  ARAudioStreamer.m
//  AudioStreamer
//
//  Created by Archer on 2017/6/3.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import "ARAudioStreamer.h"
#import "ARAudioEventLoop.h"
#import "ARAudioProvider.h"
#import "ARAudioFileInfo.h"
#import <pthread.h>

@class ARAudioDecoder;
@class ARAudioRenderer;

@interface ARAudioStreamer ()
@property (nonatomic) pthread_mutex_t mutex;

@property (nonatomic, assign) ARAudioStreamerStatus status;
@property (nonatomic, strong) ARAudioProvider *fileProvider;
@property (nonatomic, strong) ARAudioFileInfo *fileInfo;
@property (nonatomic, strong) ARAudioDecoder *decoder;
@property (nonatomic, strong) ARAudioRenderer *renderer;

@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) NSInteger timingOffset;
@property (nonatomic, assign) double bufferingRatio;
@property (nonatomic, assign, getter=isPausedByInterruption) BOOL pausedByInterruption;
@end

@implementation ARAudioStreamer

- (instancetype)init
{
    @throw [NSException exceptionWithName:@"ARAudioStreamer init error" reason:@"ARAudioStreamer must be initialized with a ‘AudioFile’. Use 'streamerWithAudioFile:' or 'initWithAudioFile:' instead." userInfo:nil];
    return [self initWithAudioFile:nil];
}

+ (instancetype)streamerWithAudioFile:(id<ARAudioFile>)audioFile
{
    return [[self alloc] initWithAudioFile:audioFile];
}

- (instancetype)initWithAudioFile:(id<ARAudioFile>)audioFile
{
    self = [super init];
    if (self) {
        if (!audioFile) return nil;
        if (![audioFile conformsToProtocol:@protocol(ARAudioFile)]) return nil;
        
        // 初始化音频数据包装类
        _fileProvider = [ARAudioProvider providerWithAudioFile:audioFile];
        if (!_fileProvider) return nil;
        
        // 更新下载进度
        _bufferingRatio = (double)[_fileProvider receivedLength] / [_fileProvider expectedLength];
        
        _status = ARAudioStreamerIdle;
        pthread_mutex_init(&_mutex, NULL);
    }
    return self;
}


#pragma mark  --  properties

- (id<ARAudioFile>)audioFile
{
    return [_fileProvider audioFile];
}

- (NSURL *)audioURL
{
    return [[self audioFile] audioURL];
}

- (NSTimeInterval)duration
{
    return [_fileInfo estimatedDuration];
}

- (NSUInteger)receivedLength
{
    return [_fileProvider receivedLength];
}

- (NSUInteger)expectedLength
{
    return [_fileProvider expectedLength];
}

- (NSUInteger)downloadSpeed
{
    return [_fileProvider downloadSpeed];
}

- (NSTimeInterval)currentTime
{
    if ([[ARAudioEventLoop sharedEventLoop] currentStreamer] != self) {
        return 0.0;
    }
    
    return [[ARAudioEventLoop sharedEventLoop] currentTime];
}

- (void)setVolume:(float)volume
{
    [[ARAudioEventLoop sharedEventLoop] setVolume:volume];
}

- (float)volume
{
    return [[ARAudioEventLoop sharedEventLoop] volume];
}


#pragma mark  --  public methods

- (void)play
{
    /**
     多线程加锁时机
     1.多人读,不需要
     2.一读一写要加
     3.多人写要加
     */
    pthread_mutex_lock(&_mutex);
    if (_status != ARAudioStreamerPaused &&
        _status != ARAudioStreamerIdle &&
        _status != ARAudioStreamerFinished) {
        return;
    }
    
    if ([[ARAudioEventLoop sharedEventLoop] currentStreamer] != self) {
        [[ARAudioEventLoop sharedEventLoop] pause];
        [[ARAudioEventLoop sharedEventLoop] setCurrentStreamer:self];
    }
    
    [[ARAudioEventLoop sharedEventLoop] play];
    pthread_mutex_unlock(&_mutex);
}

- (void)pause
{
    pthread_mutex_lock(&_mutex);
    if (_status == ARAudioStreamerPaused ||
        _status == ARAudioStreamerIdle ||
        _status == ARAudioStreamerFinished) {
        return;
    }
    
    if ([[ARAudioEventLoop sharedEventLoop] currentStreamer] != self) {
        return;
    }
    
    [[ARAudioEventLoop sharedEventLoop] pause];
    pthread_mutex_unlock(&_mutex);
}

- (void)stop
{
    pthread_mutex_lock(&_mutex);
    if (_status == ARAudioStreamerIdle) {
        return;
    }
    
    if ([[ARAudioEventLoop sharedEventLoop] currentStreamer] != self) {
        return;
    }
    
    [[ARAudioEventLoop sharedEventLoop] stop];
    [[ARAudioEventLoop sharedEventLoop] setCurrentStreamer:nil];
    pthread_mutex_unlock(&_mutex);
}

- (void)seekToTime:(NSTimeInterval)seconds
{
    if ([[ARAudioEventLoop sharedEventLoop] currentStreamer] != self) {
        return;
    }
    
    [[ARAudioEventLoop sharedEventLoop] setCurrentTime:seconds];
}

@end
