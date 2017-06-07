//
//  ARAudioLPCM.h
//  AudioStreamer
//
//  Created by Archer on 2017/6/3.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
///=====================================================================
///     这个类设计为存储解码后的PCM data，以链表的形式
///=====================================================================
@interface ARAudioLPCM : NSObject

// EOF、failed时停止写数据的标志位
@property (nonatomic, assign, getter=isEnd) BOOL end;

// 读取一个节点的数据
- (BOOL)readBytes:( void * _Nullable *_Nullable)bytes length:(NSUInteger *)length;

// 往链表添加一个节点
- (void)writeBytes:(const void *)bytes length:(NSUInteger)length;

@end
NS_ASSUME_NONNULL_END
