//
//  ARAudioStreamer.h
//  AudioStreamer
//
//  Created by Archer on 2017/6/3.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ARAudioFile.h"

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSUInteger, ARAudioStreamerStatus)
{
    ARAudioStreamerIdle,
    ARAudioStreamerBuffering,
    ARAudioStreamerPlaying,
    ARAudioStreamerPaused,
    ARAudioStreamerFinished,
    ARAudioStreamerErrorOccured
};

@interface ARAudioStreamer : NSObject

@property (nonatomic, readonly, strong) id<ARAudioFile> audioFile;
@property (nonatomic, readonly, strong) NSURL *audioURL;

@property (nonatomic, assign) float volume;// 0 ~ 1
@property (nonatomic, readonly, assign) NSTimeInterval duration;
@property (nonatomic, readonly, assign) NSTimeInterval currentTime;

@property (nonatomic, readonly, assign) double bufferingRatio;
@property (nonatomic, readonly, assign) NSUInteger receivedLength;
@property (nonatomic, readonly, assign) NSUInteger expectedLength;
@property (nonatomic, readonly, assign) NSUInteger downloadSpeed;


// This property is KVO enabled
@property (nonatomic, readonly, assign) ARAudioStreamerStatus status;

- (void)play;

- (void)pause;

- (void)stop;

- (void)seekToTime:(NSTimeInterval)seconds;

/**
 Create a new instance with the specified AudioFile.
 
 @param audioFile  An object who's class comfirm to protocol 'ARAudioFile'
 @result A new streamer object, or nil if an error occurs.
 */
- (nullable instancetype)initWithAudioFile:(id<ARAudioFile>)audioFile NS_DESIGNATED_INITIALIZER;

/**
 Convenience Initializer
 Create a new instance with the specified AudioFile.
 
 @param audioFile  An object who's class conforms to protocol 'ARAudioFile'
 @result A new streamer object, or nil if an error occurs.
 */
+ (nullable instancetype)streamerWithAudioFile:(id<ARAudioFile>)audioFile;

/**
 Unavailable arrtibute
 
 Use 'initWithAudioFile' or 'streamerWithAudioFile' instead.
 */
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end
NS_ASSUME_NONNULL_END
