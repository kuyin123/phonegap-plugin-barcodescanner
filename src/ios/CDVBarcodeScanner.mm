/*
 * PhoneGap is available under *either* the terms of the modified BSD license *or* the
 * MIT License (2008). See http://opensource.org/licenses/alphabetical for full text.
 *
 * Copyright 2011 Matt Kane. All rights reserved.
 * Copyright (c) 2011, IBM Corporation
 */

#import <AVFoundation/AVFoundation.h>
#import <AssetsLibrary/AssetsLibrary.h>

//------------------------------------------------------------------------------
// use the all-in-one version of zxing that we built
//------------------------------------------------------------------------------
#import "zxing-all-in-one.h"
#import <Cordova/CDVPlugin.h>


//------------------------------------------------------------------------------
// Delegate to handle orientation functions
//------------------------------------------------------------------------------
@protocol CDVBarcodeScannerOrientationDelegate <NSObject>

- (NSUInteger)supportedInterfaceOrientations;
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation;
- (BOOL)shouldAutorotate;

@end

//------------------------------------------------------------------------------
// Adds a shutter button to the UI, and changes the scan from continuous to
// only performing a scan when you click the shutter button.  For testing.
//------------------------------------------------------------------------------
#define USE_SHUTTER 0

//------------------------------------------------------------------------------
@class CDVbcsProcessor;
@class CDVbcsViewController;

//------------------------------------------------------------------------------
// plugin class
//------------------------------------------------------------------------------
@interface CDVBarcodeScanner : CDVPlugin {}
- (NSString*)isScanNotPossible;
- (void)scan:(CDVInvokedUrlCommand*)command;
- (void)encode:(CDVInvokedUrlCommand*)command;
- (void)returnImage:(NSString*)filePath format:(NSString*)format callback:(NSString*)callback;
- (void)returnSuccess:(NSString*)scannedText format:(NSString*)format cancelled:(BOOL)cancelled flipped:(BOOL)flipped callback:(NSString*)callback action:(NSString*)action;
- (void)returnError:(NSString*)message callback:(NSString*)callback;
@end

//------------------------------------------------------------------------------
// class that does the grunt work
//------------------------------------------------------------------------------
@interface CDVbcsProcessor : NSObject <AVCaptureMetadataOutputObjectsDelegate> {}
@property (nonatomic, retain) CDVBarcodeScanner*           plugin;
@property (nonatomic, retain) NSString*                   callback;
@property (nonatomic, retain) UIViewController*           parentViewController;
@property (nonatomic, retain) CDVbcsViewController*        viewController;
@property (nonatomic, retain) AVCaptureSession*           captureSession;
@property (nonatomic, retain) AVCaptureVideoPreviewLayer* previewLayer;
@property (nonatomic, retain) NSString*                   alternateXib;
@property (nonatomic, retain) NSMutableArray*             results;
@property (nonatomic, retain) NSString*                   formats;
@property (nonatomic)         BOOL                        is1D;
@property (nonatomic)         BOOL                        is2D;
@property (nonatomic)         BOOL                        capturing;
@property (nonatomic)         BOOL                        isFrontCamera;
@property (nonatomic)         BOOL                        isShowFlipCameraButton;
@property (nonatomic)         BOOL                        isShowTorchButton;
@property (nonatomic)         BOOL                        isFlipped;
@property (nonatomic)         BOOL                        isTransitionAnimated;
@property (nonatomic)         BOOL                        isSuccessBeepEnabled;
@property (nonatomic, retain) NSTimer*         timer;


- (id)initWithPlugin:(CDVBarcodeScanner*)plugin callback:(NSString*)callback parentViewController:(UIViewController*)parentViewController alterateOverlayXib:(NSString *)alternateXib;
- (void)scanBarcode;
- (void)barcodeScanSucceeded:(NSString*)text format:(NSString*)format;
- (void)barcodeScanFailed:(NSString*)message;
- (void)barcodeScanCancelled;
- (void)openDialog;
- (NSString*)setUpCaptureSession;
- (void)captureOutput:(AVCaptureOutput*)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection*)connection;
- (NSString*)formatStringFrom:(zxing::BarcodeFormat)format;
- (UIImage*)getImageFromSample:(CMSampleBufferRef)sampleBuffer;
- (zxing::Ref<zxing::LuminanceSource>) getLuminanceSourceFromSample:(CMSampleBufferRef)sampleBuffer imageBytes:(uint8_t**)ptr;
- (UIImage*) getImageFromLuminanceSource:(zxing::LuminanceSource*)luminanceSource;
- (void)dumpImage:(UIImage*)image;
@end

//------------------------------------------------------------------------------
// Qr encoder processor
//------------------------------------------------------------------------------
@interface CDVqrProcessor: NSObject
@property (nonatomic, retain) CDVBarcodeScanner*          plugin;
@property (nonatomic, retain) NSString*                   callback;
@property (nonatomic, retain) NSString*                   stringToEncode;
@property                     NSInteger                   size;

- (id)initWithPlugin:(CDVBarcodeScanner*)plugin callback:(NSString*)callback stringToEncode:(NSString*)stringToEncode;
- (void)generateImage;
@end

//------------------------------------------------------------------------------
// view controller for the ui
//------------------------------------------------------------------------------
@interface CDVbcsViewController : UIViewController <CDVBarcodeScannerOrientationDelegate> {}
@property (nonatomic, retain) CDVbcsProcessor* processor;
@property (nonatomic, retain) NSString*        alternateXib;
@property (nonatomic)         BOOL             shutterPressed;
//@property (nonatomic)         BOOL             linehasRun;
@property (nonatomic, retain) IBOutlet UIView* overlayView;
@property (nonatomic, retain) UIImage* lineimage;
@property (nonatomic, retain) UIView*  reticleView1;
// unsafe_unretained is equivalent to assign - used to prevent retain cycles in the property below
@property (nonatomic, unsafe_unretained) id orientationDelegate;

- (id)initWithProcessor:(CDVbcsProcessor*)processor alternateOverlay:(NSString *)alternateXib;
- (void)startCapturing;
- (UIView*)buildOverlayView;
- (UIImage*)buildReticleImage;
- (void)shutterButtonPressed;
- (IBAction)cancelButtonPressed:(id)sender;

@end

//------------------------------------------------------------------------------
// plugin class
//------------------------------------------------------------------------------
@implementation CDVBarcodeScanner

//--------------------------------------------------------------------------
- (NSString*)isScanNotPossible {
    NSString* result = nil;
    
    Class aClass = NSClassFromString(@"AVCaptureSession");
    if (aClass == nil) {
        return @"AVFoundation Framework not available";
    }
    
    return result;
}

-(BOOL)notHasPermission
{
    AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    return (authStatus == AVAuthorizationStatusDenied ||
            authStatus == AVAuthorizationStatusRestricted);
}



