//
//  ILABReverseVideoExporter.m
//
//  Created by Jon Gilkison on 8/15/17.
//  Copyright © 2017 Jon Gilkison. All rights reserved.
//  Copyright © 2017 chrissung. All rights reserved.
//

#import "ILABReverseVideoExportSession.h"
#import "ILABAudioTrackExporter.h"

@import Accelerate;
@import CoreAudio;

#pragma mark - ILABReverseVideoExportSession

@interface ILABReverseVideoExportSession() {
    AVURLAsset *sourceAsset;
    
    NSURL *inputURL;
    
    NSError *lastError;
}
@end


@implementation ILABReverseVideoExportSession

#pragma mark - Init/Dealloc

-(instancetype)initWithURL:(NSURL *)sourceVideoURL {
    if ((self = [super init])){
        if (![[NSFileManager defaultManager] fileExistsAtPath:sourceVideoURL.path]) {
            [NSException raise:@"Invalid input file." format:@"The file '%@' could not be located.", sourceVideoURL.path];
        }

        inputURL = sourceVideoURL;
        
        _samplesPerPass = 100;
        
        _sourceVideoTracks = 0;
        _sourceAudioTracks = 0;
        _sourceFPS = 0;
        _sourceSize = CGSizeZero;
        _sourceDuration = kCMTimeZero;
        _sourceReady = NO;
        
        _showDebug = NO;
        _skipAudio = NO;
        _videoOutputSettings = @{ AVVideoCodecKey: AVVideoCodecH264 };
        _audioOutputSettings = @{
                                 AVFormatIDKey: @(kAudioFormatLinearPCM),
                                 AVSampleRateKey:@(48000),
                                 AVChannelLayoutKey:@(kAudioChannelLayoutTag_Stereo),
                                 AVNumberOfChannelsKey:@(2),
                                 AVLinearPCMIsNonInterleaved: @(NO),
                                 AVLinearPCMBitDepthKey: @(32),
                                 AVLinearPCMIsFloatKey: @(YES)
                                 };
        
        sourceAsset = [AVURLAsset assetWithURL:sourceVideoURL];

        dispatch_semaphore_t loadSemi = dispatch_semaphore_create(0);
        __weak typeof(self) weakSelf = self;
        [sourceAsset loadValuesAsynchronouslyForKeys:@[@"duration",@"tracks", @"metadata"] completionHandler:^{
            if (weakSelf) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                NSError *error = nil;
                
                AVKeyValueStatus statusDuration =[strongSelf->sourceAsset statusOfValueForKey:@"duration" error:&error];
                
                if (statusDuration != AVKeyValueStatusLoaded) {
                    return;
                }
                
                AVAssetTrack *t=[strongSelf->sourceAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;

                strongSelf->_sourceDuration = strongSelf->sourceAsset.duration;
                strongSelf->_sourceVideoTracks = [strongSelf->sourceAsset tracksWithMediaType:AVMediaTypeVideo].count;
                strongSelf->_sourceAudioTracks = [strongSelf->sourceAsset tracksWithMediaType:AVMediaTypeAudio].count;
                strongSelf->_sourceFPS = t.nominalFrameRate;
                
                _sourceTransform = t.preferredTransform;
                if (_sourceTransform.a == 0 && _sourceTransform.d == 0 && (_sourceTransform.b == 1.0 || _sourceTransform.b == -1.0) && (_sourceTransform.c == 1.0 || _sourceTransform.c == -1.0)) {
                    strongSelf->_sourceSize = CGSizeMake(t.naturalSize.height, t.naturalSize.width);
                } else {
                    strongSelf->_sourceSize = CGSizeMake(t.naturalSize.width, t.naturalSize.height);
                }
                
                strongSelf->_sourceReady = ((strongSelf->_sourceVideoTracks > 0) || (strongSelf->_sourceAudioTracks > 0));
            }
            
            dispatch_semaphore_signal(loadSemi);
        }];
        
        while(dispatch_semaphore_wait(loadSemi, DISPATCH_TIME_NOW)) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate date]];
        }
    }
    
    return self;
}

+(instancetype)exportSessionWithURL:(NSURL *)sourceVideoURL outputURL:(NSURL *)outputURL {
    ILABReverseVideoExportSession *session = [[[self class] alloc] initWithURL:sourceVideoURL];
    session.outputURL = outputURL;
    
    return session;
}

#pragma mark - Queue

+(dispatch_queue_t)exportQueue {
    static dispatch_queue_t exportQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exportQueue = dispatch_queue_create("reverse video export queue", NULL);
    });
    
    return exportQueue;
}

#pragma mark - Properties

-(NSTimeInterval)sourceDurationSeconds {
    return CMTimeGetSeconds(_sourceDuration);
}

#pragma mark - Export Session

