//
//  ILABReverseVideoDefs.m
//  ILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

@import AVFoundation;

#import "ILABReverseVideoDefs.h"

NSString * const kILABReverseVideoExportSessionErrorDomain = @"kILABReverseVideoExportSessionErrorDomain";

@implementation NSError(ILABReverseVideoExportSession)

+(NSError *)reverseVideoExportSessionError:(ILABReverseVideoExportSessionErrorStatus)errorStatus {
    switch(errorStatus) {
        case ILABReverseVideoExportSessionMissingOutputError:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Missing URL for output."}];
        case ILABReverseVideoExportSessionUnableToStartReaderError:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Unable to start reader."}];
        case ILABReverseVideoExportSessionNoSamplesError:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"No samples in source video."}];
        case ILABReverseVideoExportSessionUnableToStartWriterError:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Unable to start writer."}];
        case ILABReverseVideoExportSessionUnableToWriteFrameError:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Unable to append frame to output."}];
            
        case ILABAudioTrackExporterInvalidTrackIndexError:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"The specified track index is invalid."}];
        case ILABAudioTrackExporterCannotAddInputError:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Cannot add input for audio export."}];
        case ILABAudioTrackExporterCannotAddOutputError:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Cannout add output for audio export."}];
        case ILABAudioTrackExporterExportInProgressError:
            return [NSError errorWithDomain:kILABReverseVideoExportSessionErrorDomain code:errorStatus userInfo:@{NSLocalizedDescriptionKey: @"Export is already in progress."}];
    }
}

+(NSError *)errorWithAudioFileStatusCode:(OSStatus)statusCode {
    NSString *errorDescription=nil;
    switch (statusCode) {
        case kAudioFileUnspecifiedError:
            errorDescription = @"kAudioFileUnspecifiedError";
            
        case kAudioFileUnsupportedFileTypeError:
            errorDescription = @"kAudioFileUnsupportedFileTypeError";
            
        case kAudioFileUnsupportedDataFormatError:
            errorDescription = @"kAudioFileUnsupportedDataFormatError";
            
        case kAudioFileUnsupportedPropertyError:
            errorDescription = @"kAudioFileUnsupportedPropertyError";
            
        case kAudioFileBadPropertySizeError:
            errorDescription = @"kAudioFileBadPropertySizeError";
            
        case kAudioFilePermissionsError:
            errorDescription = @"kAudioFilePermissionsError";
            
        case kAudioFileNotOptimizedError:
            errorDescription = @"kAudioFileNotOptimizedError";
            
        case kAudioFileInvalidChunkError:
            errorDescription = @"kAudioFileInvalidChunkError";
            
        case kAudioFileDoesNotAllow64BitDataSizeError:
            errorDescription = @"kAudioFileDoesNotAllow64BitDataSizeError";
            
        case kAudioFileInvalidPacketOffsetError:
            errorDescription = @"kAudioFileInvalidPacketOffsetError";
            
        case kAudioFileInvalidFileError:
            errorDescription = @"kAudioFileInvalidFileError";
            
        case kAudioFileOperationNotSupportedError:
            errorDescription = @"kAudioFileOperationNotSupportedError";
            
        case kAudioFileNotOpenError:
            errorDescription = @"kAudioFileNotOpenError";
            
        case kAudioFileEndOfFileError:
            errorDescription = @"kAudioFileEndOfFileError";
            
        case kAudioFilePositionError:
            errorDescription = @"kAudioFilePositionError";
            
        case kAudioFileFileNotFoundError:
            errorDescription = @"kAudioFileFileNotFoundError";
            
        default:
            errorDescription = @"Unknown Error";
    }
    
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:statusCode userInfo:@{NSLocalizedDescriptionKey: errorDescription}];
}


@end