//--------------------------------------------------------------------------
- (void)scan:(CDVInvokedUrlCommand*)command {
    CDVbcsProcessor* processor;
    NSString*       callback;
    NSString*       capabilityError;
    
    callback = command.callbackId;
    
    NSDictionary* options;
    if (command.arguments.count == 0) {
        options = [NSDictionary dictionary];
    } else {
        options = command.arguments[0];
    }
    
    BOOL preferFrontCamera = [options[@"preferFrontCamera"] boolValue];//no
    BOOL showFlipCameraButton = YES;//[options[@"showFlipCameraButton"] boolValue];//no
    BOOL showTorchButton = YES;//[options[@"showTorchButton"] boolValue];//no
    BOOL disableAnimations = [options[@"disableAnimations"] boolValue];//no
    BOOL disableSuccessBeep = [options[@"disableSuccessBeep"] boolValue];//no
    
    // We allow the user to define an alternate xib file for loading the overlay.
    NSString *overlayXib = options[@"overlayXib"];//nil
    
    capabilityError = [self isScanNotPossible];//nil
    if (capabilityError) {
        [self returnError:capabilityError callback:callback];
        return;
    } else if ([self notHasPermission]) {
        NSString * error = NSLocalizedString(@"Access to the camera has been prohibited; please enable it in the Settings app to continue.",nil);
        [self returnError:error callback:callback];
        return;
    }
    
    processor = [[[CDVbcsProcessor alloc]
                  initWithPlugin:self
                  callback:callback
                  parentViewController:self.viewController
                  alterateOverlayXib:overlayXib
                  ] autorelease];
    // queue [processor scanBarcode] to run on the event loop
    
    if (preferFrontCamera) {
        processor.isFrontCamera = true;
    }
    
    if (showFlipCameraButton) {
        processor.isShowFlipCameraButton = true;
    }
    
    if (showTorchButton) {
        processor.isShowTorchButton = true;
    }
    
    processor.isSuccessBeepEnabled = !disableSuccessBeep;
    
    processor.isTransitionAnimated = !disableAnimations;
    
    processor.formats = options[@"formats"];//nil
    
    [processor performSelector:@selector(scanBarcode) withObject:nil afterDelay:0];
}

//--------------------------------------------------------------------------
- (void)encode:(CDVInvokedUrlCommand*)command {
    if([command.arguments count] < 1)
        [self returnError:@"Too few arguments!" callback:command.callbackId];
    
    CDVqrProcessor* processor;
    NSString*       callback;
    callback = command.callbackId;
    
    processor = [[CDVqrProcessor alloc]
                 initWithPlugin:self
                 callback:callback
                 stringToEncode: command.arguments[0][@"data"]
                 ];
    
    [processor retain];
    [processor retain];
    [processor retain];
    // queue [processor generateImage] to run on the event loop
    [processor performSelector:@selector(generateImage) withObject:nil afterDelay:0];
}

- (void)returnImage:(NSString*)filePath format:(NSString*)format callback:(NSString*)callback{
    NSMutableDictionary* resultDict = [[[NSMutableDictionary alloc] init] autorelease];
    resultDict[@"format"] = format;
    resultDict[@"file"] = filePath;
    
    CDVPluginResult* result = [CDVPluginResult
                               resultWithStatus: CDVCommandStatus_OK
                               messageAsDictionary:resultDict
                               ];
    
    [[self commandDelegate] sendPluginResult:result callbackId:callback];
}

//--------------------------------------------------------------------------
- (void)returnSuccess:(NSString*)scannedText format:(NSString*)format cancelled:(BOOL)cancelled flipped:(BOOL)flipped callback:(NSString*)callback action:(NSString*)action{
    NSNumber* cancelledNumber = @(cancelled ? 1 : 0);
    
    NSMutableDictionary* resultDict = [[NSMutableDictionary new] autorelease];
    resultDict[@"text"] = scannedText;
    resultDict[@"format"] = format;
    resultDict[@"cancelled"] = cancelledNumber;
    resultDict[@"action"] = action;
    
    CDVPluginResult* result = [CDVPluginResult
                               resultWithStatus: CDVCommandStatus_OK
                               messageAsDictionary: resultDict
                               ];
    [self.commandDelegate sendPluginResult:result callbackId:callback];//CDVCommandDelegateImpl
}

//--------------------------------------------------------------------------
- (void)returnError:(NSString*)message callback:(NSString*)callback {
    CDVPluginResult* result = [CDVPluginResult
                               resultWithStatus: CDVCommandStatus_ERROR
                               messageAsString: message
                               ];
    
    [self.commandDelegate sendPluginResult:result callbackId:callback];
}

@end

//------------------------------------------------------------------------------
// class that does the grunt work
//------------------------------------------------------------------------------
@implementation CDVbcsProcessor

@synthesize plugin               = _plugin;
@synthesize callback             = _callback;
@synthesize parentViewController = _parentViewController;
@synthesize viewController       = _viewController;
@synthesize captureSession       = _captureSession;
@synthesize previewLayer         = _previewLayer;
@synthesize alternateXib         = _alternateXib;
@synthesize is1D                 = _is1D;
@synthesize is2D                 = _is2D;
@synthesize capturing            = _capturing;
@synthesize results              = _results;
@synthesize timer          = _timer;

SystemSoundID _soundFileObject;

//--------------------------------------------------------------------------
- (id)initWithPlugin:(CDVBarcodeScanner*)plugin
            callback:(NSString*)callback
parentViewController:(UIViewController*)parentViewController
  alterateOverlayXib:(NSString *)alternateXib {
    self = [super init];
    if (!self) return self;
    
    self.plugin               = plugin;
    self.callback             = callback;
    self.parentViewController = parentViewController;
    self.alternateXib         = alternateXib;
    
    self.is1D      = YES;
    self.is2D      = YES;
    self.capturing = NO;
    self.results = [[NSMutableArray new] autorelease];
    
    CFURLRef soundFileURLRef  = CFBundleCopyResourceURL(CFBundleGetMainBundle(), CFSTR("CDVBarcodeScanner.bundle/beep"), CFSTR ("caf"), NULL);
    AudioServicesCreateSystemSoundID(soundFileURLRef, &_soundFileObject);
    
    return self;
}

//--------------------------------------------------------------------------
- (void)dealloc {
    self.plugin = nil;
    self.callback = nil;
    self.parentViewController = nil;
    self.viewController = nil;
    self.captureSession = nil;
    self.previewLayer = nil;
    self.alternateXib = nil;
    self.results = nil;
    
    self.capturing = NO;
    
    AudioServicesRemoveSystemSoundCompletion(_soundFileObject);
    AudioServicesDisposeSystemSoundID(_soundFileObject);
    
    [super dealloc];
}

//--------------------------------------------------------------------------
- (void)scanBarcode {
    
    //    self.captureSession = nil;
    //    self.previewLayer = nil;
    NSString* errorMessage = [self setUpCaptureSession];
    if (errorMessage) {
        [self barcodeScanFailed:errorMessage];
        return;
    }
    
    self.viewController = [[[CDVbcsViewController alloc] initWithProcessor: self alternateOverlay:self.alternateXib] autorelease];
    // here we set the orientation delegate to the MainViewController of the app (orientation controlled in the Project Settings)
    self.viewController.orientationDelegate = self.plugin.viewController;
    
    // delayed [self openDialog];
    [self performSelector:@selector(openDialog) withObject:nil afterDelay:1];
}

//--------------------------------------------------------------------------
- (void)openDialog {
    [self.parentViewController
     presentViewController:self.viewController
     animated:self.isTransitionAnimated completion:nil
     ];
}

//--------------------------------------------------------------------------
- (void)barcodeScanDone:(void (^)(void))callbackBlock {//扫描结束
    self.capturing = NO;
    [self.captureSession stopRunning];
    [self.parentViewController dismissViewControllerAnimated:self.isTransitionAnimated completion:callbackBlock];
    
    // viewcontroller holding onto a reference to us, release them so they
    // will release us
    self.viewController = nil;
}

//--------------------------------------------------------------------------
- (BOOL)checkResult:(NSString *)result {
    return true;
    /*[self.results addObject:result];
     
     NSInteger treshold = 7;
     
     if (self.results.count > treshold) {
     [self.results removeObjectAtIndex:0];
     }
     
     if (self.results.count < treshold)
     {
     return NO;
     }
     
     BOOL allEqual = YES;
     NSString *compareString = self.results[0];
     
     for (NSString *aResult in self.results)
     {
     if (![compareString isEqualToString:aResult])
     {
     allEqual = NO;
     //NSLog(@"Did not fit: %@",self.results);
     break;
     }
     }
     
     return allEqual;*/
}

