//
//  ILABReverseVideoExportSession.h
//  ILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//  Copyright © 2017 Jon Gilkison. All rights reserved.
//  Copyright © 2017 chrissung. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "ILABReverseVideoDefs.h"


/**
 Utility class for reversing videos
 */
@interface ILABReverseVideoExportSession : NSObject

@property (readonly) BOOL sourceReady;                              /**< Source is loaded and ready to be reversed */
@property (readonly) NSInteger sourceVideoTracks;                   /**< Number of video tracks on source asset, anything beyond the 1st will be ignored/skipped */
@property (readonly) NSInteger sourceAudioTracks;                   /**< Number of audio tracks on source asset */
@property (readonly) CMTime sourceDuration;                         /**< Duration of source asset */
@property (readonly) NSTimeInterval sourceDurationSeconds;          /**< Duration in seconds of the source asset */
@property (readonly) float sourceFPS;                               /**< Maximum FPS of the source asset */
@property (readonly) CGSize sourceSize;                             /**< Natural size of the source asset */

@property (assign, nonatomic) BOOL showDebug;                       /**< Show debug output messages when reversing */
@property (assign, nonatomic) BOOL skipAudio;                       /**< Skip the processing of audio */
@property (copy, nonatomic) NSURL *outputURL;                       /**< URL to output reverse video to */
@property (strong, nonatomic) NSDictionary *videoOutputSettings;    /**< Output settings for reversed video */
@property (strong, nonatomic) NSDictionary *audioOutputSettings;    /**< Output settings for reversed audio */

/**
 Create a new instance

 @param sourceVideoURL The URL for the source video
 @return The new instance
 */
-(instancetype)initWithURL:(NSURL *)sourceVideoURL;

/**
 Creates a new export session

 @param sourceVideoURL The URL for the source video
 @param outputURL URL to output reverse video to
 @return The new instance
 */
+(instancetype)exportSessionWithURL:(NSURL *)sourceVideoURL outputURL:(NSURL *)outputURL;

/**
 Start the export process asynchronously

 @param progressBlock Block to call to report progress of export
 @param completeBlock Block to call when export has completed
 */
-(void)exportAsynchronously:(ILABProgressBlock)progressBlock complete:(ILABCompleteBlock)completeBlock;


@end

