//
//  ARAudioLPCM.m
//  AudioStreamer
//
//  Created by Archer on 2017/6/3.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import "ARAudioLPCM.h"

typedef struct data_segment {
    void *bytes;
    NSUInteger length;
    struct data_segment *next;
} data_segment;

@interface ARAudioLPCM ()
@property (nonatomic) dispatch_semaphore_t lock;
// 链表头
@property (nonatomic, assign) data_segment *segmentRef;
@end

@implementation ARAudioLPCM


- (instancetype)init
{
    self = [super init];
    if (self) {
        _lock = dispatch_semaphore_create(1);
    }
    return self;
}

- (void)dealloc
{
    while (_segmentRef != NULL) {
        data_segment *next = _segmentRef->next;
        free(_segmentRef->bytes);
        free(_segmentRef);
        _segmentRef = next;
    }
}

- (void)setEnd:(BOOL)end
{
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    if (end && !_end) {
        _end = YES;
    }
    dispatch_semaphore_signal(_lock);
}

- (BOOL)readBytes:(void * _Nullable *)bytes length:(NSUInteger *)length
{
    *bytes = NULL;
    *length = 0;
    
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    
    if (_end && _segmentRef == NULL) {
        dispatch_semaphore_signal(_lock);
        return NO;
    }
    // 从链表取数据，bytes需在外部释放
    if (_segmentRef != NULL) {
        *length = _segmentRef->length;
        *bytes = malloc(sizeof(char) * (*length));
        memcpy(*bytes, _segmentRef->bytes, *length);
        
        data_segment *next = _segmentRef->next;
        free(_segmentRef->bytes);
        free(_segmentRef);
        _segmentRef = next;
    }
    
    
    dispatch_semaphore_signal(_lock);
    
    return YES;
}

- (void)writeBytes:(const void *)bytes length:(NSUInteger)length
{
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
    
    if (_end) {
        dispatch_semaphore_signal(_lock);
        return;
    }
    
    if (bytes == NULL || length == 0) {
        dispatch_semaphore_signal(_lock);
        return;
    }
    
    // 分配一个节点的内存
    data_segment *segment = (data_segment *)malloc(sizeof(data_segment));
    // 为解析出来的pcm data分配内存
    segment->bytes = malloc(sizeof(char) * length);
    // 数据长度
    segment->length = length;
    // 因为是往链表尾增加节点，所以这个节点就是尾节点了
    segment->next = NULL;
    // 拷贝数据
    memcpy(segment->bytes, bytes, length);
    
    // 若是有数据剩余，renderer来不及render
    data_segment **link = &_segmentRef;
    while (*link != NULL) {
        // 当前节点
        data_segment *current = *link;
        // 赋值下一节点
        link = &(current->next);
    }
    
    *link = segment;
    
    dispatch_semaphore_signal(_lock);
}
@end
