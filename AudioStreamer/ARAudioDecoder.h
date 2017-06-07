//
//  ARAudioDecoder.h
//  AudioStreamer
//
//  Created by Archer on 2017/6/3.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudioTypes.h>
@class ARAudioLPCM;
@class ARAudioFileInfo;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXTERN AudioStreamBasicDescription standardLPCMFormat (void);
FOUNDATION_EXTERN UInt32 defaultBufferSize(void);

typedef NS_ENUM(NSUInteger, AudioDecodingStatus) {
    AudioDecodingSucceeded,
    AudioDecodingFailed,
    AudioDecodingEndEncountered,
    AudioDecodingWaiting
};

///=====================================================================
///     这个类封装了播放流程中的第三步 ---> 对分离出来的音频帧解码得到PCM数据
///=====================================================================
@interface ARAudioDecoder : NSObject

@property (nonatomic, readonly, strong) ARAudioFileInfo *fileInfo;
@property (nonatomic, readonly, strong) ARAudioLPCM *lpcm;

+ (instancetype)decoderWithAudioFileInfo:(ARAudioFileInfo *)fileInfo;

- (BOOL)prepare;

- (AudioDecodingStatus)decodeOnce;
- (void)seekToTime:(NSUInteger)milliseconds;


@end
NS_ASSUME_NONNULL_END
