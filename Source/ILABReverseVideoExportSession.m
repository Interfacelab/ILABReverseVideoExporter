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
    
    dispatch_queue_t reverseQueue;
    
    AVAssetReader *assetReader;
    AVAssetWriter *assetWriter;
    
    AVAssetReaderTrackOutput *assetReaderOutput;
    AVAssetWriterInput *assetWriterInput;
    AVAssetWriterInputPixelBufferAdaptor *assetWriterInputAdaptor;
    
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
        
        _sourceVideoTracks = 0;
        _sourceAudioTracks = 0;
        _sourceFPS = 0;
        _sourceSize = CGSizeZero;
        _sourceDuration = kCMTimeZero;
        _sourceReady = NO;
        
        _showDebug = NO;
        _skipAudio = NO;
        _videoOutputSettings = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) };
        _audioOutputSettings = @{
                                 AVFormatIDKey: @(kAudioFormatLinearPCM),
                                 AVSampleRateKey:@(48000),
                                 AVChannelLayoutKey:@(kAudioChannelLayoutTag_Stereo),
                                 AVNumberOfChannelsKey:@(2),
                                 AVLinearPCMIsNonInterleaved: @(NO),
                                 AVLinearPCMBitDepthKey: @(32),
                                 AVLinearPCMIsFloatKey: @(YES)
                                 };
        
        reverseQueue = dispatch_queue_create([[NSString stringWithFormat:@"%@ reverse queue", self] UTF8String], NULL);
        
        sourceAsset = [AVURLAsset assetWithURL:sourceVideoURL];

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
                
                CGAffineTransform vidT = t.preferredTransform;
                if (vidT.a == 0 && vidT.d == 0 && (vidT.b == 1.0 || vidT.b == -1.0) && (vidT.c == 1.0 || vidT.c == -1.0)) {
                    strongSelf->_sourceSize = CGSizeMake(t.naturalSize.height, t.naturalSize.width);
                } else {
                    strongSelf->_sourceSize = CGSizeMake(t.naturalSize.width, t.naturalSize.height);
                }
                
                strongSelf->_sourceReady = ((strongSelf->_sourceVideoTracks > 0) || (strongSelf->_sourceAudioTracks > 0));
            }
        }];
    }
    
    return self;
}

+(instancetype)exportSessionWithURL:(NSURL *)sourceVideoURL outputURL:(NSURL *)outputURL {
    ILABReverseVideoExportSession *session = [[[self class] alloc] initWithURL:sourceVideoURL];
    session.outputURL = outputURL;
    
    return session;
}

#pragma mark - Properties

-(NSTimeInterval)sourceDurationSeconds {
    return CMTimeGetSeconds(_sourceDuration);
}

#pragma mark - Export Session

-(void)exportAsynchronously:(ILABProgressBlock)progressBlock complete:(ILABCompleteBlock)completeBlock {
    // Make sure the output URL has been specified
    if (!_outputURL) {
        if (completeBlock) {
            completeBlock(NO, [NSError reverseVideoExportSessionError:ILABReverseVideoExportSessionMissingOutput]);
        }
        
        return;
    }
    
    // Remove any existing files at the output URL
    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtURL:_outputURL error:&error];
    if (error) {
        if (completeBlock) {
            completeBlock(NO, error);
        }
        
        return;
    }
    
    AVAsset *reversedAudioAsset = nil;
    if (!_skipAudio && (_sourceAudioTracks > 0)) {
        reversedAudioAsset = [self exportReversedAudio];
        
        if (!reversedAudioAsset) {
            if (completeBlock) {
                completeBlock(NO, lastError);
            }
            
            return;
        }
    }
    
}


#pragma mark - Reverse Methods