//--------------------------------------------------------------------------
- (void)barcodeScanSucceeded:(NSString*)text format:(NSString*)format {//成功
    [self stopTimer];
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (self.isSuccessBeepEnabled) {
            AudioServicesPlaySystemSound(_soundFileObject);
        }
        [self barcodeScanDone:^{
            [self.plugin returnSuccess:text format:format cancelled:FALSE flipped:FALSE callback:self.callback action:@"RESULT_SCAN"];
        }];//先调用barcodeScanDone方法，再调用returnSuccess
    });
}

//--------------------------------------------------------------------------
- (void)barcodeScanFailed:(NSString*)message {//失败
    [self stopTimer];
    dispatch_sync(dispatch_get_main_queue(), ^{
        [self barcodeScanDone:^{
            [self.plugin returnError:message callback:self.callback];
        }];
    });
}

//--------------------------------------------------------------------------
- (void)barcodeScanCancelled {//关闭
    [self stopTimer];
    [self barcodeScanDone:^{
        [self.plugin returnSuccess:@"" format:@"" cancelled:TRUE flipped:self.isFlipped callback:self.callback action:@"CLOSE_ACTION"];
    }];
    if (self.isFlipped) {
        self.isFlipped = NO;
    }
}
-(void)stopTimer{
    if (_timer) {
        [_timer invalidate];
        _timer = nil;
    }
}

- (void)flipCamera{//手动输入编号
    [self stopTimer];
    [self barcodeScanDone:^{
        [self.plugin returnSuccess:@"hand" format:@"" cancelled:TRUE flipped:self.isFlipped callback:self.callback action:@"MANUAL_INPUT"];
    }];
    if (self.isFlipped) {
        self.isFlipped = NO;
    }
    /*
     self.isFlipped = YES;
     self.isFrontCamera = !self.isFrontCamera;
     [self barcodeScanDone:^{
     if (self.isFlipped) {
     self.isFlipped = NO;
     }
     [self performSelector:@selector(scanBarcode) withObject:nil afterDelay:0.1];
     }];*/
}

- (void)toggleTorch {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    [device lockForConfiguration:nil];
    if (device.flashActive) {
        [device setTorchMode:AVCaptureTorchModeOff];
        [device setFlashMode:AVCaptureFlashModeOff];
    } else {
        [device setTorchModeOnWithLevel:AVCaptureMaxAvailableTorchLevel error:nil];
        [device setFlashMode:AVCaptureFlashModeOn];
    }
    [device unlockForConfiguration];
}

//--------------------------------------------------------------------------
- (NSString*)setUpCaptureSession {
    NSError* error = nil;
    
    AVCaptureSession* captureSession = [[[AVCaptureSession alloc] init] autorelease];
    self.captureSession = captureSession;
    
    AVCaptureDevice* __block device = nil;
    if (self.isFrontCamera) {
        
        NSArray* devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
        [devices enumerateObjectsUsingBlock:^(AVCaptureDevice *obj, NSUInteger idx, BOOL *stop) {
            if (obj.position == AVCaptureDevicePositionFront) {
                device = obj;
            }
        }];
    } else {
        device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if (!device) return @"unable to obtain video capture device";
        
    }
    
    // set focus params if available to improve focusing
    [device lockForConfiguration:&error];
    if (error == nil) {
        if([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
            [device setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
        }
        if([device isAutoFocusRangeRestrictionSupported]) {
            [device setAutoFocusRangeRestriction:AVCaptureAutoFocusRangeRestrictionNear];
        }
    }
    [device unlockForConfiguration];
    
    AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) return @"unable to obtain video capture device input";
    
    AVCaptureMetadataOutput* output = [[[AVCaptureMetadataOutput alloc] init] autorelease];
    if (!output) return @"unable to obtain video capture output";
    
    [output setMetadataObjectsDelegate:self queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0)];
    
    if ([captureSession canSetSessionPreset:AVCaptureSessionPresetHigh]) {
        captureSession.sessionPreset = AVCaptureSessionPresetHigh;
    } else if ([captureSession canSetSessionPreset:AVCaptureSessionPresetMedium]) {
        captureSession.sessionPreset = AVCaptureSessionPresetMedium;
    } else {
        return @"unable to preset high nor medium quality video capture";
    }
    
    if ([captureSession canAddInput:input]) {
        [captureSession addInput:input];
    }
    else {
        return @"unable to add video capture device input to session";
    }
    
    if ([captureSession canAddOutput:output]) {
        [captureSession addOutput:output];
    }
    else {
        return @"unable to add video capture output to session";
    }
    
    [output setMetadataObjectTypes:[self formatObjectTypes]];
    
    // setup capture preview layer
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:captureSession];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    
    // run on next event loop pass [captureSession startRunning]
    [captureSession performSelector:@selector(startRunning) withObject:nil afterDelay:0];
    
    return nil;
}

//--------------------------------------------------------------------------
// this method gets sent the captured frames,收到返回结果
//--------------------------------------------------------------------------
- (void)captureOutput:(AVCaptureOutput*)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects fromConnection:(AVCaptureConnection*)connection {
    
    if (!self.capturing) return;
    
#if USE_SHUTTER
    if (!self.viewController.shutterPressed) return;
    self.viewController.shutterPressed = NO;
    
    UIView* flashView = [[UIView alloc] initWithFrame:self.viewController.view.frame];
    [flashView setBackgroundColor:[UIColor whiteColor]];
    [self.viewController.view.window addSubview:flashView];
    
    [UIView
     animateWithDuration:.4f
     animations:^{
         [flashView setAlpha:0.f];
     }
     completion:^(BOOL finished){
         [flashView removeFromSuperview];
     }
     ];
    
    //         [self dumpImage: [[self getImageFromSample:sampleBuffer] autorelease]];
#endif
    
    
    try {
        // This will bring in multiple entities if there are multiple 2D codes in frame.
        for (AVMetadataObject *metaData in metadataObjects) {
            AVMetadataMachineReadableCodeObject* code = (AVMetadataMachineReadableCodeObject*)[self.previewLayer transformedMetadataObjectForMetadataObject:(AVMetadataMachineReadableCodeObject*)metaData];
            
            if ([self checkResult:code.stringValue]) {
                [self barcodeScanSucceeded:code.stringValue format:[self formatStringFromMetadata:code]];
            }
        }
    }
    catch (...) {
        //            NSLog(@"decoding: unknown exception");
        //            [self barcodeScanFailed:@"unknown exception decoding barcode"];
    }
    
    //        NSTimeInterval timeElapsed  = [NSDate timeIntervalSinceReferenceDate] - timeStart;
    //        NSLog(@"decoding completed in %dms", (int) (timeElapsed * 1000));
    
}

//--------------------------------------------------------------------------
// convert barcode format to string
//--------------------------------------------------------------------------
- (NSString*)formatStringFrom:(zxing::BarcodeFormat)format {
    if (format == zxing::BarcodeFormat_QR_CODE)      return @"QR_CODE";
    if (format == zxing::BarcodeFormat_DATA_MATRIX)  return @"DATA_MATRIX";
    if (format == zxing::BarcodeFormat_UPC_E)        return @"UPC_E";
    if (format == zxing::BarcodeFormat_UPC_A)        return @"UPC_A";
    if (format == zxing::BarcodeFormat_EAN_8)        return @"EAN_8";
    if (format == zxing::BarcodeFormat_EAN_13)       return @"EAN_13";
    if (format == zxing::BarcodeFormat_CODE_128)     return @"CODE_128";
    if (format == zxing::BarcodeFormat_CODE_39)      return @"CODE_39";
    if (format == zxing::BarcodeFormat_ITF)          return @"ITF";
    return @"???";
}

