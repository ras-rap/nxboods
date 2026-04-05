#import "MainViewController.h"
#import "AppDelegate.h"
#import "FLBootProfile+CoreDataClass.h"
#import "NXExec.h"
#import "NXUSBDeviceEnumerator.h"
#import "NXKernel.h"
#import "PayloadStorage.h"
#import "Settings.h"

#pragma mark - Exploit Tab

@interface ExploitViewController : UITableViewController
@property (nonatomic, strong) UIColor *textColorButton;
@property (nonatomic, strong) UIColor *textColorInactive;
@property (nonatomic, assign) BOOL hasOffsets;
@property (nonatomic, assign) BOOL downloadingOffsets;
@property (nonatomic, assign) BOOL exploitRunning;
@property (nonatomic, assign) BOOL exploitReady;
@property (nonatomic, assign) BOOL patchingEntitlements;
@property (nonatomic, assign) BOOL entitlementsPatched;
@property (nonatomic, assign) BOOL exploitFailed;
@property (nonatomic, assign) double exploitProgress;
@property (nonatomic, strong, nullable) NSString *kernelBaseText;
@property (nonatomic, strong, nullable) NSString *kernelSlideText;
@property (nonatomic, strong, nullable) NSMutableArray<NSString *> *logs;
@end

@implementation ExploitViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Exploit";
    if (@available(iOS 13, *)) {
        self.tabBarItem.image = [UIImage systemImageNamed:@"bolt.fill"];
    } else {
        self.tabBarItem.image = [UIImage imageNamed:@""];
    }

    self.textColorButton = [UIColor colorWithRed:0.001 green:0.732 blue:0.883 alpha:1.0];
    if (@available(iOS 13, *)) {
        self.textColorInactive = [UIColor secondaryLabelColor];
    } else {
        self.textColorInactive = [UIColor colorWithRed:0.235 green:0.235 blue:0.263 alpha:0.6];
    }

    self.hasOffsets = NXKernelHasOffsets();
    self.downloadingOffsets = NO;
    self.exploitRunning = NO;
    self.exploitReady = NO;
    self.patchingEntitlements = NO;
    self.entitlementsPatched = NO;
    self.exploitFailed = NO;
    self.exploitProgress = 0.0;
    self.kernelBaseText = nil;
    self.kernelSlideText = nil;
    self.logs = [NSMutableArray array];

    self.tableView.estimatedRowHeight = 44;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    if (!NXKernelIsSupported()) {
        self.exploitFailed = YES;
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appendLog:)
                                                 name:@"NXKernelLog"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)appendLog:(NSNotification *)note {
    NSString *msg = note.userInfo[@"message"];
    if (msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.logs addObject:msg];
            if (self.logs.count > 200) {
                [self.logs removeObjectAtIndex:0];
            }
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:3]
                          withRowAnimation:UITableViewRowAnimationNone];
        });
    }
}

- (void)downloadOffsets {
    if (self.downloadingOffsets || self.exploitRunning) return;
    self.downloadingOffsets = YES;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL ok = NXKernelDownloadOffsets();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.downloadingOffsets = NO;
            self.hasOffsets = ok;
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
            if (!ok) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Download Failed"
                                                                             message:@"Could not download kernelcache. Check your internet connection."
                                                                      preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            }
        });
    });
}

- (void)runExploit {
    if (self.exploitRunning || !self.hasOffsets) return;
    self.exploitRunning = YES;
    self.exploitProgress = 0.0;
    self.exploitFailed = NO;
    [self.logs removeAllObjects];
    [self.tableView reloadData];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NXKernelInitOffsets();
        NXKernelStatus status = NXKernelRun();

        dispatch_async(dispatch_get_main_queue(), ^{
            self.exploitRunning = NO;
            self.exploitProgress = 1.0;
            if (status == NXKernelStatusReady) {
                self.exploitReady = YES;
                self.kernelBaseText = [NSString stringWithFormat:@"0x%llx", NXKernelGetBase()];
                self.kernelSlideText = [NSString stringWithFormat:@"0x%llx", NXKernelGetSlide()];
                [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
            } else {
                self.exploitFailed = YES;
                [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
            }
        });
    });
}

