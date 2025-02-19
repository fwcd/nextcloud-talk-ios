/**
 * @copyright Copyright (c) 2020 Ivan Sein <ivan@nextcloud.com>
 *
 * @author Ivan Sein <ivan@nextcloud.com>
 *
 * @license GNU GPL version 3 or any later version
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import "ShareConfirmationViewController.h"
#import "ShareConfirmationCollectionViewCell.h"

@import NextcloudKit;

#import <AVFoundation/AVFoundation.h>
#import <QuickLook/QuickLook.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <TOCropViewController/TOCropViewController.h>

#import "CCCertificate.h"
#import "NCAPIController.h"
#import "NCAppBranding.h"
#import "NCIntentController.h"
#import "NCKeyChainController.h"
#import "NCNavigationController.h"
#import "NCUserDefaults.h"
#import "NCUtils.h"
#import "MBProgressHUD.h"

#import "NextcloudTalk-Swift.h"

@interface ShareConfirmationViewController () <NKCommonDelegate, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout, QLPreviewControllerDataSource, QLPreviewControllerDelegate, ShareItemControllerDelegate, TOCropViewControllerDelegate, UIImagePickerControllerDelegate, UIDocumentPickerDelegate, UINavigationControllerDelegate>
{
    UIBarButtonItem *_sendButton;
    UIActivityIndicatorView *_sharingIndicatorView;
    MBProgressHUD *_hud;
    dispatch_group_t _uploadGroup;
    BOOL _uploadFailed;
    NSMutableArray *_uploadErrors;
    NSDictionary *_objectShareRichObject;
}

@property (nonatomic, strong) UIImagePickerController *imagePicker;

@end

@implementation ShareConfirmationViewController

- (id)initWithRoom:(NCRoom *)room account:(TalkAccount *)account serverCapabilities:(ServerCapabilities *)serverCapabilities
{
    self = [super init];
    if (self) {
        self.room = room;
        self.account = account;
        self.serverCapabilities = serverCapabilities;
        self.type = ShareConfirmationTypeItem;
    }
    
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.navigationController.navigationBar.translucent = NO;
    
    self.navigationController.navigationBar.tintColor = [NCAppBranding themeTextColor];
    self.navigationController.navigationBar.barTintColor = [NCAppBranding themeColor];
    self.tabBarController.tabBar.tintColor = [NCAppBranding themeColor];

    UIColor *themeColor = [NCAppBranding themeColor];
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = themeColor;
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName:[NCAppBranding themeTextColor]};
    self.navigationItem.standardAppearance = appearance;
    self.navigationItem.compactAppearance = appearance;
    self.navigationItem.scrollEdgeAppearance = appearance;
    
    self.pageControl.currentPageIndicatorTintColor = [NCAppBranding elementColor];
    self.pageControl.pageIndicatorTintColor = [NCAppBranding placeholderColor];
    self.pageControl.hidesForSinglePage = YES;
    self.pageControl.numberOfPages = 1;
    
    if (_isModal) {
        UIBarButtonItem *cancelButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                      target:self action:@selector(cancelButtonPressed)];
        cancelButton.accessibilityHint = NSLocalizedString(@"Double tap to dismiss sharing options", nil);
        self.navigationController.navigationBar.topItem.leftBarButtonItem = cancelButton;
    }
    
    _sendButton = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Send", nil) style:UIBarButtonItemStyleDone
                                                  target:self action:@selector(sendButtonPressed)];
    _sendButton.accessibilityHint = NSLocalizedString(@"Double tap to share with selected conversations", nil);
    self.navigationItem.rightBarButtonItem = _sendButton;
    
    _sharingIndicatorView = [[UIActivityIndicatorView alloc] init];
    _sharingIndicatorView.color = [NCAppBranding themeTextColor];
    
    // Configure communication lib
    NSString *userToken = [[NCKeyChainController sharedInstance] tokenForAccountId:_account.accountId];
    NSString *userAgent = [NSString stringWithFormat:@"Mozilla/5.0 (iOS) Nextcloud-Talk v%@", [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"]];

    [[NextcloudKit shared] setupWithAccount:_account.accountId user:_account.user userId:_account.userId password:userToken urlBase:_account.server userAgent:userAgent nextcloudVersion:_serverCapabilities.versionMajor delegate:self];
    
    // Set to section
    NSDictionary *attributes = @{NSFontAttributeName:[UIFont systemFontOfSize:15],
                                 NSForegroundColorAttributeName:[UIColor labelColor]};
    NSDictionary *subAttribute = @{NSFontAttributeName:[UIFont boldSystemFontOfSize:15],
                                   NSForegroundColorAttributeName:[UIColor tertiaryLabelColor]};
    
    NSString *localizedToString = NSLocalizedString(@"To:", @"TRANSLATORS this is for sending something 'to' a user. Eg. 'To: John Doe'");
    NSMutableAttributedString *toString = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@ %@", localizedToString, _room.displayName] attributes:attributes];
    [toString addAttributes:subAttribute range:NSMakeRange(0, [localizedToString length])];
    self.toLabel.attributedText = toString;
    
    // Toolbar section
    [self.removeItemButton setEnabled:([self.shareItemController.shareItems count] > 1)];
    [self.removeItemButton setTintColor:([self.shareItemController.shareItems count] > 1) ? nil : [UIColor clearColor]];
        
    self.shareCollectionView.delegate = self;
    
    self.shareItemController = [[ShareItemController alloc] init];
    self.shareItemController.delegate = self;
    
    NSBundle *bundle = [NSBundle bundleForClass:[ShareConfirmationCollectionViewCell class]];
    [self.shareCollectionView registerNib:[UINib nibWithNibName:kShareConfirmationTableCellNibName bundle:bundle] forCellWithReuseIdentifier:kShareConfirmationCellIdentifier];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardDidHide:) name:UIKeyboardDidHideNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    if (_type == ShareConfirmationTypeText) {
        [self.itemToolbar setHidden:YES];
        [self.shareTextView becomeFirstResponder];
    } else {
        [self addMenuToAddButton];
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    if (_type == ShareConfirmationTypeText) {
        return;
    }
    
    // Hide the collection view
    [self.shareCollectionView setHidden:YES];
    // Invalidate layout to remove warning about item size must be less than UICollectionView
    [self.shareCollectionView.collectionViewLayout invalidateLayout];
    ShareItem *currentItem =  [self getCurrentShareItem];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        // Invalidate the view now so cell size is correctly calculated
        // The size of the collection view is correct at this moment
        [self.shareCollectionView.collectionViewLayout invalidateLayout];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        // Scroll to the element and make collection view appear
        [self scrollToItem:currentItem animated:NO];
        [self.shareCollectionView setHidden:NO];
    }];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Button Actions

- (void)cancelButtonPressed
{
    [self.delegate shareConfirmationViewControllerDidFinish:self];
}

- (void)sendButtonPressed
{
    if (_type == ShareConfirmationTypeText) {
        [self sendSharedText];
    } else if (_type == ShareConfirmationTypeObjectShare) {
        [self sendObjectShare];
    } else {
        [self uploadAndShareFiles];
    }
    
    [self startAnimatingSharingIndicator];
}

- (IBAction)removeItemButtonPressed:(id)sender {
    ShareItem *item = [self getCurrentShareItem];
    
    if (item) {
        [self.shareItemController removeItem:item];
    }
}

- (IBAction)cropItemButtonPressed:(id)sender {
    ShareItem *item = [self getCurrentShareItem];
    UIImage *image = [self.shareItemController getImageFromItem:item];
    
    if (!image) {
        return;
    }
    
    TOCropViewController *cropViewController = [[TOCropViewController alloc] initWithImage:image];
    cropViewController.delegate = self;
    [self presentViewController:cropViewController animated:YES completion:nil];
}

- (IBAction)previewItemButtonPressed:(id)sender {
    [self previewCurrentItem];
}

- (void)shareText:(NSString *)sharedText
{
    _type = ShareConfirmationTypeText;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.shareCollectionView.hidden = YES;
        self.itemToolbar.hidden = YES;
        self.shareTextView.hidden = NO;
        self.shareTextView.text = sharedText;
    });
}

- (void)shareObjectShareMessage:(NCChatMessage *)objectShareMessage
{
    _type = ShareConfirmationTypeObjectShare;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.shareCollectionView.hidden = YES;
        self.itemToolbar.hidden = YES;
        self.shareTextView.hidden = NO;
        self.shareTextView.userInteractionEnabled = NO;
        self.shareTextView.text = objectShareMessage.parsedMessage.string;
        self->_objectShareRichObject = objectShareMessage.richObjectFromObjectShare;
    });
}

- (void)setIsModal:(BOOL)isModal
{
    _isModal = isModal;
}

#pragma mark - Add additional items

- (void)addMenuToAddButton
{
    NSMutableArray *items = [[NSMutableArray alloc] init];

    UIAction *cameraAction = [UIAction actionWithTitle:NSLocalizedString(@"Camera", nil)
                                                 image:[UIImage systemImageNamed:@"camera"]
                                            identifier:nil
                                               handler:^(UIAction *action) {
        [self checkAndPresentCamera];
    }];

    UIAction *photoLibraryAction = [UIAction actionWithTitle:NSLocalizedString(@"Photo Library", nil)
                                                       image:[UIImage systemImageNamed:@"photo"]
                                                  identifier:nil
                                                     handler:^(UIAction *action) {
        [self presentPhotoLibrary];
    }];


    UIAction *filesAction = [UIAction actionWithTitle:NSLocalizedString(@"Files", nil)
                                                image:[UIImage systemImageNamed:@"doc"]
                                           identifier:nil
                                              handler:^(UIAction *action) {
        [self presentDocumentPicker];
    }];


#ifndef APP_EXTENSION
    // Camera access is not available in app extensions
    // https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html
    if ([UIImagePickerController isSourceTypeAvailable: UIImagePickerControllerSourceTypeCamera]) {
        [items addObject:cameraAction];
    }
#endif

    [items addObject:photoLibraryAction];
    [items addObject:filesAction];

    self.addItemButton.menu = [UIMenu menuWithTitle:@"" children:items];
}

- (void)checkAndPresentCamera
{
    // https://stackoverflow.com/a/20464727/2512312
    NSString *mediaType = AVMediaTypeVideo;
    AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:mediaType];
    
    if(authStatus == AVAuthorizationStatusAuthorized) {
        [self presentCamera];
        return;
    } else if(authStatus == AVAuthorizationStatusNotDetermined){
        [AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
            if(granted){
                [self presentCamera];
            }
        }];
        return;
    }
    
    UIAlertController * alert = [UIAlertController
                                 alertControllerWithTitle:NSLocalizedString(@"Could not access camera", nil)
                                 message:NSLocalizedString(@"Camera access is not allowed. Check your settings.", nil)
                                 preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction* okButton = [UIAlertAction
                               actionWithTitle:NSLocalizedString(@"OK", nil)
                               style:UIAlertActionStyleDefault
                               handler:nil];
    
    [alert addAction:okButton];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentCamera
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_imagePicker = [[UIImagePickerController alloc] init];
        self->_imagePicker.sourceType = UIImagePickerControllerSourceTypeCamera;
        self->_imagePicker.cameraFlashMode = [NCUserDefaults preferredCameraFlashMode];
        self->_imagePicker.mediaTypes = [UIImagePickerController availableMediaTypesForSourceType:self->_imagePicker.sourceType];
        self->_imagePicker.delegate = self;
        [self presentViewController:self->_imagePicker animated:YES completion:nil];
    });
}

- (void)presentPhotoLibrary
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_imagePicker = [[UIImagePickerController alloc] init];
        self->_imagePicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        self->_imagePicker.mediaTypes = [UIImagePickerController availableMediaTypesForSourceType:self->_imagePicker.sourceType];
        self->_imagePicker.delegate = self;
        [self presentViewController:self->_imagePicker animated:YES completion:nil];
    });
}

- (void)presentDocumentPicker
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.item"] inMode:UIDocumentPickerModeImport];
        documentPicker.delegate = self;
        [self presentViewController:documentPicker animated:YES completion:nil];
    });
}

#pragma mark - Actions

- (void)sendSharedText
{
    [[NCAPIController sharedInstance] sendChatMessage:self.shareTextView.text toRoom:_room.token displayName:nil replyTo:-1 referenceId:nil silently:NO forAccount:_account withCompletionBlock:^(NSError *error) {
        if (error) {
            NSLog(@"Failed to send shared item");
            [self.delegate shareConfirmationViewControllerDidFailed:self];
        } else {
            [[NCIntentController sharedInstance] donateSendMessageIntentForRoom:self->_room];
            [self.delegate shareConfirmationViewControllerDidFinish:self];
        }
        [self stopAnimatingSharingIndicator];
    }];
}

- (void)sendObjectShare
{
    [[NCAPIController sharedInstance] shareRichObject:_objectShareRichObject inRoom:_room.token forAccount:_account withCompletionBlock:^(NSError *error) {
        if (error) {
            [self.delegate shareConfirmationViewControllerDidFailed:self];
            NSLog(@"Failed to send shared item");
        } else {
            [self.delegate shareConfirmationViewControllerDidFinish:self];
        }
        [self stopAnimatingSharingIndicator];
    }];
}

- (void)updateHudProgress
{
    if (!_hud) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        CGFloat progress = 0;
        long items = 0;
        
        for (ShareItem *item in self->_shareItemController.shareItems) {
            progress += item.uploadProgress;
            items++;
        }
        
        self->_hud.progress = (progress / items);
    });
}

- (void)uploadAndShareFiles
{
    BGTaskHelper *bgTask = [BGTaskHelper startBackgroundTaskWithName:@"uploadAndShareFiles" expirationHandler:nil];

    _hud = [MBProgressHUD showHUDAddedTo:self.view animated:YES];
    _hud.mode = MBProgressHUDModeAnnularDeterminate;
    _hud.label.text = [NSString stringWithFormat:NSLocalizedString(@"Uploading %ld elements", nil), [self.shareItemController.shareItems count]];
    
    if ([self.shareItemController.shareItems count] == 1) {
        _hud.label.text = NSLocalizedString(@"Uploading 1 element", nil);
    }
    
    _uploadGroup = dispatch_group_create();
    _uploadFailed = NO;
    _uploadErrors = [[NSMutableArray alloc] init];
    
    for (ShareItem *item in self.shareItemController.shareItems) {
        NSLog(@"Uploading %@", item.fileURL);
        
        dispatch_group_enter(_uploadGroup);
        [[NCAPIController sharedInstance] uniqueNameForFileUploadWithName:item.fileName originalName:YES forAccount:_account withCompletionBlock:^(NSString *fileServerURL, NSString *fileServerPath, NSInteger errorCode, NSString *errorDescription) {
            if (fileServerURL && fileServerPath) {
                [self uploadFileToServerURL:fileServerURL withFilePath:fileServerPath withItem:item];
            } else {
                self->_uploadFailed = YES;
                [self->_uploadErrors addObject:errorDescription];
                dispatch_group_leave(self->_uploadGroup);
            }
        }];
    }
    
    dispatch_group_notify(_uploadGroup, dispatch_get_main_queue(),^{
        [self stopAnimatingSharingIndicator];
        [self->_hud hideAnimated:YES];
        
        [self->_shareItemController removeAllItems];
        
        // TODO: Do error reporting per item
        if (self->_uploadFailed) {
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"Upload failed", nil)
                                         message:[self->_uploadErrors componentsJoinedByString:@"\n"]
                                         preferredStyle:UIAlertControllerStyleAlert];
            
            UIAlertAction* okButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"OK", nil)
                                       style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction * _Nonnull action) {
                                            [self.delegate shareConfirmationViewControllerDidFailed:self];
                                        }];
            
            [alert addAction:okButton];
            [self presentViewController:alert animated:YES completion:nil];
        } else {
            [self.delegate shareConfirmationViewControllerDidFinish:self];
        }

        [bgTask stopBackgroundTask];
    });
}

- (void)uploadFileToServerURL:(NSString *)fileServerURL withFilePath:(NSString *)filePath withItem:(ShareItem *)item
{
    [[NextcloudKit shared] uploadWithServerUrlFileName:fileServerURL fileNameLocalPath:item.filePath dateCreationFile:nil dateModificationFile:nil customUserAgent:nil addCustomHeaders:nil queue:dispatch_get_main_queue() taskHandler:^(NSURLSessionTask *task) {
        NSLog(@"Upload task");
    } progressHandler:^(NSProgress *progress) {
        item.uploadProgress = progress.fractionCompleted;
        [self updateHudProgress];
    } completionHandler:^(NSString *accountId, NSString *ocId, NSString *etag, NSDate *date, int64_t size, NSDictionary *allHeaderFields, NKError *error) {
        if (error.errorCode == 0) {
            [[NCAPIController sharedInstance] shareFileOrFolderForAccount:self->_account atPath:filePath toRoom:self->_room.token talkMetaData:nil withCompletionBlock:^(NSError *error) {
                if (error) {
                    NSLog(@"Failed to send shared file");

                    self->_uploadFailed = YES;
                    [self->_uploadErrors addObject:error.description];
                }

                dispatch_group_leave(self->_uploadGroup);
            }];
        } else if (error.errorCode == 404 || error.errorCode == 409) {
            [[NCAPIController sharedInstance] checkOrCreateAttachmentFolderForAccount:self->_account withCompletionBlock:^(BOOL created, NSInteger errorCode) {
                if (created) {
                    [self uploadFileToServerURL:fileServerURL withFilePath:filePath withItem:item];
                } else {
                    self->_uploadFailed = YES;
                    [self->_uploadErrors addObject:error.errorDescription];
                    dispatch_group_leave(self->_uploadGroup);
                }
            }];
        } else {
            self->_uploadFailed = YES;
            [self->_uploadErrors addObject:error.errorDescription];
            dispatch_group_leave(self->_uploadGroup);
        }
    }];
}

#pragma mark - User Interface

- (void)startAnimatingSharingIndicator
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_sharingIndicatorView startAnimating];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self->_sharingIndicatorView];
    });
}

- (void)stopAnimatingSharingIndicator
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_sharingIndicatorView stopAnimating];
        self.navigationItem.rightBarButtonItem = self->_sendButton;
    });
}

-(void)keyboardWillShow:(NSNotification *)notification
{
    // see https://stackoverflow.com/a/22719225/2512312
    NSDictionary *info = notification.userInfo;
    NSValue *value = info[UIKeyboardFrameEndUserInfoKey];
    
    CGRect rawFrame = [value CGRectValue];
    CGRect keyboardFrame = [self.view convertRect:rawFrame fromView:nil];
    
    [UIView animateWithDuration:0.3 animations:^{
        self.bottomSpacer.constant = keyboardFrame.size.height;
        [self.view layoutIfNeeded];
    }];
}

-(void)keyboardDidHide:(NSNotification *)notification
{
    [UIView animateWithDuration:0.3 animations:^{
        self.bottomSpacer.constant = 0;
        [self.view layoutIfNeeded];
    }];
}

- (void)updateToolbarForCurrentItem
{
    ShareItem *item = [self getCurrentShareItem];
    
    if (item) {
        [UIView transitionWithView:self.itemToolbar duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
            [self.cropItemButton setEnabled:item.isImage];
            [self.previewItemButton setEnabled:[QLPreviewController canPreviewItem:item.fileURL]];
            [self.addItemButton setEnabled:([self.shareItemController.shareItems count] < 5)];
        } completion:nil];
    }
    
    [self.removeItemButton setEnabled:([self.shareItemController.shareItems count] > 1)];
    [self.removeItemButton setTintColor:([self.shareItemController.shareItems count] > 1) ? nil : [UIColor clearColor]];
}

#pragma mark - UIImagePickerController Delegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    [self saveImagePickerSettings:picker];
    
    NSString *mediaType = [info objectForKey:UIImagePickerControllerMediaType];
    if ([mediaType isEqualToString:@"public.image"]) {
        UIImage *image = [info objectForKey:UIImagePickerControllerOriginalImage];
        
        [self dismissViewControllerAnimated:YES completion:^{
            [self.shareItemController addItemWithImage:image];
            [self collectionViewScrollToEnd];
        }];
    } else if ([mediaType isEqualToString:@"public.movie"]) {
        NSURL *videoURL = [info objectForKey:UIImagePickerControllerMediaURL];
        
        [self dismissViewControllerAnimated:YES completion:^{
            [self.shareItemController addItemWithURL:videoURL];
            [self collectionViewScrollToEnd];
        }];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [self saveImagePickerSettings:picker];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveImagePickerSettings:(UIImagePickerController *)picker
{
    if (picker.sourceType == UIImagePickerControllerSourceTypeCamera &&
        picker.cameraCaptureMode == UIImagePickerControllerCameraCaptureModePhoto) {
        [NCUserDefaults setPreferredCameraFlashMode:picker.cameraFlashMode];
    }
}

#pragma mark - UIDocumentPickerViewController Delegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    [self shareDocumentsWithURLs:urls fromController:controller];
}

- (void)shareDocumentsWithURLs:(NSArray<NSURL *> *)urls fromController:(UIDocumentPickerViewController *)controller
{
    if (controller.documentPickerMode == UIDocumentPickerModeImport) {
        for (NSURL* url in urls) {
            [self.shareItemController addItemWithURL:url];
        }
        
        [self collectionViewScrollToEnd];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    
}

#pragma mark - ScrollView/CollectionView

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ShareConfirmationCollectionViewCell *cell = (ShareConfirmationCollectionViewCell *)[collectionView dequeueReusableCellWithReuseIdentifier:kShareConfirmationCellIdentifier forIndexPath:indexPath];
    ShareItem *item = [self.shareItemController.shareItems objectAtIndex:indexPath.row];
    
    // Setting placeholder here in case we can't generate any other preview
    [cell setPlaceHolderImage:item.placeholderImage];
    [cell setPlaceHolderText:item.fileName];

    // Check if we got an image
    UIImage *image = [self.shareItemController getImageFromItem:item];
    
    if (image) {
        // We're able to get an image directly from the fileURL -> use it
        [cell setPreviewImage:image];
    } else {
        // We need to generate our own preview/thumbnail here
        [self generatePreviewForCell:cell withCollectionView:collectionView withItem:item];
    }
    
    return cell;
}

- (void)generatePreviewForCell:(ShareConfirmationCollectionViewCell *)cell withCollectionView:(UICollectionView *)collectionView withItem:(ShareItem *)item
{
    CGSize size = CGSizeMake(collectionView.bounds.size.width, collectionView.bounds.size.height);
    CGFloat scale = [UIScreen mainScreen].scale;

    // updateHandler might be called multiple times, starting from low quality representation to high-quality
    QLThumbnailGenerationRequest *request = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:item.fileURL size:size scale:scale representationTypes:(QLThumbnailGenerationRequestRepresentationTypeLowQualityThumbnail | QLThumbnailGenerationRequestRepresentationTypeThumbnail)];
    [QLThumbnailGenerator.sharedGenerator generateRepresentationsForRequest:request updateHandler:^(QLThumbnailRepresentation * _Nullable thumbnail, QLThumbnailRepresentationType type, NSError * _Nullable error) {
        if (error) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [cell setPreviewImage:thumbnail.UIImage];
        });
    }];
}

- (NSInteger)collectionView:(nonnull UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return [self.shareItemController.shareItems count];
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 1;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    return CGSizeMake(collectionView.bounds.size.width, collectionView.bounds.size.height);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [self previewCurrentItem];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    [self updatePageControlPage];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView
{
    [self updatePageControlPage];
}

- (void)collectionViewScrollToEnd
{
    [self scrollToItem:self.shareItemController.shareItems.lastObject animated:YES];
}

- (void)scrollToItem:(ShareItem *)item animated:(BOOL)animated
{
    if (!item) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger indexForItem = [self.shareItemController.shareItems indexOfObject:item];
        
        if (indexForItem != NSNotFound) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForItem:indexForItem inSection:0];
            [self.shareCollectionView scrollToItemAtIndexPath:indexPath
                                             atScrollPosition:UICollectionViewScrollPositionNone
                                                     animated:animated];
        }
    });
}

- (ShareItem *)getCurrentShareItem
{
    NSInteger currentIndex = self.shareCollectionView.contentOffset.x / self.shareCollectionView.frame.size.width;
    
    if (currentIndex >= [self.shareItemController.shareItems count]) {
        return nil;
    }
    
    return [self.shareItemController.shareItems objectAtIndex:currentIndex];
}

#pragma mark - PageControl

- (IBAction)pageControlValueChanged:(id)sender
{
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:self.pageControl.currentPage inSection:0];
    [self.shareCollectionView scrollToItemAtIndexPath:indexPath
                                     atScrollPosition:UICollectionViewScrollPositionNone
                                             animated:YES];
}

- (void)updatePageControlPage
{
    // see: https://stackoverflow.com/a/46181277/2512312
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pageControl.currentPage = self.shareCollectionView.contentOffset.x / self.shareCollectionView.frame.size.width;
        
        [self updateToolbarForCurrentItem];
    });
}

#pragma mark - PreviewController

- (void)previewCurrentItem
{
    ShareItem *item = [self getCurrentShareItem];
    
    // Only open preview if there's an actual item and it can be previewed
    if (!item || !item.fileURL || ![QLPreviewController canPreviewItem:item.fileURL]) {
        return;
    }
    
    QLPreviewController * preview = [[QLPreviewController alloc] init];
    preview.dataSource = self;
    preview.delegate = self;
    
    preview.navigationController.navigationBar.tintColor = [NCAppBranding themeTextColor];
    preview.navigationController.navigationBar.barTintColor = [NCAppBranding themeColor];
    preview.tabBarController.tabBar.tintColor = [NCAppBranding themeColor];

    UIColor *themeColor = [NCAppBranding themeColor];
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = themeColor;
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName:[NCAppBranding themeTextColor]};
    preview.navigationItem.standardAppearance = appearance;
    preview.navigationItem.compactAppearance = appearance;
    preview.navigationItem.scrollEdgeAppearance = appearance;

    [self.navigationController pushViewController:preview animated:YES];
}

- (nonnull id<QLPreviewItem>)previewController:(nonnull QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    // Don't use index here, as this relates to numberOfPreviewItems
    // When we have numberOfPreviewItems > 1 this will show an additional list of items
    ShareItem *item = [self getCurrentShareItem];
    
    if (item && item.fileURL) {
        return item.fileURL;
    }
    
    return nil;
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller
{
    return 1;
}

- (QLPreviewItemEditingMode)previewController:(QLPreviewController *)controller editingModeForPreviewItem:(id<QLPreviewItem>)previewItem {
    return QLPreviewItemEditingModeCreateCopy;
}

- (void)previewController:(QLPreviewController *)controller didSaveEditedCopyOfPreviewItem:(id<QLPreviewItem>)previewItem atURL:(NSURL *)modifiedContentsURL {
    ShareItem *item = [self getCurrentShareItem];
    
    if (item) {
        [self.shareItemController updateItem:item withURL:modifiedContentsURL];
    }
}


#pragma mark - ShareItemController Delegate
 
- (void)shareItemControllerItemsChanged:(nonnull ShareItemController *)shareItemController {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger shareItemCount = [shareItemController.shareItems count];
        
        if (shareItemCount == 0) {
            if (self.extensionContext) {
                NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain code:0 userInfo:nil];
                [self.extensionContext cancelRequestWithError:error];
            } else {
                [self dismissViewControllerAnimated:YES completion:nil];
            }
        } else {
            [self.shareCollectionView reloadData];
            
            // Make sure all changes are full populated before we update our ui elements
            [self.shareCollectionView layoutIfNeeded];
            [self updateToolbarForCurrentItem];
            self.pageControl.numberOfPages = [shareItemController.shareItems count];
        }
    });
}

#pragma mark - TOCropViewController Delegate

- (void)cropViewController:(TOCropViewController *)cropViewController didCropToImage:(UIImage *)image withRect:(CGRect)cropRect angle:(NSInteger)angle
{
    ShareItem *item = [self getCurrentShareItem];
    
    if (item) {
        [self.shareItemController updateItem:item withImage:image];
        
        // Fixes bug on iPad where collectionView is scrolled between two pages
        [self scrollToItem:item animated:YES];
    }

    // Fixes weird iOS 13 bug: https://github.com/TimOliver/TOCropViewController/issues/365
    cropViewController.transitioningDelegate = nil;
    [cropViewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)cropViewController:(TOCropViewController *)cropViewController didFinishCancelled:(BOOL)cancelled
{
    ShareItem *item = [self getCurrentShareItem];
    
    if (item) {
        // Fixes bug on iPad where collectionView is scrolled between two pages
        [self scrollToItem:item animated:YES];
    }
    
    // Fixes weird iOS 13 bug: https://github.com/TimOliver/TOCropViewController/issues/365
    cropViewController.transitioningDelegate = nil;
    [cropViewController dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - NKCommon Delegate

- (void)authenticationChallenge:(NSURLSession *)session didReceive:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler
{
    // The pinnning check
    if ([[CCCertificate sharedManager] checkTrustedChallenge:challenge]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

@end
