//
//  NSData+ARMappedFile.m
//  AudioKit
//
//  Created by Archer on 2017/5/16.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import "NSData+ARMappedFile.h"
#import <sys/mman.h>
#import <pthread.h>

@implementation NSData (ARMappedFile)
// 存储 mmap() 的映射的 地址 和 大小
static CFMutableDictionaryRef gMapper;
// 保证 gMapper 的多线程正常读取
static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gMapper = CFDictionaryCreateMutable(CFAllocatorGetDefault(),
                                            0,
                                            &kCFTypeDictionaryKeyCallBacks,
                                            &kCFTypeDictionaryValueCallBacks);
    });
}

+ (NSData *)yo_dataWithMappedContentsOfFile:(NSString *)path
{
    return [[self class] yo_initWithMappedContentsOfFile:path modifiable:NO];
}

+ (NSData *)yo_modifiableDataWithMappedContentsOfFile:(NSString *)path
{
    return [[self class] yo_initWithMappedContentsOfFile:path modifiable:YES];
}

+ (instancetype)yo_initWithMappedContentsOfFile:(NSString *)path
                                   modifiable:(BOOL)modifiable
{
    // 根据是否可改创建NSFileHandle
    NSFileHandle *fileHandle = nil;
    if (modifiable) {
        fileHandle = [NSFileHandle fileHandleForUpdatingAtPath:path];
    }else{
        fileHandle = [NSFileHandle fileHandleForReadingAtPath:path];
    }
    if (!fileHandle) return nil;
    
    // 获取文件描述符
    int fd = [fileHandle fileDescriptor];
    if (fd < 0) return nil;

    // 获取文件大小
    off_t size = lseek(fd, 0, SEEK_END);
    if (size < 0) return nil;
    
    // 内存保护标志
    int prot = PROT_READ;
    if (modifiable) {
        prot |= PROT_WRITE;
    }
    
    /**
     mmap()是一种内存映射文件的方法，即将一个文件或者其它对象映射到进程的地址空间，实现文件磁盘地址和进程虚拟地址空间中一段虚拟地址的一一对映关系。实现这样的映射关系后，进程就可以采用指针的方式读写操作这一段内存，而系统会自动回写脏页面到对应的文件磁盘上，即完成了对文件的操作而不必再调用read,write等系统调用函数。相反，内核空间对这段区域的修改也直接反映用户空间，从而可以实现不同进程间的文件共享
     
void *mmap(void *start, size_t length, int prot, int flags, int fd, off_t offset);

     返回值:成功执行时，mmap()返回被映射区的指针。失败时，mmap()返回MAP_FAILED[其值为(void *)-1]
     第一个参数，start：映射区的开始地址，传NULL由操作系统选择
     第二个参数，length：映射区的长度
     第三个参数，prot：期望的内存保护标志，不能与文件的打开模式冲突。是以下的某个值，可以通过or运算合理地组合在一起
        1 PROT_EXEC ：页内容可以被执行
        2 PROT_READ ：页内容可以被读取
        3 PROT_WRITE ：页可以被写入
        4 PROT_NONE ：页不可访问
     第四个参数，flags：指定映射对象的类型，映射选项和映射页是否可以共享。它的值可以是一个或者多个以下位的组合体
        1 MAP_FIXED 使用指定的映射起始地址，如果由start和len参数指定的内存区重叠于现存的映射空间，重叠部分将会被丢弃。如果指定的起始地址不可用，操作将会失败。并且起始地址必须落在页的边界上。
        2 MAP_SHARED 与其它所有映射这个对象的进程共享映射空间。对共享区的写入，相当于输出到文件。直到msync()或者munmap()被调用，文件实际上不会被更新。
        3 MAP_PRIVATE 建立一个写入时拷贝的私有映射。内存区域的写入不会影响到原文件。这个标志和以上标志是互斥的，只能使用其中一个。
        4 MAP_DENYWRITE 这个标志被忽略。
        5 MAP_EXECUTABLE 同上
        6 MAP_NORESERVE 不要为这个映射保留交换空间。当交换空间被保留，对映射区修改的可能会得到保证。当交换空间不被保留，同时内存不足，对映射区的修改会引起段违例信号。
        7 MAP_LOCKED 锁定映射区的页面，从而防止页面被交换出内存。
        8 MAP_GROWSDOWN 用于堆栈，告诉内核VM系统，映射区可以向下扩展。
        9 MAP_ANONYMOUS 匿名映射，映射区不与任何文件关联。
        10 MAP_ANON MAP_ANONYMOUS的别称，不再被使用。
        11 MAP_FILE 兼容标志，被忽略。
        12 MAP_32BIT 将映射区放在进程地址空间的低2GB，MAP_FIXED指定时会被忽略。当前这个标志只在x86-64平台上得到支持。
        13 MAP_POPULATE 为文件映射通过预读的方式准备好页表。随后对映射区的访问不会被页违例阻塞。
        14 MAP_NONBLOCK 仅和MAP_POPULATE一起使用时才有意义。不执行预读，只为已存在于内存中的页面建立页表入口。
     第五个参数，fd：有效的文件描述符。如果MAP_ANONYMOUS被设定，为了兼容问题，其值应为-1
     第六个参数，offset：被映射对象内容的起点
     */
    
    // 使用mmap()建立映射
    void *address = mmap(NULL, (size_t)size, prot, MAP_SHARED, fd, 0);
    if (address == MAP_FAILED) return nil;
    
    // 此时mmap()已成功执行，address是 映射区 的首地址(其实就是一个长整数，指向内存中的位置)
    
    // 可变字典、数组等在多线程增删改时需要加锁
    pthread_mutex_lock(&gMutex);
    // 以mmap()返回的映射区首地址作为key，音频文件大小作为value，保存进字典
    NSNumber *key = [NSNumber numberWithUnsignedLongLong:(uintptr_t)address];
    NSNumber *value = [NSNumber numberWithUnsignedLongLong:(unsigned long long )size];
    CFDictionarySetValue(gMapper, (__bridge const void *)(key), (__bridge const void *)(value));
    pthread_mutex_unlock(&gMutex);
    
    // 使用自定义CFAllocatorRef，在此Data被释放时，解除内存中的映射关系，同时同步内存和磁盘中的音频文件
    return CFBridgingRelease(CFDataCreateWithBytesNoCopy(kCFAllocatorDefault,(const UInt8 *)address , (CFIndex)size, get_mmap_deallocator()));
}

