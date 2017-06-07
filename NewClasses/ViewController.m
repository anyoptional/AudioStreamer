//
//  ViewController.m
//  AudioStreamer
//
//  Created by Archer on 2017/6/2.
//  Copyright © 2017年 Archer. All rights reserved.
//

#import "ViewController.h"
#import "ARAudioStreamer.h"
#import "Track+Provider.h"

static void *kStatusKVOKey = &kStatusKVOKey;
static void *kDurationKVOKey = &kDurationKVOKey;
static void *kBufferingRatioKVOKey = &kBufferingRatioKVOKey;

@interface ViewController ()

@property (weak, nonatomic) IBOutlet UILabel *currentTimeLabel;

@property (weak, nonatomic) IBOutlet UILabel *durationLabel;
@property (weak, nonatomic) IBOutlet UILabel *artistLabel;
@property (weak, nonatomic) IBOutlet UILabel *titleLabel;
@property (weak, nonatomic) IBOutlet UISlider *progressSlider;
@property (weak, nonatomic) IBOutlet UILabel *statusLabel;
@property (weak, nonatomic) IBOutlet UISlider *volumeSlider;
@property (weak, nonatomic) IBOutlet UILabel *miscLabel;

@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSArray *tracks;
@property (nonatomic, strong) ARAudioStreamer *streamer;
@property (nonatomic, assign) NSInteger currentTrackIndex;

@end

@implementation ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    _tracks = [Track remoteTracks];
}

- (void)_cancelStreamer
{
    if (_streamer != nil) {
        [_streamer pause];
        [_streamer removeObserver:self forKeyPath:@"status"];
        [_streamer removeObserver:self forKeyPath:@"duration"];
        [_streamer removeObserver:self forKeyPath:@"bufferingRatio"];
        _streamer = nil;
    }
}

- (void)_resetStreamer
{
    
    [self _cancelStreamer];
    
    if (0 == [_tracks count])
    {
        [_titleLabel setText:@"(No tracks available)"];
    }
    else
    {
        Track *track = [_tracks objectAtIndex:_currentTrackIndex];
        NSString *title = [NSString stringWithFormat:@"%@ - %@", track.artist, track.title];
        [_titleLabel setText:title];
        
        _streamer = [ARAudioStreamer streamerWithAudioFile:track];
        [_streamer addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:kStatusKVOKey];
        [_streamer addObserver:self forKeyPath:@"duration" options:NSKeyValueObservingOptionNew context:kDurationKVOKey];
        [_streamer addObserver:self forKeyPath:@"bufferingRatio" options:NSKeyValueObservingOptionNew context:kBufferingRatioKVOKey];
        
        [_streamer play];
        
        [self _updateBufferingStatus];
    }
}

- (void)_timerAction:(id)timer
{
    if ([_streamer duration] == 0.0) {
        [_progressSlider setValue:0.0f animated:NO];
    }
    else {
        [_progressSlider setValue:[_streamer currentTime] / [_streamer duration] animated:YES];
    }
    _currentTimeLabel.text = [NSString stringWithFormat:@"%.1f",[_streamer currentTime]];
    _durationLabel.text = [NSString stringWithFormat:@"%.1f",[_streamer duration]];
}

- (void)_updateStatus
{
    switch ([_streamer status]) {
        case ARAudioStreamerPlaying:
            [_statusLabel setText:@"playing"];
            break;
            
        case ARAudioStreamerPaused:
            [_statusLabel setText:@"paused"];
            break;
            
        case ARAudioStreamerIdle:
            [_statusLabel setText:@"idle"];
            break;
            
        case ARAudioStreamerFinished:
            [_statusLabel setText:@"finished"];
            [self playNext];
            break;
            
        case ARAudioStreamerBuffering:
            [_statusLabel setText:@"buffering"];
            break;
            
        case ARAudioStreamerErrorOccured:
            [_statusLabel setText:@"error"];
            break;
    }
}

- (void)_updateBufferingStatus
{
    [_miscLabel setText:[NSString stringWithFormat:@"Received %.2f/%.2f MB (%.2f %%), Speed %.2f MB/s", (double)[_streamer receivedLength] / 1024 / 1024, (double)[_streamer expectedLength] / 1024 / 1024, [_streamer bufferingRatio] * 100.0, (double)[_streamer downloadSpeed] / 1024 / 1024]];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == kStatusKVOKey) {
        [self performSelector:@selector(_updateStatus)
                     onThread:[NSThread mainThread]
                   withObject:nil
                waitUntilDone:NO];
    }
    else if (context == kDurationKVOKey) {
        [self performSelector:@selector(_timerAction:)
                     onThread:[NSThread mainThread]
                   withObject:nil
                waitUntilDone:NO];
    }
    else if (context == kBufferingRatioKVOKey) {
        [self performSelector:@selector(_updateBufferingStatus)
                     onThread:[NSThread mainThread]
                   withObject:nil
                waitUntilDone:NO];
    }
    else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [self _resetStreamer];
    
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(_timerAction:) userInfo:nil repeats:YES];
    [_volumeSlider setValue:[_streamer volume]];
}
- (IBAction)playPrev
{
    if (--_currentTrackIndex < 0) {
        _currentTrackIndex = [_tracks count] - 1;
    }
    
    [self _resetStreamer];
}

- (IBAction)pause
{
    if (!([_streamer status] == ARAudioStreamerPaused ||
        [_streamer status] == ARAudioStreamerIdle)) {
        [_streamer pause];
    }
}

- (IBAction)play
{
    if ([_streamer status] == ARAudioStreamerPaused ||
        [_streamer status] == ARAudioStreamerIdle) {
        [_streamer play];
    }
}

- (IBAction)stop
{
    [_streamer stop];
}

- (IBAction)playNext
{
    if (++_currentTrackIndex >= [_tracks count]) {
        _currentTrackIndex = 0;
    }
    
    [self _resetStreamer];
}

- (IBAction)seek {
    [_streamer seekToTime:[_streamer duration] * [_progressSlider value]];
}

- (IBAction)setVolume:(id)sender
{
    [_streamer setVolume:[_volumeSlider value]];
}
@end
