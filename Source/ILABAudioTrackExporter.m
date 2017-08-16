//
//  ILABAudioTrackExporter.m
//  ILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

#import "ILABAudioTrackExporter.h"

@interface ILABAudioTrackExporter() {
    AVMutableComposition *audioComp;
    
    AVAssetReaderOutput *trackOutput;
    AVAssetWriterInput *writerInput;
    
    AVAssetReader *assetReader;
    AVAssetWriter *assetWriter;
    
    dispatch_semaphore_t semi;
    dispatch_queue_t mainQueue;
    dispatch_queue_t audioQueue;
    dispatch_group_t dispatchGroup;
    
    NSError *lastError;
    
    NSURL *exportURL;
}
@end

@implementation ILABAudioTrackExporter

-(instancetype)initWithAsset:(AVAsset *)sourceAsset trackIndex:(NSInteger)trackIndex {
    if ((self = [super init])) {
        lastError = nil;
        
        _exporting = NO;
        _sourceAsset = sourceAsset;
        _trackIndex = trackIndex;
        
        mainQueue=dispatch_queue_create([[NSString stringWithFormat:@"%p main",self] UTF8String], NULL);
        audioQueue=dispatch_queue_create([[NSString stringWithFormat:@"%p audio",self] UTF8String], NULL);
        
        semi=dispatch_semaphore_create(0);
        
        dispatchGroup=dispatch_group_create();
        
        AVMutableComposition *comp = [AVMutableComposition composition];
        for(AVAssetTrack *track in [sourceAsset tracksWithMediaType:AVMediaTypeAudio]) {
            AVMutableCompositionTrack *atrack = [comp addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            [atrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, sourceAsset.duration) ofTrack:track atTime:kCMTimeZero error:nil];
        }
    }
    
    return self;
}

#pragma mark - Bookkeeping

-(AVAssetReaderOutput *)createReaderOutput {
    AVAssetReaderTrackOutput *output=nil;
    
    AudioChannelLayout stereoChannelLayout = {
        .mChannelLayoutTag = kAudioChannelLayoutTag_Mono,
        .mChannelBitmap = 0,
        .mNumberChannelDescriptions = 0
    };
    
    NSData *channelLayoutData=[NSData dataWithBytes:&stereoChannelLayout length:offsetof(AudioChannelLayout, mChannelDescriptions)];
    
    NSArray *audioTracks=[audioComp tracksWithMediaType:AVMediaTypeAudio];
    if (_trackIndex>=audioTracks.count) {
        lastError = [NSError reverseVideoExportSessionError:ILABAudioTrackExporterInvalidTrackIndex];
        return nil;
    }
    
    AVCompositionTrack *compAudioTrack=audioTracks[_trackIndex];
    
    output=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:compAudioTrack
                                                      outputSettings:@{
                                                                       AVFormatIDKey:@(kAudioFormatLinearPCM),
                                                                       AVLinearPCMBitDepthKey: @32,
                                                                       AVSampleRateKey:@44100,
                                                                       AVLinearPCMIsFloatKey:@YES,
                                                                       AVLinearPCMIsNonInterleaved:@YES,
                                                                       AVLinearPCMIsBigEndianKey:@NO,
                                                                       AVNumberOfChannelsKey:@1,
                                                                       AVChannelLayoutKey:channelLayoutData
                                                                       }];
    
    return output;
}