- (void)patchEntitlements {
    if (self.patchingEntitlements || self.entitlementsPatched || !self.exploitReady) return;
    self.patchingEntitlements = YES;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int result = NXKernelPatchCSFlags();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.patchingEntitlements = NO;
            self.entitlementsPatched = (result == 0);
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
            if (!self.entitlementsPatched) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Patch Failed"
                                                                             message:@"Could not patch code signing flags. USB access may not work."
                                                                      preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            } else {
                // Notify the switch tab that USB can now start
                [[NSNotificationCenter defaultCenter] postNotificationName:@"NXKernelEntitlementsPatched" object:nil];
            }
        });
    });
}

#pragma mark - Table Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;
        case 1: return 1;
        case 2: return 1;
        case 3: return self.logs.count > 0 ? self.logs.count : 1;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Step 1 — Kernelcache";
        case 1: return @"Step 2 — Exploit";
        case 2: return @"Step 3 — Entitlements";
        case 3: return @"Log";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Download and resolve kernel offsets. This is a one-time operation.";
        case 1: return @"Run the Darksword IOSurface/ICMPv6 exploit to gain kernel read/write.";
        case 2: return @"Patch code signing flags to grant unrestricted IOKit access (required for USB).";
        case 3: return nil;
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"StepCell" forIndexPath:indexPath];
            if (self.hasOffsets) {
                cell.textLabel.text = @"Offsets cached ✓";
                cell.textLabel.textColor = [UIColor systemGreenColor];
                cell.detailTextLabel.text = @"Ready for exploit";
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
                cell.userInteractionEnabled = NO;
            } else if (self.downloadingOffsets) {
                cell.textLabel.text = @"Downloading kernelcache...";
                cell.textLabel.textColor = [UIColor systemOrangeColor];
                cell.detailTextLabel.text = nil;
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.userInteractionEnabled = NO;
            } else {
                cell.textLabel.text = @"Download Kernelcache Offsets";
                cell.textLabel.textColor = self.textColorButton;
                cell.detailTextLabel.text = @"One-time download (~30 MB)";
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.userInteractionEnabled = YES;
            }
            return cell;
        }
        case 1: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"StepCell" forIndexPath:indexPath];
            if (self.exploitRunning) {
                cell.textLabel.text = [NSString stringWithFormat:@"Running exploit... %d%%", (int)(self.exploitProgress * 100)];
                cell.textLabel.textColor = [UIColor systemOrangeColor];
                cell.detailTextLabel.text = nil;
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.userInteractionEnabled = NO;
            } else if (self.exploitReady) {
                cell.textLabel.text = @"Exploit succeeded ✓";
                cell.textLabel.textColor = [UIColor systemGreenColor];
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Base: %@  Slide: %@", self.kernelBaseText, self.kernelSlideText];
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
                cell.userInteractionEnabled = NO;
            } else if (self.exploitFailed) {
                cell.textLabel.text = @"Exploit failed — tap to retry";
                cell.textLabel.textColor = [UIColor systemRedColor];
                cell.detailTextLabel.text = nil;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.userInteractionEnabled = YES;
            } else if (!self.hasOffsets) {
                cell.textLabel.text = @"Run Exploit";
                cell.textLabel.textColor = self.textColorInactive;
                cell.detailTextLabel.text = @"Download offsets first";
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.userInteractionEnabled = NO;
            } else {
                cell.textLabel.text = @"Run Exploit";
                cell.textLabel.textColor = self.textColorButton;
                cell.detailTextLabel.text = @"Darksword IOSurface/ICMPv6";
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.userInteractionEnabled = YES;
            }
            return cell;
        }
        case 2: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"StepCell" forIndexPath:indexPath];
            if (self.entitlementsPatched) {
                cell.textLabel.text = @"Entitlements patched ✓";
                cell.textLabel.textColor = [UIColor systemGreenColor];
                cell.detailTextLabel.text = @"IOKit USB access granted";
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
                cell.userInteractionEnabled = NO;
            } else if (self.patchingEntitlements) {
                cell.textLabel.text = @"Patching csflags...";
                cell.textLabel.textColor = [UIColor systemOrangeColor];
                cell.detailTextLabel.text = nil;
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.userInteractionEnabled = NO;
            } else if (!self.exploitReady) {
                cell.textLabel.text = @"Patch Entitlements";
                cell.textLabel.textColor = self.textColorInactive;
                cell.detailTextLabel.text = @"Exploit kernel first";
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.userInteractionEnabled = NO;
            } else {
                cell.textLabel.text = @"Patch Entitlements";
                cell.textLabel.textColor = self.textColorButton;
                cell.detailTextLabel.text = @"CS_PLATFORM_BINARY + CS_DEBUGGED";
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.userInteractionEnabled = YES;
            }
            return cell;
        }
        case 3: {
            if (self.logs.count == 0) {
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LogCell"];
                if (!cell) {
                    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LogCell"];
                    cell.textLabel.font = [UIFont fontWithName:@"Menlo" size:11];
                    cell.textLabel.numberOfLines = 0;
                }
                cell.textLabel.text = @"No log entries yet";
                cell.textLabel.textColor = self.textColorInactive;
                return cell;
            } else {
                NSString *msg = self.logs[indexPath.row];
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LogCell"];
                if (!cell) {
                    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LogCell"];
                    cell.textLabel.font = [UIFont fontWithName:@"Menlo" size:11];
                    cell.textLabel.numberOfLines = 0;
                }
                cell.textLabel.text = msg;
                return cell;
            }
        }
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch (indexPath.section) {
        case 0:
            if (!self.hasOffsets && !self.downloadingOffsets) [self downloadOffsets];
            break;
        case 1:
            if (self.hasOffsets && !self.exploitRunning && !self.exploitReady) [self runExploit];
            break;
        case 2:
            if (self.exploitReady && !self.patchingEntitlements && !self.entitlementsPatched) [self patchEntitlements];
            break;
    }
}

