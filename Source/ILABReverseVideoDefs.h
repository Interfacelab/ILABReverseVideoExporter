//
//  ILABReverseVideoDefs.h
//  ILABReverseVideoExporter
//
//  Created by Jon Gilkison on 8/15/17.
//

#import <Foundation/Foundation.h>

extern NSString * const kILABReverseVideoExportSessionErrorDomain;

typedef enum : NSInteger {
    ILABReverseVideoExportSessionMissingOutputError        = -100,
    ILABReverseVideoExportSessionUnableToStartReaderError  = -101,
    ILABReverseVideoExportSessionNoSamplesError            = -102,
    ILABReverseVideoExportSessionUnableToStartWriterError  = -103,
    ILABReverseVideoExportSessionUnableToWriteFrameError   = -104,
    
    ILABAudioTrackExporterInvalidTrackIndexError           = -200,
    ILABAudioTrackExporterCannotAddInputError              = -201,
    ILABAudioTrackExporterCannotAddOutputError             = -202,
    ILABAudioTrackExporterExportInProgressError            = -203,
} ILABReverseVideoExportSessionErrorStatus;

/**
 Block called when a reversal has completed.
 
 @param complete YES if successful, NO if not
 @param error If not successful, the NSError describing the problem
 */
typedef void(^ILABCompleteBlock)(BOOL complete, NSError *error);

/**
 Progress block called during reversal process
 
 @param currentOperation The current operation name/title
 @param progress The current progress normalized 0 .. 1, INFINITY for an operation that is indeterminate
 */
typedef void(^ILABProgressBlock)(NSString *currentOperation, float progress);


/**
 Category for easily generation NSError instances in the kILABReverseVideoExportSessionErrorDomain domain.
 */
@interface NSError(ILABReverseVideoExportSession)

/**
 Return an NSError with the kILABReverseVideoExportSessionDomain, error code and localized description set
 
 @param errorStatus The error status to return
 @return The NSError instance
 */
+(NSError *)reverseVideoExportSessionError:(ILABReverseVideoExportSessionErrorStatus)errorStatus;


/**
 Returns an NSError with a helpful localized description for common audio errors

 @param statusCode The status code
 @return The NSError instance
 */
+(NSError *)errorWithAudioFileStatusCode:(OSStatus)statusCode;

@end