-(BOOL)setupReaderAndWriter {
    NSError *localError=nil;
    
    assetReader = [[AVAssetReader alloc] initWithAsset:audioComp error:&localError];
    if (localError) {
        lastError = localError;
        return NO;
    }
    
    [[NSFileManager defaultManager] removeItemAtURL:exportURL error:nil];
    
    assetWriter = [[AVAssetWriter alloc] initWithURL:exportURL fileType:AVFileTypeWAVE error:&localError];
    if (localError) {
        lastError = localError;
        return nil;
    }
    
    trackOutput=[self createReaderOutput];
    if (!trackOutput) {
        return NO;
    }
    
    // Associate the audio mix used to mix the audio tracks being read with the output.
    // Add the output to the reader if possible.
    if ([assetReader canAddOutput:trackOutput]) {
        [assetReader addOutput:trackOutput];
    } else {
        lastError = [NSError reverseVideoExportSessionError:ILABAudioTrackExporterCannotAddInput];
        return NO;
    }
    
    AudioChannelLayout stereoChannelLayout = {
        .mChannelLayoutTag = kAudioChannelLayoutTag_Mono,
        .mChannelBitmap = 0,
        .mNumberChannelDescriptions = 0
    };
    
    NSData *channelLayoutData=[NSData dataWithBytes:&stereoChannelLayout length:offsetof(AudioChannelLayout, mChannelDescriptions)];
    
    writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                     outputSettings:@{
                                                                      AVFormatIDKey:@(kAudioFormatLinearPCM),
                                                                      AVLinearPCMBitDepthKey: @32,
                                                                      AVSampleRateKey:@44100,
                                                                      AVLinearPCMIsFloatKey:@NO,
                                                                      AVLinearPCMIsNonInterleaved:@NO,
                                                                      AVLinearPCMIsBigEndianKey:@NO,
                                                                      AVNumberOfChannelsKey:@1,
                                                                      AVChannelLayoutKey:channelLayoutData
                                                                      }];
    
    
    [assetWriter addInput:writerInput];
    
    return YES;
}

-(BOOL)processSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    return YES;
}

-(BOOL)startReadingAndWriting {
    if (![assetReader startReading]) {
        lastError = assetReader.error;
        return NO;
    }
    
    if (![assetWriter startWriting]) {
        lastError = assetWriter.error;
        return NO;
    }
    
    [assetWriter startSessionAtSourceTime:kCMTimeZero];
    
    __block BOOL audioFinished=NO;
    
    dispatch_group_enter(dispatchGroup);
    
    // Specify the block to execute when the asset writer is ready for audio media data, and specify the queue to call it on.
    [writerInput requestMediaDataWhenReadyOnQueue:audioQueue usingBlock:^{
        // Because the block is called asynchronously, check to see whether its task is complete.
        if (audioFinished)
            return;
        
        BOOL completedOrFailed = NO;
        // If the task isn't complete yet, make sure that the input is actually ready for more media data.
        while ([writerInput isReadyForMoreMediaData] && !completedOrFailed) {
            // Get the next audio sample buffer, and append it to the output file.
            CMSampleBufferRef sampleBuffer = [trackOutput copyNextSampleBuffer];
            if (sampleBuffer != NULL) {
                if (![self processSampleBuffer:sampleBuffer]) {
                    completedOrFailed=YES;
                } else {
                    BOOL success = [writerInput appendSampleBuffer:sampleBuffer];
                    completedOrFailed = !success;
                }
                
                // CFRelease not necessary?
//                CFRelease(sampleBuffer);
            } else {
                completedOrFailed = YES;
            }
        }

        if (completedOrFailed) {
            // Mark the input as finished, but only if we haven't already done so, and then leave the dispatch group (since the audio work has finished).
            BOOL oldFinished = audioFinished;
            audioFinished = YES;
            if (oldFinished == NO) {
                [writerInput markAsFinished];
            }
            
            dispatch_group_leave(dispatchGroup);
        }
    }];
    
    dispatch_group_notify(dispatchGroup, mainQueue, ^{
        dispatch_group_t finishGroup=dispatch_group_create();
        
        dispatch_group_enter(finishGroup);
        [assetWriter finishWritingWithCompletionHandler:^{
            dispatch_group_leave(finishGroup);
        }];
        
        dispatch_group_notify(finishGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            dispatch_semaphore_signal(semi);
            
        });
    });
    
    return YES;
}


#pragma mark - Exporting

-(void)exportToURL:(NSURL *)outputURL complete:(ILABCompleteBlock)completeBlock {
    if (_exporting) {
        if (completeBlock) {
            completeBlock(NO, [NSError reverseVideoExportSessionError:ILABAudioTrackExporterExportInProgress]);
        }
        
        return;
    }
    
    _exporting=YES;
    
    exportURL=[outputURL copy];
    
    __block BOOL result=NO;
    
    dispatch_async(mainQueue, ^{
        if (![self setupReaderAndWriter]) {
            return;
        }

        if (![self startReadingAndWriting]) {
            return;
        }
        
        result=YES;
    });
    
    while(dispatch_semaphore_wait(semi, DISPATCH_TIME_NOW)) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate date]];
    }
    
    _exporting=NO;
    
    if (completeBlock) {
        completeBlock(result, lastError);
    }
}

@end