-(void)exportAsynchronously:(ILABProgressBlock)progressBlock complete:(ILABCompleteBlock)completeBlock{
    // Make sure the output URL has been specified
    if (!_outputURL) {
        if (completeBlock) {
            completeBlock(NO, [NSError reverseVideoExportSessionError:ILABReverseVideoExportSessionMissingOutputError]);
        }
        
        return;
    }
    
    // Remove any existing files at the output URL
    NSError *error = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:_outputURL.path]) {
        [[NSFileManager defaultManager] removeItemAtURL:_outputURL error:&error];
        if (error) {
            if (completeBlock) {
                completeBlock(NO, error);
            }
            
            return;
        }
    }
    
    __weak typeof(self) weakSelf = self;
    dispatch_async([[self class] exportQueue], ^{
        if (weakSelf) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            [strongSelf doExportAsynchronously:progressBlock complete:completeBlock];
        }
    });
}

-(void)doExportAsynchronously:(ILABProgressBlock)progressBlock complete:(ILABCompleteBlock)completeBlock {

    NSString *cachePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;

    // Reverse the primary audio track
    AVAsset *reversedAudioAsset = nil;
    NSURL *reversedAudioPath = [NSURL fileURLWithPath:[cachePath stringByAppendingFormat:@"/%@-reversed-audio.wav",[[NSUUID UUID] UUIDString]]];
    if (!_skipAudio && (_sourceAudioTracks > 0)) {
        NSLog(@"Reversed Audio: %@", reversedAudioPath.path);
        reversedAudioAsset = [self exportReversedAudio:reversedAudioPath];
        if (!reversedAudioAsset) {
            if (completeBlock) {
                completeBlock(NO, lastError);
            }
            
            return;
        }
    }
    
    // Reverse the primary video track
    NSURL *reversedVideoPath = [NSURL fileURLWithPath:[cachePath stringByAppendingFormat:@"/%@-reversed-video.mov",[[NSUUID UUID] UUIDString]]];
    NSLog(@"Reversed Video: %@", reversedVideoPath.path);
    AVAsset *reversedVideoAsset = [self exportReversedVideo:reversedVideoPath progress:progressBlock];
    if (!reversedVideoAsset) {
        if (completeBlock) {
            completeBlock(NO, lastError);
        }
        
        return;
    }
    
    // Mux the tracks together
    if (reversedAudioAsset) {
        AVMutableComposition *muxComp = [AVMutableComposition composition];
        
        AVMutableCompositionTrack *compVideoTrack = [muxComp addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        AVMutableCompositionTrack *compAudioTrack = [muxComp addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        
        AVAssetTrack *videoTrack = [reversedVideoAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        AVAssetTrack *audioTrack = [reversedAudioAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;

        compVideoTrack.preferredTransform = videoTrack.preferredTransform;
        
        [compVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, reversedVideoAsset.duration) ofTrack:videoTrack atTime:kCMTimeZero error:nil];
        [compAudioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, reversedAudioAsset.duration) ofTrack:audioTrack atTime:kCMTimeZero error:nil];
        
        AVAssetExportSession *exportSession = [AVAssetExportSession exportSessionWithAsset:muxComp presetName:AVAssetExportPresetPassthrough];
        exportSession.outputURL = _outputURL;
        exportSession.outputFileType = AVFileTypeQuickTimeMovie;

        lastError = nil;
        dispatch_semaphore_t exportSemi = dispatch_semaphore_create(0);

        if (progressBlock) {
            [self updateProgressBlock:progressBlock
                            operation:@"Finishing Up"
                             progress:INFINITY];
        }

        [exportSession exportAsynchronouslyWithCompletionHandler:^{
            if (exportSession.status != AVAssetExportSessionStatusCompleted) {
                lastError = exportSession.error;
            }
            
            dispatch_semaphore_signal(exportSemi);
        }];
        
        while(dispatch_semaphore_wait(exportSemi, DISPATCH_TIME_NOW)) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate date]];
        }
        
        if (completeBlock) {
            completeBlock((lastError == nil), lastError);
        }
        
    } else {
        NSError *error = nil;
        [[NSFileManager defaultManager] moveItemAtURL:reversedVideoPath toURL:_outputURL error:&error];
        if (error) {
            if (completeBlock) {
                completeBlock(NO, error);
            }
            
            return;
        }
    }
}

#pragma mark - Reverse Methods

-(void)updateProgressBlock:(ILABProgressBlock)progressBlock operation:(NSString *)operation progress:(float)progress {
    if (!progressBlock) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        progressBlock(operation, progress);
    });
}

