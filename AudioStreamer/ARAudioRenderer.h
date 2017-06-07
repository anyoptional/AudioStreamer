//
//  ARAudioRenderer.h
//  AudioStreamer
//
//  Created by Archer on 2017/6/3.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
///=====================================================================
///     这个类封装了播放流程中的第四步 ---> 把PCM数据解码成音频信号并交给硬件播放
///=====================================================================
@interface ARAudioRenderer : NSObject

// 当前播放时间
@property (nonatomic, readonly) NSUInteger currentTime;
// AudioUnit是否已启动
@property (nonatomic, readonly, getter=isStarted) BOOL started;
// 是否被打断
@property (nonatomic, assign, getter=isInterrupted) BOOL interrupted;
// 音量
@property (nonatomic, assign) double volume;

- (BOOL)prepare;

- (void)renderBytes:(const void *)bytes length:(NSUInteger)length;
- (void)stop;
- (void)flush;
- (void)flushShouldResetTiming:(BOOL)shouldResetTiming;
@end
NS_ASSUME_NONNULL_END
