//
//  ILABAudioTrackExporter.m
//  ILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

#import "ILABAudioTrackExporter.h"

@import Accelerate;

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
    return [self initWithAsset:sourceAsset trackIndex:0 timeRange:CMTimeRangeMake(kCMTimeZero, sourceAsset.duration)];
}

-(instancetype)initWithAsset:(AVAsset *)sourceAsset trackIndex:(NSInteger)trackIndex timeRange:(CMTimeRange)timeRange {
    if ((self = [super init])) {
        lastError = nil;
        
        _exporting = NO;
        _sourceAsset = sourceAsset;
        _trackIndex = trackIndex;
        
        mainQueue=dispatch_queue_create([[NSString stringWithFormat:@"%p main",self] UTF8String], NULL);
        audioQueue=dispatch_queue_create([[NSString stringWithFormat:@"%p audio",self] UTF8String], NULL);
        
        semi=dispatch_semaphore_create(0);
        
        dispatchGroup=dispatch_group_create();
        
        audioComp = [AVMutableComposition composition];
        for(AVAssetTrack *track in [sourceAsset tracksWithMediaType:AVMediaTypeAudio]) {
            AVMutableCompositionTrack *atrack = [audioComp addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            [atrack insertTimeRange:timeRange ofTrack:track atTime:kCMTimeZero error:nil];
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
        lastError = [NSError reverseVideoExportSessionError:ILABAudioTrackExporterInvalidTrackIndexError];
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
        return NO;
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
        lastError = [NSError reverseVideoExportSessionError:ILABAudioTrackExporterCannotAddInputError];
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
    
    __weak typeof(self) weakSelf = self;
    
    dispatch_group_enter(dispatchGroup);
    
    // Specify the block to execute when the asset writer is ready for audio media data, and specify the queue to call it on.
    [writerInput requestMediaDataWhenReadyOnQueue:audioQueue usingBlock:^{
        
        // Because the block is called asynchronously, check to see whether its task is complete.
        if (audioFinished)
            return;
        
        ILABAudioTrackExporter *exporter = weakSelf;
        
        BOOL completedOrFailed = NO;
        // If the task isn't complete yet, make sure that the input is actually ready for more media data.
        while ([exporter->writerInput isReadyForMoreMediaData] && !completedOrFailed) {
            // Get the next audio sample buffer, and append it to the output file.
            CMSampleBufferRef sampleBuffer = [exporter->trackOutput copyNextSampleBuffer];
            if (sampleBuffer != NULL) {
                if (![self processSampleBuffer:sampleBuffer]) {
                    completedOrFailed=YES;
                } else {
                    BOOL success = [exporter->writerInput appendSampleBuffer:sampleBuffer];
                    completedOrFailed = !success;
                }
                
                // CFRelease not necessary?
                CFRelease(sampleBuffer);
            } else {
                completedOrFailed = YES;
            }
        }
        
        if (completedOrFailed) {
            // Mark the input as finished, but only if we haven't already done so, and then leave the dispatch group (since the audio work has finished).
            BOOL oldFinished = audioFinished;
            audioFinished = YES;
            if (oldFinished == NO) {
                [exporter->writerInput markAsFinished];
            }
            
            dispatch_group_leave(exporter->dispatchGroup);
        }
    }];
    
    dispatch_group_notify(dispatchGroup, mainQueue, ^{
        
        ILABAudioTrackExporter *exporter = weakSelf;
        
        dispatch_group_t finishGroup=dispatch_group_create();
        
        dispatch_group_enter(finishGroup);
        [exporter->assetWriter finishWritingWithCompletionHandler:^{
            dispatch_group_leave(finishGroup);
        }];
        
        dispatch_group_notify(finishGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            dispatch_semaphore_signal(exporter->semi);
            
        });
    });
    
    return YES;
}


#pragma mark - Exporting

-(void)exportToURL:(NSURL *)outputURL complete:(ILABCompleteBlock)completeBlock {
    if (_exporting) {
        if (completeBlock) {
            completeBlock(NO, [NSError reverseVideoExportSessionError:ILABAudioTrackExporterExportInProgressError]);
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

-(void)exportReverseToURL:(NSURL *)outputURL complete:(ILABCompleteBlock)completeBlock {
    NSURL *exportAudioURL = [[outputURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"exported-audio.wav"];

    __weak typeof(self) weakSelf = self;

    [self exportToURL:exportAudioURL complete:^(BOOL complete, NSError *error) {
        if (!complete) {
            if (completeBlock) {
                completeBlock(complete, error);
            }
            
            return;
        }
        
        ILABAudioTrackExporter *exporter = weakSelf;
        OSStatus theErr = noErr;
        
        // set up input file
        AudioFileID inputAudioFile;
        theErr = AudioFileOpenURL((__bridge CFURLRef)exportAudioURL, kAudioFileReadPermission, 0, &inputAudioFile);
        if (theErr != noErr) {
            exporter->lastError = [NSError errorWithAudioFileStatusCode:theErr];
            if (completeBlock) {
                completeBlock(NO, exporter->lastError);
            }
            
            return;
        }
        
        AudioStreamBasicDescription theFileFormat;
        UInt32 thePropertySize = sizeof(theFileFormat);
        theErr = AudioFileGetProperty(inputAudioFile, kAudioFilePropertyDataFormat, &thePropertySize, &theFileFormat);
        if (theErr != noErr) {
            AudioFileClose(inputAudioFile);
            exporter->lastError = [NSError errorWithAudioFileStatusCode:theErr];
            
            if (completeBlock) {
                completeBlock(NO, exporter->lastError);
            }
            
            return;
        }
        
        UInt64 fileDataSize = 0;
        thePropertySize = sizeof(fileDataSize);
        theErr = AudioFileGetProperty(inputAudioFile, kAudioFilePropertyAudioDataByteCount, &thePropertySize, &fileDataSize);
        if (theErr != noErr) {
            AudioFileClose(inputAudioFile);
            exporter->lastError = [NSError errorWithAudioFileStatusCode:theErr];
            if (completeBlock) {
                completeBlock(NO, exporter->lastError);
            }
            
            return;
        }
        
        AudioFileID outputAudioFile;
        theErr=AudioFileCreateWithURL((__bridge CFURLRef)outputURL,
                                      kAudioFileWAVEType,
                                      &theFileFormat,
                                      kAudioFileFlags_EraseFile,
                                      &outputAudioFile);
        if (theErr != noErr) {
            AudioFileClose(inputAudioFile);
            exporter->lastError = [NSError errorWithAudioFileStatusCode:theErr];

            if (completeBlock) {
                completeBlock(NO, exporter->lastError);
            }
            
            return;
        }
        
        UInt64 dataSize = fileDataSize;
        SInt32* theData = malloc((UInt32)dataSize);
        
        if (theData == NULL) {
            // TODO: Set lastError to "Could not allocate audio pointer"
            AudioFileClose(inputAudioFile);
            AudioFileClose(outputAudioFile);

            if (completeBlock) {
                completeBlock(NO, exporter->lastError);
            }
            
            return;
        }
        
        
        UInt32 bytesRead=(UInt32)dataSize;
        theErr = AudioFileReadBytes(inputAudioFile, false, 0, &bytesRead, theData);
        if (theErr != noErr) {
            AudioFileClose(inputAudioFile);
            AudioFileClose(outputAudioFile);
            exporter->lastError = [NSError errorWithAudioFileStatusCode:theErr];

            if (completeBlock) {
                completeBlock(NO, exporter->lastError);
            }
            
            return;
        }
        
        Float32 *floatData=malloc((UInt32)dataSize);
        if (floatData == NULL) {
            free(theData);
            
            // TODO: Set lastError to "Could not allocate audio pointer"
            AudioFileClose(inputAudioFile);
            AudioFileClose(outputAudioFile);
            
            if (completeBlock) {
                completeBlock(NO, exporter->lastError);
            }
            
            return;
        }
        
        vDSP_vflt32((const int *)theData, 1, floatData, 1, (UInt32)dataSize/sizeof(Float32));
        vDSP_vrvrs(floatData, 1, (UInt32)dataSize/sizeof(Float32));
        vDSP_vfix32(floatData, 1, (int *)theData, 1, (UInt32)dataSize/sizeof(Float32));
        
        UInt32 bytesWritten=(UInt32)dataSize;
        theErr=AudioFileWriteBytes(outputAudioFile, false, 0, &bytesWritten, theData);
        if (theErr != noErr) {
            free(theData);
            free(floatData);
            
            AudioFileClose(inputAudioFile);
            AudioFileClose(outputAudioFile);
            exporter->lastError = [NSError errorWithAudioFileStatusCode:theErr];

            if (completeBlock) {
                completeBlock(NO, exporter->lastError);
            }
            
            return;
        }
        
        free(theData);
        free(floatData);
        AudioFileClose(inputAudioFile);
        AudioFileClose(outputAudioFile);
        
        [[NSFileManager defaultManager] removeItemAtURL:exportAudioURL error:nil];
        
        if (completeBlock) {
            completeBlock(YES, nil);
        }
    }];
}

@end