//--------------------------------------------------------------------------
// convert metadata object information to barcode format string
//--------------------------------------------------------------------------
- (NSString*)formatStringFromMetadata:(AVMetadataMachineReadableCodeObject*)format {
    if (format.type == AVMetadataObjectTypeQRCode)          return @"QR_CODE";
    if (format.type == AVMetadataObjectTypeAztecCode)       return @"AZTEC";
    if (format.type == AVMetadataObjectTypeDataMatrixCode)  return @"DATA_MATRIX";
    if (format.type == AVMetadataObjectTypeUPCECode)        return @"UPC_E";
    // According to Apple documentation, UPC_A is EAN13 with a leading 0.
    if (format.type == AVMetadataObjectTypeEAN13Code && [format.stringValue characterAtIndex:0] == '0') return @"UPC_A";
    if (format.type == AVMetadataObjectTypeEAN8Code)        return @"EAN_8";
    if (format.type == AVMetadataObjectTypeEAN13Code)       return @"EAN_13";
    if (format.type == AVMetadataObjectTypeCode128Code)     return @"CODE_128";
    if (format.type == AVMetadataObjectTypeCode93Code)      return @"CODE_93";
    if (format.type == AVMetadataObjectTypeCode39Code)      return @"CODE_39";
    if (format.type == AVMetadataObjectTypeITF14Code)          return @"ITF";
    if (format.type == AVMetadataObjectTypePDF417Code)      return @"PDF_417";
    return @"???";
}

//--------------------------------------------------------------------------
// convert string formats to metadata objects
//--------------------------------------------------------------------------
- (NSArray*) formatObjectTypes {
    NSArray *supportedFormats = nil;
    if (self.formats != nil) {
        supportedFormats = [self.formats componentsSeparatedByString:@","];
    }
    
    NSMutableArray * formatObjectTypes = [NSMutableArray array];
    
    if (self.formats == nil || [supportedFormats containsObject:@"QR_CODE"]) [formatObjectTypes addObject:AVMetadataObjectTypeQRCode];
    if (self.formats == nil || [supportedFormats containsObject:@"AZTEC"]) [formatObjectTypes addObject:AVMetadataObjectTypeAztecCode];
    if (self.formats == nil || [supportedFormats containsObject:@"DATA_MATRIX"]) [formatObjectTypes addObject:AVMetadataObjectTypeDataMatrixCode];
    if (self.formats == nil || [supportedFormats containsObject:@"UPC_E"]) [formatObjectTypes addObject:AVMetadataObjectTypeUPCECode];
    if (self.formats == nil || [supportedFormats containsObject:@"EAN_8"]) [formatObjectTypes addObject:AVMetadataObjectTypeEAN8Code];
    if (self.formats == nil || [supportedFormats containsObject:@"EAN_13"]) [formatObjectTypes addObject:AVMetadataObjectTypeEAN13Code];
    if (self.formats == nil || [supportedFormats containsObject:@"CODE_128"]) [formatObjectTypes addObject:AVMetadataObjectTypeCode128Code];
    if (self.formats == nil || [supportedFormats containsObject:@"CODE_93"]) [formatObjectTypes addObject:AVMetadataObjectTypeCode93Code];
    if (self.formats == nil || [supportedFormats containsObject:@"CODE_39"]) [formatObjectTypes addObject:AVMetadataObjectTypeCode39Code];
    if (self.formats == nil || [supportedFormats containsObject:@"ITF"]) [formatObjectTypes addObject:AVMetadataObjectTypeITF14Code];
    if (self.formats == nil || [supportedFormats containsObject:@"PDF_417"]) [formatObjectTypes addObject:AVMetadataObjectTypePDF417Code];
    
    return formatObjectTypes;
}

//--------------------------------------------------------------------------
// convert capture's sample buffer (scanned picture) into the thing that
// zxing needs.
//--------------------------------------------------------------------------
- (zxing::Ref<zxing::LuminanceSource>) getLuminanceSourceFromSample:(CMSampleBufferRef)sampleBuffer imageBytes:(uint8_t**)ptr {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferLockBaseAddress(imageBuffer, 0);
    
    size_t   bytesPerRow =            CVPixelBufferGetBytesPerRow(imageBuffer);
    size_t   width       =            CVPixelBufferGetWidth(imageBuffer);
    size_t   height      =            CVPixelBufferGetHeight(imageBuffer);
    uint8_t* baseAddress = (uint8_t*) CVPixelBufferGetBaseAddress(imageBuffer);
    
    // only going to get 90% of the min(width,height) of the captured image
    size_t    greyWidth  = 9 * MIN(width, height) / 10;
    uint8_t*  greyData   = (uint8_t*) malloc(greyWidth * greyWidth);
    
    // remember this pointer so we can free it later
    *ptr = greyData;
    
    if (!greyData) {
        CVPixelBufferUnlockBaseAddress(imageBuffer,0);
        throw new zxing::ReaderException("out of memory");
    }
    
    size_t offsetX = (width  - greyWidth) / 2;
    size_t offsetY = (height - greyWidth) / 2;
    
    // pixel-by-pixel ...
    for (size_t i=0; i<greyWidth; i++) {
        for (size_t j=0; j<greyWidth; j++) {
            // i,j are the coordinates from the sample buffer
            // ni, nj are the coordinates in the LuminanceSource
            // in this case, there's a rotation taking place
            size_t ni = greyWidth-j;
            size_t nj = i;
            
            size_t baseOffset = (j+offsetY)*bytesPerRow + (i + offsetX)*4;
            
            // convert from color to grayscale
            // http://en.wikipedia.org/wiki/Grayscale#Converting_color_to_grayscale
            size_t value = 0.11 * baseAddress[baseOffset] +
            0.59 * baseAddress[baseOffset + 1] +
            0.30 * baseAddress[baseOffset + 2];
            
            greyData[nj*greyWidth + ni] = value;
        }
    }
    
    CVPixelBufferUnlockBaseAddress(imageBuffer,0);
    
    using namespace zxing;
    
    Ref<LuminanceSource> luminanceSource (
                                          new GreyscaleLuminanceSource(greyData, (int)greyWidth, (int)greyWidth, 0, 0, (int)greyWidth, (int)greyWidth)
                                          );
    
    return luminanceSource;
}

//--------------------------------------------------------------------------
// for debugging
//--------------------------------------------------------------------------
- (UIImage*) getImageFromLuminanceSource:(zxing::LuminanceSource*)luminanceSource  {
    unsigned char* bytes = luminanceSource->getMatrix();
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(
                                                 bytes,
                                                 luminanceSource->getWidth(), luminanceSource->getHeight(), 8, luminanceSource->getWidth(),
                                                 colorSpace,
                                                 kCGImageAlphaNone
                                                 );
    
    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    UIImage*   image   = [[UIImage alloc] initWithCGImage:cgImage];
    
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    CGImageRelease(cgImage);
    free(bytes);
    
    return image;
}

