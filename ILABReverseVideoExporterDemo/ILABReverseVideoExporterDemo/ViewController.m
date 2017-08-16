//
//  ViewController.m
//  ILABReverseVideoExporterDemo
//
//  Created by Jon Gilkison on 8/16/17.
//  Copyright © 2017 Jon Gilkison. All rights reserved.
//

#import "ViewController.h"

@import AVKit;
@import AVFoundation;

#import <OHQBImagePicker/QBImagePicker.h>
#import <ILABReverseVideoExporter/ILABReverseVideoExporter.h>
#import <M13ProgressSuite/M13ProgressViewBar.h>

@interface ViewController()<QBImagePickerControllerDelegate> {
    __weak IBOutlet M13ProgressViewBar *progressBar;
    __weak IBOutlet UILabel *progressLabel;
    
}

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    progressBar.hidden = YES;
    progressBar.showPercentage = NO;
    progressBar.progressBarThickness = 3;
    progressBar.progressBarCornerRadius = 3;
    progressBar.indeterminate = YES;
    
    progressLabel.hidden = YES;
    progressLabel.text = @"";
}


- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (IBAction)reverseVideoTouched:(id)sender {
    QBImagePickerController *picker = [QBImagePickerController new];
    picker.delegate = self;
    picker.mediaType = QBImagePickerMediaTypeVideo;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)qb_imagePickerController:(QBImagePickerController *)imagePickerController didFinishPickingItems:(NSArray *)items {
    PHVideoRequestOptions *reqOpts=[PHVideoRequestOptions new];
    reqOpts.version=PHImageRequestOptionsVersionCurrent;
    reqOpts.deliveryMode=PHVideoRequestOptionsDeliveryModeHighQualityFormat;
    reqOpts.networkAccessAllowed = NO;
    reqOpts.progressHandler = ^(double progress, NSError * _Nullable error, BOOL * _Nonnull stop, NSDictionary * _Nullable info) {
        NSLog(@"Video download progress %f", progress);
    };
    
    [[PHImageManager defaultManager] requestAVAssetForVideo:[items firstObject]
                                                    options:reqOpts
                                              resultHandler:^(AVAsset * _Nullable asset, AVAudioMix * _Nullable audioMix, NSDictionary * _Nullable info) {
                                                  [self processAsset:asset];
                                              }];

    [self dismissViewControllerAnimated:YES completion:nil];
}

-(void)processAsset:(AVAsset *)asset {
    [progressBar performAction:M13ProgressViewActionNone animated:NO];
    progressBar.hidden = NO;
    [progressBar setProgress:0. animated:NO];
    
    progressLabel.text = @"";
    progressLabel.hidden = NO;
    
    NSString *cachePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *outputURL = [NSURL fileURLWithPath:[cachePath stringByAppendingFormat:@"%@-reversed.mov", [[NSUUID UUID] UUIDString]]];
    NSLog(@"Output URL: %@", outputURL.path);
    
    ILABReverseVideoExportSession *exportSession = [ILABReverseVideoExportSession exportSessionWithURL:((AVURLAsset *)asset).URL
                                                                                             outputURL:outputURL];
    
    __weak typeof(self) weakSelf = self;
    ILABProgressBlock progressBlock = ^(NSString *currentOperation, float progress) {
        if (weakSelf) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            
            progressLabel.text = currentOperation;
            
            if (progress == INFINITY) {
                strongSelf->progressBar.indeterminate = YES;
            } else {
                strongSelf->progressBar.indeterminate = NO;
                [strongSelf->progressBar setProgress:progress animated:NO];
            }
        }
    };
    
    ILABCompleteBlock completeBlock = ^(BOOL complete, NSError *error) {
        NSLog(@"Done.");
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                strongSelf->progressLabel.text = @"Done.";
                strongSelf->progressBar.indeterminate = NO;
                [strongSelf->progressBar performAction:(complete) ? M13ProgressViewActionSuccess : M13ProgressViewActionFailure animated:YES];
                
                if (complete) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (weakSelf) {
                            __strong typeof(weakSelf) strongSelf = weakSelf;
                            [strongSelf showReversedVideoAsset:[AVURLAsset assetWithURL:outputURL]];
                        }
                    });
                }
            }
        });
    };
    
    [exportSession exportAsynchronously:progressBlock complete:completeBlock];
}

-(void)showReversedVideoAsset:(AVAsset *)asset {
    progressLabel.hidden = YES;
    progressBar.hidden = YES;
    
    AVPlayerViewController *avpc = [self.storyboard instantiateViewControllerWithIdentifier:@"avPlayer"];
    avpc.player = [AVPlayer playerWithPlayerItem:[AVPlayerItem playerItemWithAsset:asset]];
    [self presentViewController:avpc animated:YES completion:nil];
}

@end
