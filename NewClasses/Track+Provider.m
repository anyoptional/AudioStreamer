

#import "Track+Provider.h"
#import <MediaPlayer/MediaPlayer.h>

@implementation Track (Provider)


+ (NSArray *)remoteTracks
{
  static NSArray *tracks = nil;

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
      NSString *path0 = [[NSBundle mainBundle] pathForResource:@"Winky诗 - 花开不记年" ofType:@"mp3"];

      NSString *path1 = [[NSBundle mainBundle] pathForResource:@"David Arnold - Opening Titles" ofType:@"mp3"];
      NSString *path2 = [[NSBundle mainBundle] pathForResource:@"邂逅" ofType:@"aac"];


      NSURL *audioFileURL0 = [NSURL fileURLWithPath:path0];
      NSURL *audioFileURL1 = [NSURL fileURLWithPath:path1];
      NSURL *audioFileURL2 = [NSURL fileURLWithPath:path2];

      
      NSMutableArray *allTracks = [NSMutableArray array];
      
      Track *track0 = [[Track alloc] init];
      [track0 setArtist:@"Winky诗"];
      [track0 setTitle:@"花开不记年"];
      [track0 setAudioURL:audioFileURL0];
      [allTracks addObject:track0];
      
      
      Track *track1 = [[Track alloc] init];
      [track1 setArtist:@"David Arnold"];
      [track1 setTitle:@"Opening Titles"];
      [track1 setAudioURL:audioFileURL1];
      [allTracks addObject:track1];
      
      Track *track2 = [[Track alloc] init];
      [track2 setArtist:@"Naruto"];
      [track2 setTitle:@"邂逅"];
      [track2 setAudioURL:audioFileURL2];
      [allTracks addObject:track2];
      


      Track *track5 = [[Track alloc] init];
      [track5 setArtist:@"许嵩"];
      [track5 setTitle:@"千古"];
      [track5 setAudioURL:[NSURL URLWithString:@"http://120.25.76.67/OBD/vae.mp3"]];
      [allTracks addObject:track5];
      
    tracks = [allTracks copy];
  });

  return tracks;
}

+ (NSArray *)musicLibraryTracks
{
  static NSArray *tracks = nil;

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSMutableArray *allTracks = [NSMutableArray array];
    for (MPMediaItem *item in [[MPMediaQuery songsQuery] items]) {
      if ([[item valueForProperty:MPMediaItemPropertyIsCloudItem] boolValue]) {
        continue;
      }

      Track *track = [[Track alloc] init];
      [track setArtist:[item valueForProperty:MPMediaItemPropertyArtist]];
      [track setTitle:[item valueForProperty:MPMediaItemPropertyTitle]];
      [track setAudioURL:[item valueForProperty:MPMediaItemPropertyAssetURL]];
      [allTracks addObject:track];
    }

    for (NSUInteger i = 0; i < [allTracks count]; ++i) {
      NSUInteger j = arc4random_uniform((u_int32_t)[allTracks count]);
      [allTracks exchangeObjectAtIndex:i withObjectAtIndex:j];
    }

    tracks = [allTracks copy];
  });

  return tracks;
}

@end