//--------------------------------------------------------------------------
// for debugging
//--------------------------------------------------------------------------
- (UIImage*)getImageFromSample:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferLockBaseAddress(imageBuffer, 0);
    
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    size_t width       = CVPixelBufferGetWidth(imageBuffer);
    size_t height      = CVPixelBufferGetHeight(imageBuffer);
    
    uint8_t* baseAddress    = (uint8_t*) CVPixelBufferGetBaseAddress(imageBuffer);
    int      length         = (int)(height * bytesPerRow);
    uint8_t* newBaseAddress = (uint8_t*) malloc(length);
    memcpy(newBaseAddress, baseAddress, length);
    baseAddress = newBaseAddress;
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
                                                 baseAddress,
                                                 width, height, 8, bytesPerRow,
                                                 colorSpace,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst
                                                 );
    
    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    UIImage*   image   = [[UIImage alloc] initWithCGImage:cgImage];
    
    CVPixelBufferUnlockBaseAddress(imageBuffer,0);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    CGImageRelease(cgImage);
    
    free(baseAddress);
    
    return image;
}

//--------------------------------------------------------------------------
// for debugging
//--------------------------------------------------------------------------
- (void)dumpImage:(UIImage*)image {
    NSLog(@"writing image to library: %dx%d", (int)image.size.width, (int)image.size.height);
    ALAssetsLibrary* assetsLibrary = [[[ALAssetsLibrary alloc] init] autorelease];
    [assetsLibrary
     writeImageToSavedPhotosAlbum:image.CGImage
     orientation:ALAssetOrientationUp
     completionBlock:^(NSURL* assetURL, NSError* error){
         if (error) NSLog(@"   error writing image to library");
         else       NSLog(@"   wrote image to library %@", assetURL);
     }
     ];
}

@end

//------------------------------------------------------------------------------
// qr encoder processor
//------------------------------------------------------------------------------
@implementation CDVqrProcessor
@synthesize plugin               = _plugin;
@synthesize callback             = _callback;
@synthesize stringToEncode       = _stringToEncode;
@synthesize size                 = _size;

- (id)initWithPlugin:(CDVBarcodeScanner*)plugin callback:(NSString*)callback stringToEncode:(NSString*)stringToEncode{
    self = [super init];
    if (!self) return self;
    
    self.plugin          = plugin;
    self.callback        = callback;
    self.stringToEncode  = stringToEncode;
    self.size            = 300;
    
    return self;
}

//--------------------------------------------------------------------------
- (void)dealloc {
    self.plugin = nil;
    self.callback = nil;
    self.stringToEncode = nil;
    
    [super dealloc];
}
//--------------------------------------------------------------------------
- (void)generateImage{
    /* setup qr filter */
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setDefaults];
    
    /* set filter's input message
     * the encoding string has to be convert to a UTF-8 encoded NSData object */
    [filter setValue:[self.stringToEncode dataUsingEncoding:NSUTF8StringEncoding]
              forKey:@"inputMessage"];
    
    /* on ios >= 7.0  set low image error correction level */
    if (floor(NSFoundationVersionNumber) >= NSFoundationVersionNumber_iOS_7_0)
        [filter setValue:@"L" forKey:@"inputCorrectionLevel"];
    
    /* prepare cgImage */
    CIImage *outputImage = [filter outputImage];
    CIContext *context = [CIContext contextWithOptions:nil];
    CGImageRef cgImage = [context createCGImage:outputImage
                                       fromRect:[outputImage extent]];
    
    /* returned qr code image */
    UIImage *qrImage = [UIImage imageWithCGImage:cgImage
                                           scale:1.
                                     orientation:UIImageOrientationUp];
    /* resize generated image */
    CGFloat width = _size;
    CGFloat height = _size;
    
    UIGraphicsBeginImageContext(CGSizeMake(width, height));
    
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    [qrImage drawInRect:CGRectMake(0, 0, width, height)];
    qrImage = UIGraphicsGetImageFromCurrentImageContext();
    
    /* clean up */
    UIGraphicsEndImageContext();
    CGImageRelease(cgImage);
    
    /* save image to file */
    NSString* fileName = [[[NSProcessInfo processInfo] globallyUniqueString] stringByAppendingString:@".jpg"];
    NSString* filePath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    [UIImageJPEGRepresentation(qrImage, 1.0) writeToFile:filePath atomically:YES];
    
    /* return file path back to cordova */
    [self.plugin returnImage:filePath format:@"QR_CODE" callback: self.callback];
}
@end

//------------------------------------------------------------------------------
// view controller for the ui
//------------------------------------------------------------------------------
@implementation CDVbcsViewController
@synthesize lineimage = _lineimage;
@synthesize reticleView1 = _reticleView1;
@synthesize processor      = _processor;
@synthesize shutterPressed = _shutterPressed;
@synthesize alternateXib   = _alternateXib;
@synthesize overlayView    = _overlayView;
//@synthesize linehasRun = _linehasRun;


//--------------------------------------------------------------------------
- (id)initWithProcessor:(CDVbcsProcessor*)processor alternateOverlay:(NSString *)alternateXib {
    self = [super init];
    if (!self) return self;
    
    self.processor = processor;
    self.shutterPressed = NO;
    self.alternateXib = alternateXib;
    self.overlayView = nil;
    return self;
}

//--------------------------------------------------------------------------
- (void)dealloc {
    self.view = nil;
    self.processor = nil;
    self.shutterPressed = NO;
    self.alternateXib = nil;
    self.overlayView = nil;
    [super dealloc];
}

//--------------------------------------------------------------------------
- (void)loadView {
    self.view = [[UIView alloc] initWithFrame: self.processor.parentViewController.view.frame];
    
    // setup capture preview layer
    AVCaptureVideoPreviewLayer* previewLayer = self.processor.previewLayer;
    previewLayer.frame = self.view.bounds;
    previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    
    if ([previewLayer.connection isVideoOrientationSupported]) {
        [previewLayer.connection setVideoOrientation:AVCaptureVideoOrientationPortrait];
    }
    
    [self.view.layer insertSublayer:previewLayer below:[[self.view.layer sublayers] objectAtIndex:0]];
    
    [self.view addSubview:[self buildOverlayView]];
}

//--------------------------------------------------------------------------
- (void)viewWillAppear:(BOOL)animated {
    
    // set video orientation to what the camera sees
    self.processor.previewLayer.connection.videoOrientation = (AVCaptureVideoOrientation) [[UIApplication sharedApplication] statusBarOrientation];
    
    // this fixes the bug when the statusbar is landscape, and the preview layer
    // starts up in portrait (not filling the whole view)
    self.processor.previewLayer.frame = self.view.bounds;
}

//--------------------------------------------------------------------------
- (void)viewDidAppear:(BOOL)animated {
    [self startCapturing];
    
    [super viewDidAppear:animated];
}

//--------------------------------------------------------------------------
- (void)startCapturing {
    self.processor.capturing = YES;
}

//--------------------------------------------------------------------------
- (void)shutterButtonPressed {
    self.shutterPressed = YES;
}

//--------------------------------------------------------------------------
- (IBAction)cancelButtonPressed:(id)sender {//取消按钮
    [self.processor performSelector:@selector(barcodeScanCancelled) withObject:nil afterDelay:0];
}

- (void)flipCameraButtonPressed:(id)sender//跳转按钮
{
    [self.processor performSelector:@selector(flipCamera) withObject:nil afterDelay:0];
}

- (void)torchButtonPressed:(id)sender
{
    [self.processor performSelector:@selector(toggleTorch) withObject:nil afterDelay:0];
}

//--------------------------------------------------------------------------
- (UIView *)buildOverlayViewFromXib
{
    [[NSBundle mainBundle] loadNibNamed:self.alternateXib owner:self options:NULL];
    
    if ( self.overlayView == nil )
    {
        NSLog(@"%@", @"An error occurred loading the overlay xib.  It appears that the overlayView outlet is not set.");
        return nil;
    }
    
    return self.overlayView;
}