@end

#pragma mark - Switch Tab

@interface SwitchViewController : UITableViewController
@property (nonatomic, strong) UIColor *textColorButton;
@property (nonatomic, strong) UIColor *textColorInactive;
@property (nonatomic, strong) NSDateFormatter *payloadDateFormatter;
@property (nonatomic, strong) PayloadStorage *payloadStorage;
@property (nonatomic, strong) NSMutableArray<Payload *> *payloads;
@property (nonatomic, strong, nullable) Payload *selectedPayload;
@property (nonatomic, strong) NXUSBDeviceEnumerator *usbEnum;
@property (nonatomic, strong, nullable) NXUSBDevice *usbDevice;
@property (nonatomic, strong, nullable) NSString *usbStatus;
@property (nonatomic, strong, nullable) NSString *usbError;
@property (nonatomic, assign) BOOL entitlementsPatched;
@end

@implementation SwitchViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Switch";
    if (@available(iOS 13, *)) {
        self.tabBarItem.image = [UIImage systemImageNamed:"gamecontroller.fill"];
    }

    self.textColorButton = [UIColor colorWithRed:0.001 green:0.732 blue:0.883 alpha:1.0];
    if (@available(iOS 13, *)) {
        self.textColorInactive = [UIColor secondaryLabelColor];
    } else {
        self.textColorInactive = [UIColor colorWithRed:0.235 green:0.235 blue:0.263 alpha:0.6];
    }

    self.payloadDateFormatter = [[NSDateFormatter alloc] init];
    self.payloadDateFormatter.dateStyle = NSDateFormatterMediumStyle;
    self.payloadDateFormatter.timeStyle = NSDateFormatterNoStyle;

    self.payloadStorage = [PayloadStorage sharedPayloadStorage];
    self.payloads = [[self.payloadStorage loadPayloads] mutableCopy];

    self.usbEnum = [[NXUSBDeviceEnumerator alloc] init];
    self.usbEnum.delegate = self;
    [self.usbEnum setFilterForVendorID:kTegraX1VendorID productID:kTegraX1ProductID];
    // Don't start until entitlements are patched

    self.entitlementsPatched = NO;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(entitlementsPatchedNotification:)
                                                 name:@"NXKernelEntitlementsPatched"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshPayloadList)
                                                 name:NXBootPayloadStorageChangedExternally
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.usbEnum stop];
}