-(AVAsset *)exportReversedAudio:(NSURL *)reversedAudioPath {
    ILABAudioTrackExporter *audioExporter = [[ILABAudioTrackExporter alloc] initWithAsset:sourceAsset trackIndex:0];
    
    dispatch_semaphore_t audioExportSemi = dispatch_semaphore_create(0);
    
    __block BOOL audioExported = NO;
    __weak typeof(self) weakSelf = self;
    [audioExporter exportReverseToURL:reversedAudioPath complete:^(BOOL complete, NSError *error) {
        if (error) {
            NSLog(@"Audio export error: %@", error.localizedDescription);
            
            if (weakSelf) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                strongSelf->lastError = error;
            }
        }
        
        audioExported = complete;
        
        dispatch_semaphore_signal(audioExportSemi);
    }];
    
    while(dispatch_semaphore_wait(audioExportSemi, DISPATCH_TIME_NOW)) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate date]];
    }
    
    if (audioExported) {
        return [AVURLAsset assetWithURL:reversedAudioPath];
    } else {
        return nil;
    }
}

-(AVAsset *)exportReversedVideo:(NSURL *)reversedVideoPath progress:(ILABProgressBlock)progressBlock {
    // Setup the reader
    NSError *error = nil;
    AVAssetReader *assetReader = [AVAssetReader assetReaderWithAsset:sourceAsset error:&error];
    if (error) {
        lastError = error;
        return nil;
    }

    // Setup the reader output
    AVAssetReaderTrackOutput *assetReaderOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:[sourceAsset tracksWithMediaType:AVMediaTypeVideo].firstObject outputSettings:@{ (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) }];
    assetReaderOutput.supportsRandomAccess = YES;
    [assetReader addOutput:assetReaderOutput];
    if (![assetReader startReading]) {
        lastError = [NSError reverseVideoExportSessionError:ILABReverseVideoExportSessionUnableToStartReaderError];
        return nil;
    }
    
    // Fetch the sample times for the source video
    NSMutableArray<NSValue *> *revSampleTimes = [NSMutableArray new];
    CMSampleBufferRef sample;
    NSInteger localCount = 0;
    while ((sample = [assetReaderOutput copyNextSampleBuffer])) {
        CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sample);
        [revSampleTimes addObject:[NSValue valueWithCMTime:presentationTime]];
        
        if (progressBlock) {
            [self updateProgressBlock:progressBlock
                            operation:@"Analyzing Source Video"
                             progress:(CMTimeGetSeconds(presentationTime) / CMTimeGetSeconds(_sourceDuration)) * 0.5];
        }
        
        CFRelease(sample);
        sample = NULL;

        localCount++;
    }
    
    // No samples, no bueno
    if (revSampleTimes.count == 0) {
        lastError = [NSError reverseVideoExportSessionError:ILABReverseVideoExportSessionNoSamplesError];
        return nil;
    }
    
    // Generate the pass data
    NSMutableArray *passDicts = [NSMutableArray new];
    
    CMTime initEventTime = revSampleTimes.firstObject.CMTimeValue;
    CMTime passStartTime = initEventTime;
    CMTime passEndTime = initEventTime;
    CMTime timeEventTime = initEventTime;
    
    NSInteger timeStartIndex = -1;
    NSInteger timeEndIndex = -1;
    NSInteger frameStartIndex = -1;
    NSInteger frameEndIndex = -1;

    NSInteger totalPasses = ceil((float)revSampleTimes.count / (float)_samplesPerPass);
    
    BOOL initNewPass = NO;
    for(NSInteger i=0; i<revSampleTimes.count; i++) {
        timeEventTime = revSampleTimes[i].CMTimeValue;
        
        timeEndIndex = i;
        frameEndIndex = (revSampleTimes.count - 1) - i;
        
        passEndTime = timeEventTime;
        
        if (i % _samplesPerPass == 0) {
            if (i > 0) {
                [passDicts addObject:@{
                                       @"passStartTime": [NSValue valueWithCMTime:passStartTime],
                                       @"passEndTime": [NSValue valueWithCMTime:passEndTime],
                                       @"timeStartIndex": @(timeStartIndex),
                                       @"timeEndIndex": @(timeEndIndex),
                                       @"frameStartIndex": @(frameStartIndex),
                                       @"frameEndIndex": @(frameEndIndex)
                                       }];
            }
            
            initNewPass = YES;
        }
        
        if (initNewPass) {
            passStartTime = timeEventTime;
            timeStartIndex = i;
            frameStartIndex = ((revSampleTimes.count - 1) - i);
            initNewPass = NO;
        }
    }
    
    if ((passDicts.count < totalPasses) || ((revSampleTimes.count % _samplesPerPass) != 0)) {
        [passDicts addObject:@{
                               @"passStartTime": [NSValue valueWithCMTime:passStartTime],
                               @"passEndTime": [NSValue valueWithCMTime:passEndTime],
                               @"timeStartIndex": @(timeStartIndex),
                               @"timeEndIndex": @(timeEndIndex),
                               @"frameStartIndex": @(frameStartIndex),
                               @"frameEndIndex": @(frameEndIndex)
                               }];
    }
    
    
    // Create the writer
    AVAssetWriter *assetWriter = [AVAssetWriter assetWriterWithURL:reversedVideoPath fileType:AVFileTypeQuickTimeMovie error:&error];
    if (error) {
        lastError = error;
        
        return nil;
    }
    
    // Create the writer input and adaptor
    NSMutableDictionary *outputSettings = [_videoOutputSettings mutableCopy];
    if (!outputSettings[AVVideoCodecKey]) {
        outputSettings[AVVideoCodecKey] = AVVideoCodecH264;
    }
    if (!outputSettings[AVVideoWidthKey]) {
        outputSettings[AVVideoWidthKey] = @((_sourceSize.width<_sourceSize.height) ? _sourceSize.height : _sourceSize.width);
    }
    if (!outputSettings[AVVideoHeightKey]) {
        outputSettings[AVVideoHeightKey] = @((_sourceSize.width<_sourceSize.height) ? _sourceSize.width : _sourceSize.height);
    }
    
    AVAssetWriterInput *assetWriterInput =[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:outputSettings];
    assetWriterInput.expectsMediaDataInRealTime = NO;
    assetWriterInput.transform = _sourceTransform;
    
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:assetWriterInput sourcePixelBufferAttributes:nil];
    [assetWriter addInput:assetWriterInput];
    
    // Start writing
    if (![assetWriter startWriting]) {
        lastError = [NSError reverseVideoExportSessionError:ILABReverseVideoExportSessionUnableToStartWriterError];
        return nil;
    }
    [assetWriter startSessionAtSourceTime:initEventTime];
    
    NSInteger frameCount = 0;
    for(NSInteger z=passDicts.count - 1; z>=0; z--) {
        NSDictionary *dict = passDicts[z];
        
        passStartTime = [dict[@"passStartTime"] CMTimeValue];
        passEndTime = [dict[@"passEndTime"] CMTimeValue];
        
        CMTime passDuration = CMTimeSubtract(passEndTime, passStartTime);
        
        timeStartIndex = [dict[@"timeStartIndex"] longValue];
        timeEndIndex = [dict[@"timeEndIndex"] longValue];

        frameStartIndex = [dict[@"frameStartIndex"] longValue];
        frameEndIndex = [dict[@"frameEndIndex"] longValue];
        
        while((sample = [assetReaderOutput copyNextSampleBuffer])) {
            CFRelease(sample);
        }
        
        [assetReaderOutput resetForReadingTimeRanges:@[[NSValue valueWithCMTimeRange:CMTimeRangeMake(passStartTime, passDuration)]]];
        
        NSMutableArray *samples = [NSMutableArray new];
        while((sample = [assetReaderOutput copyNextSampleBuffer])) {
            [samples addObject:(__bridge id)sample];
            CFRelease(sample);
        }
        
        for(NSInteger i=0; i<samples.count; i++) {
            if (frameCount >= revSampleTimes.count) {
                break;
            }
            
            CMTime eventTime = revSampleTimes[frameCount].CMTimeValue;
            
            CVPixelBufferRef imageBufferRef = CMSampleBufferGetImageBuffer((__bridge  CMSampleBufferRef)samples[(samples.count - 1) - i]);
            
            BOOL didAppend = NO;
            NSInteger missCount = 0;
            while(!didAppend && (missCount <= 45)) {
                if (adaptor.assetWriterInput.readyForMoreMediaData) {
                    didAppend = [adaptor appendPixelBuffer:imageBufferRef withPresentationTime:eventTime];
                    if (!didAppend) {
                        lastError = [NSError reverseVideoExportSessionError:ILABReverseVideoExportSessionUnableToWriteFrameError];
                        return nil;
                    }
                } else {
                    [NSThread sleepForTimeInterval:1. / 30.];
                }
                
                missCount++;
            }
            
            frameCount++;
            
            if(progressBlock) {
                [self updateProgressBlock:progressBlock
                                operation:@"Reversing Video"
                                 progress:0.5 + ((float)frameCount/(float)revSampleTimes.count)];
            }
        }
        
        samples = nil;
    }
    
    [assetWriterInput markAsFinished];
    
    dispatch_semaphore_t finishSemi = dispatch_semaphore_create(0);
    
    if (progressBlock) {
        [self updateProgressBlock:progressBlock
                        operation:@"Saving Reversed Video"
                         progress:INFINITY];
    }

    [assetWriter finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(finishSemi);
    }];
    
    while(dispatch_semaphore_wait(finishSemi, DISPATCH_TIME_NOW)) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate date]];
    }
    
    return [AVURLAsset assetWithURL:reversedVideoPath];
}

@end