-(AVAsset *)exportReversedAudio {
    ILABAudioTrackExporter *audioExporter = [[ILABAudioTrackExporter alloc] initWithAsset:sourceAsset trackIndex:0];

    __block BOOL audioExported = NO;
    NSURL *audioURL = [[_outputURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"exported-audio.wav"];
    [audioExporter exportToURL:audioURL complete:^(BOOL complete, NSError *error) {
        audioExported = complete;
        if (!complete && error) {
            NSLog(@"Audio export error: %@", error.localizedDescription);
        }
    }];
    
    NSURL *reversedURL = [[_outputURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"reversed-audio.wav"];
    
    OSStatus theErr = noErr;

    // set up input file
    AudioFileID inputAudioFile;
    theErr = AudioFileOpenURL((__bridge CFURLRef)audioURL, kAudioFileReadPermission, 0, &inputAudioFile);
    if (theErr != noErr) {
        lastError = [NSError errorWithAudioFileStatusCode:theErr];
        return nil;
    }
    
    AudioStreamBasicDescription theFileFormat;
    UInt32 thePropertySize = sizeof(theFileFormat);
    theErr = AudioFileGetProperty(inputAudioFile, kAudioFilePropertyDataFormat, &thePropertySize, &theFileFormat);
    if (theErr != noErr) {
        AudioFileClose(inputAudioFile);
        lastError = [NSError errorWithAudioFileStatusCode:theErr];
        return nil;
    }
    
    UInt64 fileDataSize = 0;
    thePropertySize = sizeof(fileDataSize);
    theErr = AudioFileGetProperty(inputAudioFile, kAudioFilePropertyAudioDataByteCount, &thePropertySize, &fileDataSize);
    if (theErr != noErr) {
        AudioFileClose(inputAudioFile);
        lastError = [NSError errorWithAudioFileStatusCode:theErr];
        return nil;
    }
    
    AudioFileID outputAudioFile;
    theErr=AudioFileCreateWithURL((__bridge CFURLRef)reversedURL,
                                  kAudioFileWAVEType,
                                  &theFileFormat,
                                  kAudioFileFlags_EraseFile,
                                  &outputAudioFile);
    if (theErr != noErr) {
        AudioFileClose(inputAudioFile);
        lastError = [NSError errorWithAudioFileStatusCode:theErr];
        return nil;
    }
    
    UInt64 dataSize = fileDataSize;
    SInt32* theData = malloc(dataSize);
    
    if (theData == NULL) {
        // TODO: Set lastError to "Could not allocate audio pointer"
        AudioFileClose(inputAudioFile);
        AudioFileClose(outputAudioFile);
        return nil;
    }
    

    UInt32 bytesRead=(UInt32)dataSize;
    theErr = AudioFileReadBytes(inputAudioFile, false, 0, &bytesRead, theData);
    if (theErr != noErr) {
        AudioFileClose(inputAudioFile);
        AudioFileClose(outputAudioFile);
        lastError = [NSError errorWithAudioFileStatusCode:theErr];
        return nil;
    }
    
    Float32 *floatData=malloc(dataSize);
    vDSP_vflt32(theData, 1, floatData, 1, dataSize/sizeof(Float32));
    vDSP_vrvrs(floatData, 1, dataSize/sizeof(Float32));
    vDSP_vfix32(floatData, 1, theData, 1, dataSize/sizeof(Float32));
    
    UInt32 bytesWritten=(UInt32)dataSize;
    theErr=AudioFileWriteBytes(outputAudioFile, false, 0, &bytesWritten, theData);
    if (theErr != noErr) {
        AudioFileClose(inputAudioFile);
        AudioFileClose(outputAudioFile);
        lastError = [NSError errorWithAudioFileStatusCode:theErr];
        return nil;
    }
    
    free(theData);
    free(floatData);
    AudioFileClose(inputAudioFile);
    AudioFileClose(outputAudioFile);
    
    [[NSFileManager defaultManager] removeItemAtURL:audioURL error:nil];
    
    return [AVURLAsset assetWithURL:reversedURL];
}
//
//// read input in multi-pass increments and write in reverse
//- (void)reverseVideoAtPath:(NSString *)inputPath outputPath:(NSString *)outputPath {
//    
//    // check input path
//    if (![[NSFileManager defaultManager] fileExistsAtPath:inputPath]) {
//        NSString *msg = [NSString stringWithFormat:@"input file does not exist: %@", inputPath];
//        NSLog(@"%s %@", __FUNCTION__, msg);
//        [self conveyErrorWithMessage:msg];
//        return;
//    }
//    
//    // make sure nothing exists at output path
//    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
//    
//    NSURL *inputUrl = [NSURL fileURLWithPath:inputPath isDirectory:NO];
//    AVURLAsset *inputAsset = [AVURLAsset URLAssetWithURL:inputUrl options:nil];
//    
//    // make sure we have something to reverse
//    NSArray *videoTracks = [inputAsset tracksWithMediaType:AVMediaTypeVideo];
//    if (videoTracks.count<1) {
//        NSString *msg = [NSString stringWithFormat:@"no video tracks found in: %@", inputPath];
//        if (self.showDebug) NSLog(@"%s %@", __FUNCTION__, msg);
//        [self conveyErrorWithMessage:msg];
//        return;
//    }
//    
//    // create unique name for the processing thread
//    NSString *reverseQueueDescription = [NSString stringWithFormat:@"%@ reverse queue", self];
//    
//    // create main serialization queue
//    dispatch_queue_t reverseQueue = dispatch_queue_create([reverseQueueDescription UTF8String], NULL);
//    
//    if (self.showDebug)
//        NSLog(@"%s analyzing input", __FUNCTION__);
//    
//    // let's reverse this many frames in each pass
//    int numSamplesInPass = 100; // write to output in <numSamplesInPass> frame increments
//    
//    dispatch_async(reverseQueue, ^{
//        NSError *error = nil;
//        
//        // for timing if desired
//        NSDate *methodStart;
//        NSTimeInterval reconTime;
//        
//        // Initialize the reader
//        assetReader = [[AVAssetReader alloc] initWithAsset:inputAsset error:&error];
//        AVAssetTrack *videoTrack = [[inputAsset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
//        
//        float fps = videoTrack.nominalFrameRate;
//        
//        // initialize reader output with base config if not defined before method call
//        if (self.readerOutputSettings == nil)
//            self.readerOutputSettings = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange], kCVPixelBufferPixelFormatTypeKey, nil];
//        assetReaderOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:self.readerOutputSettings];
//        assetReaderOutput.supportsRandomAccess = YES;
//        [assetReader addOutput:assetReaderOutput];
//        [assetReader startReading];
//        
//        if (self.showDebug)
//            NSLog(@"%s size: %f x %f", __FUNCTION__, videoTrack.naturalSize.width, videoTrack.naturalSize.height);
//        
//        CGFloat outputWidth = videoTrack.naturalSize.width;
//        CGFloat outputHeight = videoTrack.naturalSize.height;
//        
//        // main array to hold presentation times
//        NSMutableArray *revSampleTimes = [[NSMutableArray alloc] init];
//        
//        // for timing
//        methodStart = [NSDate date];
//        
//        // now go through the reader output to get some recon on frame presentation times
//        CMSampleBufferRef sample;
//        int localCount = 0;
//        while((sample = [assetReaderOutput copyNextSampleBuffer])) {
//            CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sample);
//            NSValue *presentationValue = [NSValue valueWithBytes:&presentationTime objCType:@encode(CMTime)];
//            [revSampleTimes addObject:presentationValue];
//            CFRelease(sample);
//            sample = NULL;
//            
//            localCount++;
//        }
//        
//        if (self.showDebug) {
//            reconTime = [[NSDate date] timeIntervalSinceDate:methodStart];
//            NSLog(@"%s full read time: %f", __FUNCTION__, reconTime);
//            NSLog(@"%s frames: %d; array count: %lu", __FUNCTION__, localCount, (unsigned long)[revSampleTimes count]);
//            NSLog(@"%s duration: %lld / %d", __FUNCTION__, inputAsset.duration.value, inputAsset.duration.timescale);
//        }
//        
//        // if no frames, format the error and return
//        if (revSampleTimes.count<1) {
//            NSString *msg = [NSString stringWithFormat:@"no video frames found in: %@", inputPath];
//            if (self.showDebug) NSLog(@"%s %@", __FUNCTION__, msg);
//            [self conveyErrorWithMessage:msg];
//            return;
//        }
//        
//        // create pass info since the reversal may be too large to be achieved in one pass
//        
//        // each pass is defined by a time range which we can specify each time we re-init the asset reader
//        
//        // array that holds the pass info
//        NSMutableArray *passDicts = [[NSMutableArray alloc] init];
//        
//        NSValue *initEventValue = [revSampleTimes objectAtIndex:0];
//        CMTime initEventTime = [initEventValue CMTimeValue];
//        
//        CMTime passStartTime = [initEventValue CMTimeValue];
//        CMTime passEndTime = [initEventValue CMTimeValue];
//        
//        int timeStartIndex = -1;
//        int timeEndIndex = -1;
//        int frameStartIndex = -1;
//        int frameEndIndex = -1;
//        
//        NSValue *timeEventValue, *frameEventValue;
//        NSValue *passStartValue, *passEndValue;
//        CMTime timeEventTime, frameEventTime;
//        
//        int totalPasses = (int)ceil((float)revSampleTimes.count / (float)numSamplesInPass);
//        
//        BOOL initNewPass = NO;
//        for (NSInteger i=0; i<revSampleTimes.count; i++) {
//            timeEventValue = [revSampleTimes objectAtIndex:i];
//            timeEventTime = [timeEventValue CMTimeValue];
//            
//            frameEventValue = [revSampleTimes objectAtIndex:(revSampleTimes.count - 1 - i)];
//            frameEventTime = [frameEventValue CMTimeValue];
//            
//            passEndTime = timeEventTime;
//            timeEndIndex = (int)i;
//            frameEndIndex = (int)(revSampleTimes.count - 1 - i);
//            
//            // if this is a pass border
//            if (i%numSamplesInPass == 0) {
//                // record new pass
//                if (i>0) {
//                    passStartValue = [NSValue valueWithBytes:&passStartTime objCType:@encode(CMTime)];
//                    passEndValue = [NSValue valueWithBytes:&passEndTime objCType:@encode(CMTime)];
//                    NSDictionary *dict = @{
//                                           @"passStartTime": passStartValue,
//                                           @"passEndTime": passEndValue,
//                                           @"timeStartIndex" : [NSNumber numberWithLong:timeStartIndex],
//                                           @"timeEndIndex": [NSNumber numberWithLong:timeEndIndex],
//                                           @"frameStartIndex" : [NSNumber numberWithLong:frameStartIndex],
//                                           @"frameEndIndex": [NSNumber numberWithLong:frameEndIndex]
//                                           };
//                    [passDicts addObject:dict];
//                }
//                initNewPass = YES;
//            }
//            
//            // if new pass then init the main vars
//            if (initNewPass) {
//                passStartTime = timeEventTime;
//                timeStartIndex = (int)i;
//                frameStartIndex = (int)(revSampleTimes.count - 1 - i);
//                initNewPass = NO;
//            }
//        }
//        
//        // handle last pass
//        if ((passDicts.count < totalPasses) || revSampleTimes.count%numSamplesInPass != 0) {
//            passStartValue = [NSValue valueWithBytes:&passStartTime objCType:@encode(CMTime)];
//            passEndValue = [NSValue valueWithBytes:&passEndTime objCType:@encode(CMTime)];
//            NSDictionary *dict = @{
//                                   @"passStartTime": passStartValue,
//                                   @"passEndTime": passEndValue,
//                                   @"timeStartIndex" : [NSNumber numberWithLong:timeStartIndex],
//                                   @"timeEndIndex": [NSNumber numberWithLong:timeEndIndex],
//                                   @"frameStartIndex" : [NSNumber numberWithLong:frameStartIndex],
//                                   @"frameEndIndex": [NSNumber numberWithLong:frameEndIndex]
//                                   };
//            [passDicts addObject:dict];
//        }
//        
//        //// writer setup
//        
//        // set the desired output URL for the file created by the export process
//        NSURL *outputURL = [NSURL fileURLWithPath:outputPath isDirectory:NO];
//        
//        // initialize the writer -- NOTE: this assumes a QT output file type
//        assetWriter = [[AVAssetWriter alloc] initWithURL:outputURL
//                                                fileType:AVFileTypeQuickTimeMovie // AVFileTypeMPEG4
//                                                   error:&error];
//        NSDictionary *writerOutputSettings = [NSDictionary dictionaryWithObjectsAndKeys:
//                                              AVVideoCodecH264, AVVideoCodecKey,
//                                              [NSNumber numberWithInt:outputWidth], AVVideoWidthKey,
//                                              [NSNumber numberWithInt:outputHeight], AVVideoHeightKey,
//                                              nil];
//        
//        assetWriterInput = [AVAssetWriterInput
//                            assetWriterInputWithMediaType:AVMediaTypeVideo
//                            outputSettings:writerOutputSettings];
//        
//        [assetWriterInput setExpectsMediaDataInRealTime:NO];
//        [assetWriterInput setTransform:[videoTrack preferredTransform]];
//        
//        // create the pixel buffer adaptor needed to add presentation time to output frames
//        AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
//                                                         assetWriterInputPixelBufferAdaptorWithAssetWriterInput:assetWriterInput
//                                                         sourcePixelBufferAttributes:nil];
//        [assetWriter addInput:assetWriterInput];
//        
//        [assetWriter startWriting];
//        [assetWriter startSessionAtSourceTime:initEventTime];
//        
//        int frameCount = 0; // master frame counter
//        int fpsInt = (int)(fps + 0.5);
//        
//        if (self.showDebug)
//            NSLog(@"%s --- writing ---", __FUNCTION__);
//        
//        // now go through the read passes and write to output
//        for (NSInteger z=passDicts.count-1; z>=0; z--) {
//            NSDictionary *dict = [passDicts objectAtIndex:z];
//            
//            passStartValue = dict[@"passStartTime"];
//            passStartTime = [passStartValue CMTimeValue];
//            
//            passEndValue = dict[@"passEndTime"];
//            passEndTime = [passEndValue CMTimeValue];
//            
//            CMTime passDuration = CMTimeSubtract(passEndTime, passStartTime);
//            
//            int timeStartIx = (int)[dict[@"timeStartIndex"] longValue];
//            int timeEndIx = (int)[dict[@"timeEndIndex"] longValue];
//            
//            int frameStartIx = (int)[dict[@"frameStartIndex"] longValue];
//            int frameEndIx = (int)[dict[@"frameEndIndex"] longValue];
//            
//            if (self.showDebug) {
//                NSLog(@"%s pass %ld: range: %lld to %lld", __FUNCTION__, (long)z, passStartTime.value, passEndTime.value);
//                NSLog(@"%s pass %ld: duration: %lld / %d", __FUNCTION__, (long)z, passDuration.value, passDuration.timescale);
//                NSLog(@"%s pass %ld: time: %d to %d", __FUNCTION__, (long)z, timeStartIx, timeEndIx);
//                NSLog(@"%s pass %ld: frame: %d to %d", __FUNCTION__, (long)z, frameStartIx, frameEndIx);
//            }
//            
//            CMTimeRange localRange = CMTimeRangeMake(passStartTime,passDuration);
//            NSValue *localRangeValue = [NSValue valueWithBytes:&localRange objCType:@encode(CMTimeRange)];
//            NSMutableArray *localRanges = [[NSMutableArray alloc] init];
//            [localRanges addObject:localRangeValue];
//            
//            // make sure we have no remaining samples from last time range
//            while((sample = [assetReaderOutput copyNextSampleBuffer])) {
//                CFRelease(sample);
//            }
//            
//            // reset the reader to the range of the pass
//            [assetReaderOutput resetForReadingTimeRanges:localRanges];
//            if (self.showDebug)
//                NSLog(@"%s pass %ld: set time range", __FUNCTION__, (long)z);
//            
//            // read in the samples of the pass
//            NSMutableArray *samples = [[NSMutableArray alloc] init];
//            while((sample = [assetReaderOutput copyNextSampleBuffer])) {
//                [samples addObject:(__bridge id)sample];
//                CFRelease(sample);
//            }
//            
//            // append samples to output using the recorded frame times
//            for (NSInteger i=0; i<samples.count; i++) {
//                // make sure we have valid event time
//                if (frameCount >= revSampleTimes.count) {
//                    NSLog(@"%s pass %ld: more samples than recorded frames! %d >= %lu ", __FUNCTION__, (long)z, frameCount, (unsigned long)revSampleTimes.count);
//                    break;
//                }
//                
//                // get the orig presentation time (from start to end)
//                NSValue *eventValue = [revSampleTimes objectAtIndex:frameCount];
//                CMTime eventTime = [eventValue CMTimeValue];
//                
//                // take the image/pixel buffer from tail end of the array
//                CVPixelBufferRef imageBufferRef = CMSampleBufferGetImageBuffer((__bridge CMSampleBufferRef)samples[samples.count - i - 1]);
//                
//                // append frames to output
//                BOOL append_ok = NO;
//                int j = 0;
//                while (!append_ok && j < fpsInt) {
//                    
//                    if (adaptor.assetWriterInput.readyForMoreMediaData) {
//                        append_ok = [adaptor appendPixelBuffer:imageBufferRef withPresentationTime:eventTime];
//                        if (!append_ok)
//                            NSLog(@"%s Problem appending frame at time: %lld", __FUNCTION__, eventTime.value);
//                    }
//                    else {
//                        // adaptor not ready
//                        [NSThread sleepForTimeInterval:0.05];
//                    }
//                    
//                    j++;
//                }
//                
//                if (!append_ok)
//                    NSLog(@"%s error appending frame %d; times %d", __FUNCTION__, frameCount, j);
//                
//                frameCount++;
//            }
//            
//            // release the samples array for this pass
//            samples = nil;
//        }
//        
//        // tell asset writer to finish
//        [assetWriterInput markAsFinished];
//        
//        [assetWriter finishWritingWithCompletionHandler:^(){
//            if (self.showDebug)
//                NSLog(@"%s finished writing", __FUNCTION__);
//            
//            // display the total execution time
//            NSDate *methodFinish = [NSDate date];
//            NSTimeInterval procTime = [methodFinish timeIntervalSinceDate:methodStart];
//            
//            if (self.showDebug)
//                NSLog(@"%s reversed %d frames in %f sec", __FUNCTION__, frameCount, procTime);
//            
//            [self conveySuccess];
//        }];
//    });
//}

@end