- (void)entitlementsPatchedNotification:(NSNotification *)note {
    self.entitlementsPatched = YES;
    [self.usbEnum start];
    [self.tableView reloadData];
}

- (void)refreshPayloadList {
    self.payloads = [[self.payloadStorage loadPayloads] mutableCopy];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)bootPayload:(Payload *)payload {
    NSData *relocator = [PayloadStorage relocator];
    if (!relocator) return;
    NSData *payloadData = payload.data;
    if (!payloadData) {
        self.usbError = @"Failed to load payload data from disk.";
        [self updateDeviceStatus:@"Error loading payload"];
        return;
    }
    if (!self.usbDevice) return;
    NSString *error = nil;
    if (NXExec(self.usbDevice, relocator, payloadData, &error)) {
        self.usbError = nil;
        [self updateDeviceStatus:@"Payload injected"];
    } else {
        self.usbError = error;
        [self updateDeviceStatus:@"Payload injection error"];
    }
    if (error) NSLog(@"Switch boot failed: %@", error);
}

- (void)updateDeviceStatus:(NSString *)status {
    self.usbStatus = status;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;
        case 1: {
            if (self.payloads.count == 0) return 1;
            return self.payloads.count;
        }
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Device";
        case 1: return @"Payloads";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case 0: {
            if (self.usbError) return self.usbError;
            if (!self.entitlementsPatched) return @"Patch entitlements in the Exploit tab first to enable USB access.";
            return @"Connect your Nintendo Switch in RCM mode via a Lightning OTG adapter.";
        }
        case 1: return @"Activate a payload to boot it automatically.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DeviceCell" forIndexPath:indexPath];
            if (!self.entitlementsPatched) {
                cell.textLabel.text = @"USB Not Available";
                cell.detailTextLabel.text = @"Patch entitlements first";
                cell.textLabel.enabled = NO;
                cell.detailTextLabel.enabled = NO;
            } else {
                cell.textLabel.text = self.usbDevice ? @"Nintendo Switch Connected" : @"No Connection";
                cell.detailTextLabel.text = self.usbStatus ?: @"Ready for APX USB device...";
                cell.textLabel.enabled = YES;
                cell.detailTextLabel.enabled = YES;
            }
            return cell;
        }
        case 1: {
            if (self.payloads.count == 0) {
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ButtonCell" forIndexPath:indexPath];
                cell.textLabel.text = @"Add Payload";
                cell.textLabel.enabled = self.entitlementsPatched;
                return cell;
            } else {
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PayloadCell" forIndexPath:indexPath];
                Payload *payload = self.payloads[indexPath.row];
                cell.accessoryType = (payload == self.selectedPayload) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
                cell.textLabel.text = payload.displayName;
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%llu KiB)",
                                             [self.payloadDateFormatter stringFromDate:payload.fileDate],
                                             payload.fileSize / 1024];
                cell.textLabel.enabled = self.entitlementsPatched;
                cell.detailTextLabel.enabled = self.entitlementsPatched;
                return cell;
            }
        }
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.entitlementsPatched) return;
    switch (indexPath.section) {
        case 1: {
            if (self.payloads.count == 0) {
                [self addPayloadFromFile];
            } else {
                Payload *payload = self.payloads[indexPath.row];
                if ([self.selectedPayload isEqual:payload]) {
                    self.selectedPayload = nil;
                    Settings.lastPayloadFileName = nil;
                    [self.tableView cellForRowAtIndexPath:indexPath].accessoryType = UITableViewCellAccessoryNone;
                } else {
                    if (self.selectedPayload) {
                        NSIndexPath *prevIdx = [NSIndexPath indexPathForRow:(NSInteger)[self.payloads indexOfObject:self.selectedPayload] inSection:1];
                        [[self.tableView cellForRowAtIndexPath:prevIdx] setAccessoryType:UITableViewCellAccessoryNone];
                    }
                    [self.tableView cellForRowAtIndexPath:indexPath].accessoryType = UITableViewCellAccessoryCheckmark;
                    self.selectedPayload = payload;
                    Settings.lastPayloadFileName = payload.path.lastPathComponent;
                    if (self.usbDevice) {
                        [self updateDeviceStatus:@"Booting payload..."];
                        [self bootPayload:payload];
                    }
                }
            }
            break;
        }
    }
}

