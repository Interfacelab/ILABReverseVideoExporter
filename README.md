ILABReverseVideoExporter
========================

A set of utility classes for reversing AVAsset video and audio.  These classes will reverse video, audio and videos with audio.  Video reversal is based heavily on Chris Sung's [CSVideoReverse](https://github.com/chrissung/CSVideoReverse) class.

## Installation

If you are using cocoapods:

```ruby
pod 'ILABReverseVideoExporter'
```

Otherwise, you can drag the files in the `Source` directory into your project.

I don't use carthage, so *shrug*.


## Usage

Usage is pretty simple.  All processing happens in on a separate thread and, thanks to Chris, is very memory performant.

```objc
#import <ILABReverseVideoExporter/ILABReverseVideoExporter.h>

ILABReverseVideoExportSession *exportSession = [ILABReverseVideoExportSession exportSessionWithURL:sourceAssetURL outputURL:outputAssetURL];
    
ILABProgressBlock progressBlock = ^(NSString *currentOperation, float progress) {
    // If progress == INFINITY then the class is performing
    // a process whose progress can't be tracked
    NSLog(@"Progress: %f", (progress == INFINITY) ? '0' : progress * 100.);
};
    
ILABCompleteBlock completeBlock = ^(BOOL complete, NSError *error) {
    NSLog(@"Done.");
};
    
[exportSession exportAsynchronously:progressBlock complete:completeBlock];

```

## Demo
To get the video running, simply open up a terminal to the demo's directory and type:

```bash
pod install
```

## Thanks
Again, special thanks to Chris Sung for the video reversing code.  

