//
//  ARAudioEventLoop.h
//  AudioStreamer
//
//  Created by Archer on 2017/6/3.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import <Foundation/Foundation.h>
@class ARAudioStreamer;

NS_ASSUME_NONNULL_BEGIN
///=====================================================================
///  音频的播放过程是一个：
///  读取音频数据 --> 解析分离音频帧 --> 转码成LPCM --> 播放
///  的循环过程。这个过程会一直持续，直到播放完毕或者出错。
///
///  这个类包装了一个事件循环，用来处理音频播放过程中可能出现的事件，包括状态控制
///=====================================================================
@interface ARAudioEventLoop : NSObject
/**
 当前使用的AudioStreamer对象
 音频上下曲功能是通过重新创建播放器对象实现的
 stop消息会销毁AudioStreamer对象
 */
@property (nullable, nonatomic, strong) ARAudioStreamer *currentStreamer;
// 当前的播放时间
@property (nonatomic, assign) NSTimeInterval currentTime;
// 音量
@property (nonatomic, assign) double volume;

+ (instancetype)sharedEventLoop;

- (void)play;
- (void)pause;
- (void)stop;

@end
NS_ASSUME_NONNULL_END