static CFAllocatorRef get_mmap_deallocator()
{
    static CFAllocatorRef deallocator = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Core Foundation 内存管理相关
        // CFAllocatorContext 是定义对象的操作环境和一些典型的函数指针的结构
        CFAllocatorContext context;
        bzero(&context, sizeof(context));
        memset(&context, 0, sizeof(context));
        context.deallocate = mmap_deallocate;
        deallocator = CFAllocatorCreate(kCFAllocatorDefault, &context);
    });
    return deallocator;
}

static void mmap_deallocate(void *ptr, void *info)
{
    // 参数中的ptr即mmap()返回的映射区地址
    // 取出key
    NSNumber *key = [NSNumber numberWithUnsignedLongLong:(uintptr_t)ptr];
    // 取出value
    pthread_mutex_lock(&gMutex);
    const void *value = CFDictionaryGetValue(gMapper, (__bridge const void *)(key));
    // 移除映射
    CFDictionaryRemoveValue(gMapper, (__bridge const void *)(key));
    pthread_mutex_unlock(&gMutex);
    
    // 读取文件大小
    NSNumber *fileSize = (__bridge NSNumber *)(value);
    size_t size = (size_t)[fileSize unsignedLongLongValue];
    // 解除映射
    munmap(ptr, size);
}

- (void)yo_synchronizeMappedFile
{
    // 取出key
    NSNumber *key = [NSNumber numberWithUnsignedLongLong:(uintptr_t)[self bytes]];
    pthread_mutex_lock(&gMutex);
    // 取出value
    const void *value = CFDictionaryGetValue(gMapper, (__bridge const void *)(key));
    pthread_mutex_unlock(&gMutex);
    
    if (value == NULL) return;
    
    // 读取文件大小
    NSNumber *fileSize = (__bridge NSNumber *)(value);
    size_t size = (size_t)[fileSize unsignedLongLongValue];
    //一般说来，进程在映射空间的对共享内容的改变并不直接写回到磁盘文件中，往往在调用munmap()后才执行该操作。
    //可以通过调用msync()实现磁盘上文件内容与共享内存区的内容一致.
    msync((void *)[self bytes], size, MS_SYNC | MS_INVALIDATE);
}

@end
