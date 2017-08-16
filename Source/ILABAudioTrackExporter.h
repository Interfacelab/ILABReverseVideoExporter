//
//  ILABAudioTrackExporter.h
//  ILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

#import <Foundation/Foundation.h>
#import "ILABReverseVideoDefs.h"

@import AVFoundation;

/**
 Utility class for exporting an audio AVAssetTrack to a file quickly
 */
@interface ILABAudioTrackExporter : NSObject

@property (readonly) BOOL exporting;
@property (readonly) NSInteger trackIndex;
@property (readonly) AVAsset *sourceAsset;

-(instancetype)initWithAsset:(AVAsset *)sourceAsset trackIndex:(NSInteger)trackIndex;
-(void)exportToURL:(NSURL *)outputURL complete:(ILABCompleteBlock)completeBlock;
-(BOOL)processSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end