- (void)addPayloadFromFile {
    NSArray *docTypes = @[@"public.item", @"public.data"];
    @try {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:docTypes inMode:UIDocumentPickerModeImport];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    } @catch (NSException *exception) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error" message:exception.reason preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end

@implementation SwitchViewController (UIDocumentPickerDelegate)
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    NSError *error = nil;
    Payload *payload = [self.payloadStorage importPayload:url.path move:YES error:&error];
    if (payload) {
        [self.payloads addObject:payload];
        [self.payloadStorage storePayloadSortOrder:self.payloads];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationAutomatic];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import Failed" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}
@end

@implementation SwitchViewController (NXUSBDeviceEnumeratorDelegate)
- (void)usbDeviceEnumerator:(NXUSBDeviceEnumerator *)deviceEnum deviceConnected:(NXUSBDevice *)device {
    self.usbDevice = device;
    if (self.selectedPayload) {
        [self updateDeviceStatus:@"Connected, booting payload..."];
        [self bootPayload:self.selectedPayload];
    } else {
        [self updateDeviceStatus:@"No payload activated yet"];
    }
}
- (void)usbDeviceEnumerator:(NXUSBDeviceEnumerator *)deviceEnum deviceDisconnected:(NXUSBDevice *)device {
    self.usbDevice = nil;
    [self updateDeviceStatus:@"Disconnected"];
}
- (void)usbDeviceEnumerator:(NXUSBDeviceEnumerator *)deviceEnum deviceError:(NSString *)err {
    self.usbError = err;
    [self updateDeviceStatus:@"USB device error"];
}
@end

#pragma mark - Main TabBarController

@implementation MainViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    ExploitViewController *exploitVC = [[ExploitViewController alloc] initWithStyle:UITableViewStyleGrouped];
    UINavigationController *exploitNav = [[UINavigationController alloc] initWithRootViewController:exploitVC];

    SwitchViewController *switchVC = [[SwitchViewController alloc] initWithStyle:UITableViewStyleGrouped];
    UINavigationController *switchNav = [[UINavigationController alloc] initWithRootViewController:switchVC];

    self.viewControllers = @[exploitNav, switchNav];

    if (@available(iOS 13, *)) {
        exploitVC.tabBarItem.image = [UIImage systemImageNamed:@"bolt.fill"];
        switchVC.tabBarItem.image = [UIImage systemImageNamed:@"gamecontroller.fill"];
    }
    exploitVC.tabBarItem.title = @"Exploit";
    switchVC.tabBarItem.title = @"Switch";
}

@end
