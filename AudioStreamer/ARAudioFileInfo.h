//
//  ARAudioFileInfo.h
//  AudioStreamer
//
//  Created by Archer on 2017/6/2.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudioTypes.h>
@class ARAudioProvider;

NS_ASSUME_NONNULL_BEGIN
///=====================================================================
///     这个类封装了播放流程中的第二步 ---> 解析音频信息，分离音频帧
///=====================================================================
@interface ARAudioFileInfo : NSObject

// AudioFile是否可用
@property (nonatomic, readonly, getter=isAvailable) BOOL available;
// 基本格式
@property (nonatomic, readonly) AudioStreamBasicDescription baseFormat;
// 最高规格格式
@property (nonatomic, readonly) AudioStreamBasicDescription highFormat;
// 头信息长度
@property (nonatomic, readonly, assign) NSUInteger dataOffset;
// 音频时长
@property (nonatomic, readonly, assign) NSTimeInterval estimatedDuration;
// magic cookie
@property (nullable, nonatomic, readonly, strong) NSData *magicCookie;

+ (instancetype)fileInfoWithProvider:(ARAudioProvider *)fileProvider;

@end
NS_ASSUME_NONNULL_END