-(UIImage *)returnImages:(NSString *)name
{
    NSURL *bundleURL = [[NSBundle mainBundle] URLForResource:@"CDVBarcodeScanner" withExtension:@"bundle"];
    NSBundle *bundle = [NSBundle bundleWithURL:bundleURL];
    NSString *imagePath = [bundle pathForResource:name ofType:@"png"];
    UIImage *image = [UIImage imageWithContentsOfFile:imagePath];
    return image;
}

//--------------------------------------------------------------------------

//--------------------------------------------------------------------------
#define handHeight 90.0f
#define handWidth 70.0f
#define closeWidth 30.0f

- (UIView*)buildOverlayView {
    
    if ( nil != self.alternateXib )
    {
        return [self buildOverlayViewFromXib];
    }
    CGRect bounds = self.view.bounds;
    bounds = CGRectMake(0, 0, bounds.size.width, bounds.size.height);//全屏幕
    
    UIView* overlayView = [[UIView alloc] initWithFrame:bounds];
    overlayView.autoresizesSubviews = YES;
    overlayView.autoresizingMask    = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlayView.opaque              = NO;
    
    
    
    
    UIButton *handView = [[[UIButton alloc] init] autorelease];
    handView.frame = CGRectMake(bounds.size.width/12, bounds.size.height*8/10, handWidth, handHeight);
    [overlayView addSubview:handView];
    [handView addTarget:(id)self action:@selector(flipCameraButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
    UIImageView *iconView = [[[UIImageView alloc] init] autorelease];
    iconView.frame = CGRectMake(0, 0, handWidth, handHeight*3/5);
    iconView.image = [self returnImages:@"qrcode_normal"];
    [handView addSubview:iconView];
    UILabel *titleLabel = [[[UILabel alloc] init] autorelease];
    titleLabel.frame = CGRectMake(0, handHeight*3/5, handWidth, handHeight*2/5);
    titleLabel.textAlignment = NSTextAlignmentCenter; // 居中
    titleLabel.text = @"输入编号";
    titleLabel.font = [UIFont fontWithName:@"Arial" size:12];
    titleLabel.textColor = [UIColor whiteColor];
    [handView addSubview:titleLabel];
    
    
    
    
    
    UIButton *light = [[[UIButton alloc] init] autorelease];
    light.frame = CGRectMake((bounds.size.width*11/12)-handWidth, bounds.size.height*8/10, handWidth, handHeight);
    [overlayView addSubview:light];
    [light addTarget:(id)self action:@selector(torchButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
    UIImageView *iconView1 = [[[UIImageView alloc] init] autorelease];
    iconView1.frame = CGRectMake(0, 0, handWidth, handHeight*3/5);
    iconView1.image = [self returnImages:@"light_on"];
    [light addSubview:iconView1];
    UILabel *titleLabel1 = [[[UILabel alloc] init] autorelease];
    titleLabel1.frame = CGRectMake(0, handHeight*3/5, handWidth, handHeight*2/5);
    titleLabel1.textAlignment = NSTextAlignmentCenter; // 居中
    titleLabel1.text = @"手电筒";
    titleLabel1.font = [UIFont fontWithName:@"Arial" size:12];
    titleLabel1.textColor = [UIColor whiteColor];
    [light addSubview:titleLabel1];
    
    
    
    UIButton *close = [[[UIButton alloc] init] autorelease];
    close.frame = CGRectMake((bounds.size.width*11/12)-closeWidth, bounds.size.height*1/10, closeWidth, closeWidth);
    [overlayView addSubview:close];
    [close addTarget:(id)self action:@selector(cancelButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
    UIImageView *iconView2 = [[[UIImageView alloc] init] autorelease];
    iconView2.frame = CGRectMake(0, 0, closeWidth, closeWidth);
    iconView2.image = [self returnImages:@"close"];
    [close addSubview:iconView2];
    
    
    
    
    
    
    
    /*
     UIToolbar* toolbar = [[UIToolbar alloc] init];
     toolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
     
     id cancelButton = [[[UIBarButtonItem alloc]
     initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
     target:(id)self
     action:@selector(cancelButtonPressed:)
     ] autorelease];
     
     
     id flexSpace = [[[UIBarButtonItem alloc]
     initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
     target:nil
     action:nil
     ] autorelease];
     
     id flipCamera = [[[UIBarButtonItem alloc]
     initWithBarButtonSystemItem:UIBarButtonSystemItemCompose
     target:(id)self
     action:@selector(flipCameraButtonPressed:)
     ] autorelease];
     
     NSMutableArray *items;
     
     #if USE_SHUTTER
     id shutterButton = [[[UIBarButtonItem alloc]
     initWithBarButtonSystemItem:UIBarButtonSystemItemCamera
     target:(id)self
     action:@selector(shutterButtonPressed)
     ] autorelease];
     
     if (_processor.isShowFlipCameraButton) {
     items = [NSMutableArray arrayWithObjects:flexSpace, cancelButton, flexSpace, flipCamera, shutterButton, nil];
     } else {
     items = [NSMutableArray arrayWithObjects:flexSpace, cancelButton, flexSpace, shutterButton, nil];
     }
     #else
     if (_processor.isShowFlipCameraButton) {
     items = [@[flexSpace, cancelButton, flexSpace, flipCamera] mutableCopy];
     } else {
     items = [@[flexSpace, cancelButton, flexSpace] mutableCopy];
     }
     #endif
     
     if (_processor.isShowTorchButton && !_processor.isFrontCamera) {
     AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
     if ([device hasTorch] && [device hasFlash]) {
     NSURL *bundleURL = [[NSBundle mainBundle] URLForResource:@"CDVBarcodeScanner" withExtension:@"bundle"];
     NSBundle *bundle = [NSBundle bundleWithURL:bundleURL];
     NSString *imagePath = [bundle pathForResource:@"torch" ofType:@"png"];
     UIImage *image = [UIImage imageWithContentsOfFile:imagePath];
     
     id torchButton = [[[UIBarButtonItem alloc]
     initWithImage:image
     style:UIBarButtonItemStylePlain
     target:(id)self
     action:@selector(torchButtonPressed:)
     ] autorelease];
     
     [items insertObject:torchButton atIndex:0];
     }
     }
     
     toolbar.items = items;*/
    
    bounds = overlayView.bounds;
    
    //    [toolbar sizeToFit];
    //    CGFloat toolbarHeight  = [toolbar frame].size.height;
    
    CGFloat rootViewHeight = CGRectGetHeight(bounds);
    CGFloat rootViewWidth  = CGRectGetWidth(bounds);
    //    CGRect  rectArea       = nil;//CGRectMake(0, rootViewHeight - toolbarHeight, rootViewWidth, toolbarHeight);
    //    [toolbar setFrame:rectArea];
    
    //[overlayView addSubview: toolbar];底部3个按钮
    
    
    
    
    CGFloat minAxis = MIN(rootViewHeight, rootViewWidth);//568,320
    CGRect rectArea = CGRectMake(
                                 (CGFloat) (0.5 * (rootViewWidth  - minAxis)),
                                 (CGFloat) (0.5 * (rootViewHeight - minAxis)),
                                 minAxis,
                                 minAxis
                                 );//0,124,320,320
    
    
    UIImage* reticleImage = [self buildReticleImage:overlayView];
    
    UIView* reticleView = [[[UIImageView alloc] initWithImage:reticleImage] autorelease];
    /*
     
     float f1 = reticleView.frame.origin.x;
     float f2 = reticleView.frame.origin.y;
     
     [reticleView setFrame:rectArea]; //reticleView整体下移改变大小，不是reticleImage一个下移
     
     
     [reticleView setBackgroundColor:[UIColor blueColor]];
     
     reticleView.opaque           = NO;
     reticleView.contentMode      = UIViewContentModeScaleAspectFit;
     reticleView.autoresizingMask = (UIViewAutoresizing) (0
     | UIViewAutoresizingFlexibleLeftMargin
     | UIViewAutoresizingFlexibleRightMargin
     | UIViewAutoresizingFlexibleTopMargin
     | UIViewAutoresizingFlexibleBottomMargin)
     ;*/
    
    [overlayView addSubview: reticleView];//扫描区域
    
    /*
     //UIImageView* lineView = [[UIImageView alloc] initWithFrame:CGRectMake(reticleView.origin.x, reticleView.origin.y, rectArea.size.width, 2)];
     UIImage* lineimage = [self returnImages:@"scan_line"];
     UIView* reticleView1 = [[[UIImageView alloc] initWithImage:lineimage] autorelease];
     [reticleView1 setFrame:CGRectMake(f1,f2,500,2)];
     [overlayView addSubview: reticleView1];
     */
    return overlayView;
}

//--------------------------------------------------------------------------
#define RETICLE_SIZE    500.0f
#define RETICLE_WIDTH     3.0f  //绿线的宽度和框框的厚度
#define RETICLE_OFFSET   60.0f
#define RETICLE_ALPHA     0.4f
#define line_long        20.0f
//-------------------------------------------------------------------------
// builds the green box and red line
//-------------------------------------------------------------------------
#define percent 3/4

- (UIImage*)buildReticleImage:(UIView*)overlayView{
    UIImage* result;
    /*UIGraphicsBeginImageContext(CGSizeMake(RETICLE_SIZE, RETICLE_SIZE));
     CGContextRef context = UIGraphicsGetCurrentContext();
     
     if (self.processor.is1D) { //红线
     /*UIColor* color = [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:1.0];
     CGContextSetStrokeColorWithColor(context, color.CGColor);
     
     //0
     CGContextSetLineWidth(context, RETICLE_WIDTH);
     CGContextBeginPath(context);
     
     // CGFloat lineOffset = (CGFloat) (RETICLE_OFFSET+(0.5*RETICLE_WIDTH));
     CGFloat lineOffset = (CGFloat)RETICLE_OFFSET;//60
     CGContextMoveToPoint(context, lineOffset, RETICLE_SIZE/2);
     CGContextAddLineToPoint(context, RETICLE_SIZE-lineOffset, (CGFloat) (0.5*RETICLE_SIZE));
     
     CGContextStrokePath(context);
     
     if(nil == self.processor.timer){
     self.processor.timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(moveLine) userInfo:nil repeats:YES];
     }
     
     
     //        UIView* reticleView1 = [[[UIImageView alloc] initWithImage:lineimage] autorelease];
     //        [reticleView1 setFrame:CGRectMake(RETICLE_OFFSET,RETICLE_OFFSET,100,2)];
     //        [result addSubview: reticleView1];
     //
     
     CGFloat lineOffset = (CGFloat)RETICLE_OFFSET;//60
     
     UIColor* color1 = [UIColor colorWithWhite:1.0 alpha:1.0];
     CGContextSetStrokeColorWithColor(context, color1.CGColor);
     //左上上
     CGContextSetLineWidth(context, RETICLE_WIDTH*2);
     CGContextBeginPath(context);
     
     CGContextMoveToPoint(context, lineOffset 0, lineOffset+RETICLE_WIDTH);
     CGContextAddLineToPoint(context, lineOffset+line_long, lineOffset+RETICLE_WIDTH);
     
     CGContextStrokePath(context);
     
     //左上下
     CGContextSetLineWidth(context, RETICLE_WIDTH*2);
     CGContextBeginPath(context);
     
     CGContextMoveToPoint(context, lineOffset+RETICLE_WIDTH, lineOffset);
     CGContextAddLineToPoint(context, lineOffset+RETICLE_WIDTH, lineOffset+line_long);
     
     CGContextStrokePath(context);
     
     //右上上
     CGContextSetLineWidth(context, RETICLE_WIDTH*2);
     CGContextBeginPath(context);
     
     CGContextMoveToPoint(context, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET)-line_long, lineOffset+RETICLE_WIDTH);
     CGContextAddLineToPoint(context, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET), lineOffset+RETICLE_WIDTH);
     
     CGContextStrokePath(context);
     
     //右上下
     CGContextSetLineWidth(context, RETICLE_WIDTH*2);
     CGContextBeginPath(context);
     
     CGContextMoveToPoint(context, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET)-RETICLE_WIDTH, lineOffset);
     CGContextAddLineToPoint(context, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET)-RETICLE_WIDTH, lineOffset+line_long);
     
     CGContextStrokePath(context);
     
     
     
     //左下左
     CGContextSetLineWidth(context, RETICLE_WIDTH*2);
     CGContextBeginPath(context);
     
     CGContextMoveToPoint(context, lineOffset+RETICLE_WIDTH, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET));
     CGContextAddLineToPoint(context, lineOffset+RETICLE_WIDTH, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET)-line_long);
     
     CGContextStrokePath(context);
     
     
     //左下下
     CGContextSetLineWidth(context, RETICLE_WIDTH*2);
     CGContextBeginPath(context);
     
     CGContextMoveToPoint(context, lineOffset, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET)-RETICLE_WIDTH);
     CGContextAddLineToPoint(context, lineOffset+line_long, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET)-RETICLE_WIDTH);
     
     CGContextStrokePath(context);
     
     
     //右下右
     CGContextSetLineWidth(context, RETICLE_WIDTH*2);
     CGContextBeginPath(context);
     
     CGContextMoveToPoint(context, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET)-RETICLE_WIDTH, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET));
     CGContextAddLineToPoint(context, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET)-RETICLE_WIDTH, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET)-line_long);
     
     CGContextStrokePath(context);
     
     //右下下
     CGContextSetLineWidth(context, RETICLE_WIDTH*2);
     CGContextBeginPath(context);
     
     CGContextMoveToPoint(context, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET), lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET)-RETICLE_WIDTH);
     CGContextAddLineToPoint(context, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET)-line_long, lineOffset+(RETICLE_SIZE-2*RETICLE_OFFSET)-RETICLE_WIDTH);
     
     CGContextStrokePath(context);
     
     }
     
     if (self.processor.is2D) { //白框
     UIColor* color = [UIColor colorWithWhite:1.0 alpha:1.0];
     CGContextSetStrokeColorWithColor(context, color.CGColor);
     CGContextSetLineWidth(context, RETICLE_WIDTH);
     CGContextStrokeRect(context,
     CGRectMake(
     RETICLE_OFFSET,
     RETICLE_OFFSET,
     RETICLE_SIZE-2*RETICLE_OFFSET,
     RETICLE_SIZE-2*RETICLE_OFFSET
     )
     );
     
     }
     
     */
    
    //矩形
    CGRect bounds = overlayView.bounds;
    CGFloat rootViewHeight = CGRectGetHeight(bounds);
    CGFloat rootViewWidth  = CGRectGetWidth(bounds);
    UIGraphicsBeginImageContext(CGSizeMake(rootViewWidth, rootViewHeight));
    
    CGContextRef context = UIGraphicsGetCurrentContext();
    UIColor* color = [UIColor colorWithWhite:1.0 alpha:1.0];
    CGContextSetStrokeColorWithColor(context, color.CGColor);
    CGContextSetLineWidth(context, RETICLE_WIDTH);
    
    CGFloat top = (rootViewHeight - rootViewWidth*3/4)/2;
    CGFloat bottom = rootViewHeight/2 + rootViewWidth*3/8;
    CGFloat x = rootViewWidth*1/8;
    CGFloat w = rootViewWidth*3/4;
    
    CGContextStrokeRect(context,
                        CGRectMake(
                                   x,
                                   top,
                                   w,
                                   w
                                   )
                        );
    
    //扫描线
    [self initLineView:rootViewHeight:rootViewWidth:overlayView];
    
    NSDictionary *dict = @{@"top":@(top), @"bottom":@(bottom)};
    if(nil == self.processor.timer){
        self.processor.timer = [NSTimer scheduledTimerWithTimeInterval:0.05  target:self  selector:@selector(moveLine:)  userInfo:dict  repeats:YES];
    }
    
    //4个角
    CGContextSetLineWidth(context, RETICLE_WIDTH*2);
    CGContextBeginPath(context);
    //左上上
    CGContextMoveToPoint(context, x, top + RETICLE_WIDTH);
    CGContextAddLineToPoint(context, x + line_long, top + RETICLE_WIDTH);
    //左上下
    CGContextMoveToPoint(context, x + RETICLE_WIDTH, top);
    CGContextAddLineToPoint(context, x + RETICLE_WIDTH, top + line_long);
    //右上上
    CGContextMoveToPoint(context, rootViewWidth * 7/8 - line_long, top + RETICLE_WIDTH);
    CGContextAddLineToPoint(context, rootViewWidth * 7/8, top + RETICLE_WIDTH);
    //右上下
    CGContextMoveToPoint(context, rootViewWidth * 7/8 - RETICLE_WIDTH, top);
    CGContextAddLineToPoint(context, rootViewWidth * 7/8 - RETICLE_WIDTH, top + line_long);
    //左下左
    CGContextMoveToPoint(context, x + RETICLE_WIDTH,rootViewHeight / 2 + rootViewWidth * 3/8 );
    CGContextAddLineToPoint(context, x + RETICLE_WIDTH, rootViewHeight / 2 + rootViewWidth * 3/8 - line_long);
    //左下下
    CGContextMoveToPoint(context, x, rootViewHeight / 2 + rootViewWidth * 3/8 - RETICLE_WIDTH);
    CGContextAddLineToPoint(context, x + line_long, rootViewHeight / 2 + rootViewWidth * 3/8 - RETICLE_WIDTH);
    //右下下
    CGContextMoveToPoint(context, rootViewWidth * 7/8, rootViewHeight / 2 + rootViewWidth * 3/8 - RETICLE_WIDTH);
    CGContextAddLineToPoint(context, rootViewWidth * 7/8 - line_long, rootViewHeight / 2 + rootViewWidth * 3/8 - RETICLE_WIDTH);
    //右下右
    CGContextMoveToPoint(context, rootViewWidth * 7/8 - RETICLE_WIDTH, rootViewHeight / 2 + rootViewWidth * 3/8);
    CGContextAddLineToPoint(context, rootViewWidth * 7/8 - RETICLE_WIDTH, rootViewHeight / 2 + rootViewWidth * 3/8 - line_long);
    
    CGContextStrokePath(context);
    
    result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}


- (void)initLineView:(CGFloat)rootViewHeight : (CGFloat)rootViewWidth :(UIView*)overlayView{
    _lineimage = [self returnImages:@"scan_line"];
    _reticleView1 = [[[UIImageView alloc] initWithImage:_lineimage] autorelease];
    [_reticleView1 setFrame:CGRectMake(rootViewWidth*1/8,(rootViewHeight-rootViewWidth*3/4)/2,rootViewWidth*3/4,2)];
    [overlayView addSubview: _reticleView1];
    
    //    UIColor* color = [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:1.0];
    //    CGContextSetStrokeColorWithColor(context, color.CGColor);
    //
    //    //0
    //    CGContextSetLineWidth(context, RETICLE_WIDTH);
    //    CGContextBeginPath(context);
    //
    //    // CGFloat lineOffset = (CGFloat) (RETICLE_OFFSET+(0.5*RETICLE_WIDTH));
    //    CGFloat lineOffset = (CGFloat)RETICLE_OFFSET;//60
    //    CGContextMoveToPoint(context, lineOffset, lineOffset);
    //    CGContextAddLineToPoint(context, RETICLE_SIZE-*RETICLE_OFFSET, lineOffset);
    //
    //    CGContextStrokePath(context);
    
    
    //    CGFloat mainRectWith = mainRect.size.width;
    //    CGFloat mainRectHeight = mainRect.size.height;
    //    lineView = [[UIImageView alloc] initWithFrame:CGRectMake(mainRectWith/6, mainRectHeight/2 - 2*mainRectWith/3, 2*mainRectWith/3, 2)];
    //    lineView.image = [UIImage imageNamed:@"line"];
    //    [self addSubview:lineView];
    //    lineY = lineView.frame.origin.y;
}

- (void)moveLine:(NSTimer *)timer
{
    int top = [[[timer userInfo] objectForKey:@"top"] intValue];
    int bottom = [[[timer userInfo] objectForKey:@"bottom"] intValue];
    
    CGRect frame1 = self.reticleView1.frame;
    frame1.origin.y += [self laserSpeed:frame1:top:bottom];
    if(frame1.origin.y > bottom) {frame1.origin.y = top;}
    self.reticleView1.frame = frame1;
    //self.reticleView1.frame.origin.y += 1.0;
    NSLog(@"8888888,,,%f",self.reticleView1.frame.origin.y);
}

-(int)laserSpeed:(CGRect)frame:(CGFloat)top:(CGFloat)bottom
{
    int origin_y = frame.origin.y;
    CGFloat half = (bottom + top)/2;
    if(origin_y>=top && origin_y<=half){
        float tan = 20.0/(half-top);
        return (int)roundf( tan*(origin_y - top))+1;
    }else{
        float tan = 20.0/(bottom - half);
        return (int)roundf(tan*(bottom - origin_y))+1;
    }
}

#pragma mark CDVBarcodeScannerOrientationDelegate

- (BOOL)shouldAutorotate
{
    return YES;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation
{
    return [[UIApplication sharedApplication] statusBarOrientation];
}

- (NSUInteger)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskAll;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    if ((self.orientationDelegate != nil) && [self.orientationDelegate respondsToSelector:@selector(shouldAutorotateToInterfaceOrientation:)]) {
        return [self.orientationDelegate shouldAutorotateToInterfaceOrientation:interfaceOrientation];
    }
    
    return YES;
}

- (void) willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration
{
    [UIView setAnimationsEnabled:NO];
    AVCaptureVideoPreviewLayer* previewLayer = self.processor.previewLayer;
    previewLayer.frame = self.view.bounds;
    
    if (orientation == UIInterfaceOrientationLandscapeLeft) {
        [previewLayer setOrientation:AVCaptureVideoOrientationLandscapeLeft];
    } else if (orientation == UIInterfaceOrientationLandscapeRight) {
        [previewLayer setOrientation:AVCaptureVideoOrientationLandscapeRight];
    } else if (orientation == UIInterfaceOrientationPortrait) {
        [previewLayer setOrientation:AVCaptureVideoOrientationPortrait];
    } else if (orientation == UIInterfaceOrientationPortraitUpsideDown) {
        [previewLayer setOrientation:AVCaptureVideoOrientationPortraitUpsideDown];
    }
    
    previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [UIView setAnimationsEnabled:YES];
}

@end
