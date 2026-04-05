#import "MainViewController.h"
#import "AppDelegate.h"
#import "FLBootProfile+CoreDataClass.h"
#import "NXExec.h"
#import "NXUSBDeviceEnumerator.h"
#import "NXKernel.h"
#import "PayloadStorage.h"
#import "Settings.h"

static void NXBootKernelLogCallback(const char *message) {
        if (!message) return;

        NSString *msg = [NSString stringWithUTF8String:message];
        if (!msg) return;

        [[NSNotificationCenter defaultCenter] postNotificationName:@"NXKernelLog"
                                                                                                                object:nil
                                                                                                            userInfo:@{ @"message": msg }];
}

@interface MainViewController () <
        NXUSBDeviceEnumeratorDelegate,
        UIAdaptivePresentationControllerDelegate,
        UIDocumentPickerDelegate>

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
@property (nonatomic, strong) NSMutableArray<NSString *> *logs;

@end

@implementation MainViewController

- (NSString *)persistentLogFilePath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"nxboot-live.log"];
}

- (void)appendPersistentLogLine:(NSString *)line {
    if (line.length == 0) return;

    NSString *entry = [line stringByAppendingString:@"\n"];
    NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    NSString *path = [self persistentLogFilePath];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;

    @try {
        [fh seekToEndOfFile];
        [fh writeData:data];
        if (@available(iOS 13.0, *)) {
            [fh synchronizeAndReturnError:nil];
        } else {
            [fh synchronizeFile];
        }
    } @catch (__unused NSException *e) {
    }

    [fh closeFile];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    NXKernelSetLogCallback(NXBootKernelLogCallback);

    [self appendPersistentLogLine:[NSString stringWithFormat:@"===== Session %@ =====", [NSDate date]]];

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

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshPayloadList)
                                                 name:NXBootPayloadStorageChangedExternally
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appendLog:)
                                                 name:@"NXKernelLog"
                                               object:nil];

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
    [self restoreRememberedPayload];

    self.usbEnum = [[NXUSBDeviceEnumerator alloc] init];
    self.usbEnum.delegate = self;
    [self.usbEnum setFilterForVendorID:kTegraX1VendorID productID:kTegraX1ProductID];

    self.navigationItem.leftBarButtonItems = @[self.settingsButtonItem, self.exportLogsButtonItem];
    self.navigationItem.rightBarButtonItem = self.editButtonItem;
}

- (void)dealloc {
    NXKernelSetLogCallback(NULL);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.usbEnum stop];
}

- (void)appendLog:(NSNotification *)note {
    NSString *msg = note.userInfo[@"message"];
    if (msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.logs addObject:msg];
            if (self.logs.count > 200) [self.logs removeObjectAtIndex:0];
            [self appendPersistentLogLine:msg];
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:5]
                          withRowAnimation:UITableViewRowAnimationNone];
        });
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self restoreRememberedPayload];
}

- (void)restoreRememberedPayload {
    if (!Settings.rememberPayload) return;
    NSString *payloadFileName = Settings.lastPayloadFileName;
    if (!payloadFileName) return;
    for (Payload *payload in self.payloads) {
        if ([payload.path.lastPathComponent isEqualToString:payloadFileName]) {
            if (self.selectedPayload) {
                [self cellForPayload:self.selectedPayload].accessoryType = UITableViewCellAccessoryNone;
            }
            self.selectedPayload = payload;
            [self cellForPayload:payload].accessoryType = UITableViewCellAccessoryCheckmark;
            return;
        }
    }
    Settings.lastPayloadFileName = nil;
}

#pragma mark - Kernel Exploit

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
        int result = NXKernelSandboxEscape();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.patchingEntitlements = NO;
            self.entitlementsPatched = (result == 0);
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
            if (self.entitlementsPatched) {
                [self.usbEnum start];
            } else {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Escape Failed"
                                                                             message:@"Could not escape sandbox. USB access may not work."
                                                                      preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            }
        });
    });
}

#pragma mark - Switch Boot

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
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:3] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Table

typedef NS_ENUM(NSInteger, TableSection) {
    TableSectionOffsets,
    TableSectionExploit,
    TableSectionEntitlements,
    TableSectionDevice,
    TableSectionPayloads,
    TableSectionLog,
};

- (void)refreshPayloadList {
    [self.tableView beginUpdates];
    [self.refreshControl endRefreshing];
    [self setEditing:NO animated:YES];
    self.payloads = [[self.payloadStorage loadPayloads] mutableCopy];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:TableSectionPayloads]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
    [self.tableView endUpdates];
    [self restoreRememberedPayload];
}

- (IBAction)refreshPayloadList:(id)sender {
    [self refreshPayloadList];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    BOOL wasEditing = self.isEditing;
    UITableViewRowAnimation animation = animated ? UITableViewRowAnimationAutomatic : UITableViewRowAnimationNone;
    [self.tableView beginUpdates];
    if (editing && !wasEditing && self.selectedPayload) {
        [self cellForPayload:self.selectedPayload].accessoryType = UITableViewCellAccessoryNone;
        self.selectedPayload = nil;
    }
    [super setEditing:editing animated:animated];
    NSInteger nlinks = [self tableView:self.tableView numberOfRowsInSection:TableSectionPayloads];
    for (NSInteger row = 0; row < nlinks; row++) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:TableSectionPayloads];
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        if (cell) [self configureLinkCell:cell];
    }
    NSIndexPath *newPayloadPath = [NSIndexPath indexPathForRow:self.payloads.count inSection:TableSectionPayloads];
    if (self.payloads.count != 0) {
        if (editing && !wasEditing) {
            [self.tableView insertRowsAtIndexPaths:@[newPayloadPath] withRowAnimation:animation];
        } else if (!editing && wasEditing) {
            [self.tableView deleteRowsAtIndexPaths:@[newPayloadPath] withRowAnimation:animation];
        }
    }
    [self.tableView footerViewForSection:TableSectionPayloads].textLabel.text = [self tableView:self.tableView titleForFooterInSection:TableSectionPayloads];
    [self.tableView endUpdates];
    if (!editing && wasEditing) [self restoreRememberedPayload];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 6;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case TableSectionOffsets: return 1;
        case TableSectionExploit: return 1;
        case TableSectionEntitlements: return 1;
        case TableSectionDevice: return 1;
        case TableSectionPayloads: {
            if (self.payloads.count == 0) return 1;
            if (self.isEditing) return self.payloads.count + 1;
            return self.payloads.count;
        }
        case TableSectionLog: return self.logs.count > 0 ? self.logs.count : 1;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case TableSectionOffsets: return @"Step 1 — Kernelcache";
        case TableSectionExploit: return @"Step 2 — Exploit";
        case TableSectionEntitlements: return @"Step 3 — Sandbox Escape";
        case TableSectionDevice: return @"Nintendo Switch";
        case TableSectionPayloads: return @"Payloads";
        case TableSectionLog: return @"Log";
    }
    return [super tableView:tableView titleForHeaderInSection:section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case TableSectionOffsets: return @"Download and resolve kernel offsets. One-time operation.";
        case TableSectionExploit: return @"Run the Darksword IOSurface/ICMPv6 exploit to gain kernel read/write.";
        case TableSectionEntitlements: return @"Patch sandbox extensions to grant unrestricted IOKit access (required for USB).";
        case TableSectionDevice: return [self footerForDeviceCell];
        case TableSectionPayloads:
            if (self.isEditing) return @"Tap a payload to change its name.";
            return @"Activate a payload to boot it automatically.";
        case TableSectionLog: return nil;
    }
    return [super tableView:tableView titleForFooterInSection:section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case TableSectionOffsets: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ButtonCell" forIndexPath:indexPath];
            if (self.hasOffsets) {
                cell.textLabel.text = @"Offsets cached";
                cell.textLabel.textColor = [UIColor systemGreenColor];
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
            } else if (self.downloadingOffsets) {
                cell.textLabel.text = @"Downloading kernelcache...";
                cell.textLabel.textColor = [UIColor systemOrangeColor];
                cell.accessoryType = UITableViewCellAccessoryNone;
            } else {
                cell.textLabel.text = @"Download Kernelcache Offsets";
                cell.textLabel.textColor = self.textColorButton;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            return cell;
        }
        case TableSectionExploit: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ButtonCell" forIndexPath:indexPath];
            if (self.exploitRunning) {
                cell.textLabel.text = [NSString stringWithFormat:@"Running exploit... %d%%", (int)(self.exploitProgress * 100)];
                cell.textLabel.textColor = [UIColor systemOrangeColor];
                cell.accessoryType = UITableViewCellAccessoryNone;
            } else if (self.exploitReady) {
                cell.textLabel.text = @"Exploit succeeded";
                cell.textLabel.textColor = [UIColor systemGreenColor];
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
            } else if (self.exploitFailed) {
                cell.textLabel.text = @"Exploit failed — tap to retry";
                cell.textLabel.textColor = [UIColor systemRedColor];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if (!self.hasOffsets) {
                cell.textLabel.text = @"Run Exploit";
                cell.textLabel.textColor = self.textColorInactive;
                cell.accessoryType = UITableViewCellAccessoryNone;
            } else {
                cell.textLabel.text = @"Run Exploit";
                cell.textLabel.textColor = self.textColorButton;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            return cell;
        }
        case TableSectionEntitlements: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ButtonCell" forIndexPath:indexPath];
            if (self.entitlementsPatched) {
                cell.textLabel.text = @"Sandbox escaped";
                cell.textLabel.textColor = [UIColor systemGreenColor];
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
            } else if (self.patchingEntitlements) {
                cell.textLabel.text = @"Escaping sandbox...";
                cell.textLabel.textColor = [UIColor systemOrangeColor];
                cell.accessoryType = UITableViewCellAccessoryNone;
            } else if (!self.exploitReady) {
                cell.textLabel.text = @"Escape Sandbox";
                cell.textLabel.textColor = self.textColorInactive;
                cell.accessoryType = UITableViewCellAccessoryNone;
            } else {
                cell.textLabel.text = @"Escape Sandbox";
                cell.textLabel.textColor = self.textColorButton;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            return cell;
        }
        case TableSectionDevice: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DeviceCell" forIndexPath:indexPath];
            [self configureDeviceCell:cell];
            return cell;
        }
        case TableSectionPayloads: {
            if (indexPath.row == self.payloads.count) {
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ButtonCell" forIndexPath:indexPath];
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.textLabel.text = @"Add Payload";
                return cell;
            } else {
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PayloadCell" forIndexPath:indexPath];
                Payload *payload = self.payloads[indexPath.row];
                cell.accessoryType = (payload == self.selectedPayload) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
                cell.textLabel.text = payload.displayName;
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%llu KiB)",
                                             [self.payloadDateFormatter stringFromDate:payload.fileDate],
                                             payload.fileSize / 1024];
                return cell;
            }
        }
        case TableSectionLog: {
            if (self.logs.count == 0) {
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ButtonCell" forIndexPath:indexPath];
                cell.textLabel.text = @"No log entries yet";
                cell.textLabel.textColor = self.textColorInactive;
                return cell;
            } else {
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ButtonCell" forIndexPath:indexPath];
                cell.textLabel.text = self.logs[indexPath.row];
                cell.textLabel.font = [UIFont fontWithName:@"Menlo" size:11];
                cell.textLabel.numberOfLines = 0;
                return cell;
            }
        }
    }
    return nil;
}

- (void)configureLinkCell:(UITableViewCell *)cell {
    if (self.editing) {
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.textLabel.textColor = self.textColorInactive;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.textColor = self.textColorButton;
    }
}

- (void)configureDeviceCell:(UITableViewCell *)cell {
    cell.textLabel.text = self.usbDevice ? @"Nintendo Switch Connected" : @"No Connection";
    cell.detailTextLabel.text = self.usbStatus ?: @"Ready for APX USB device...";
}

- (NSString *)footerForDeviceCell {
    if (self.usbError) return self.usbError;
    if (!self.entitlementsPatched) return @"Patch entitlements in Step 3 first to enable USB access.";
    return @"Connect your Nintendo Switch in RCM mode via a Lightning OTG adapter.";
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == TableSectionPayloads;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == TableSectionPayloads && indexPath.row != self.payloads.count;
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)destIndexPath {
    if (sourceIndexPath.section > destIndexPath.section) return [NSIndexPath indexPathForRow:0 inSection:sourceIndexPath.section];
    if (sourceIndexPath.section < destIndexPath.section || destIndexPath.row >= self.payloads.count) return [NSIndexPath indexPathForRow:(self.payloads.count - 1) inSection:sourceIndexPath.section];
    return destIndexPath;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    Payload *payload = self.payloads[sourceIndexPath.row];
    [self.payloads removeObjectAtIndex:sourceIndexPath.row];
    [self.payloads insertObject:payload atIndex:destinationIndexPath.row];
    [self.payloadStorage storePayloadSortOrder:self.payloads];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!self.editing) return UITableViewCellEditingStyleNone;
    if (indexPath.section != TableSectionPayloads) return UITableViewCellEditingStyleNone;
    if (indexPath.row == self.payloads.count) return UITableViewCellEditingStyleInsert;
    return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    assert(indexPath.section == TableSectionPayloads);
    if (editingStyle == UITableViewCellEditingStyleInsert) { [self addPayloadFromFile]; return; }
    assert(editingStyle == UITableViewCellEditingStyleDelete);
    Payload *payload = self.payloads[indexPath.row];
    NSError *error = nil;
    if ([self.payloadStorage deletePayload:payload error:&error]) {
        [self.payloads removeObjectAtIndex:indexPath.row];
        [self.payloadStorage storePayloadSortOrder:self.payloads];
        [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Deletion Failed" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.isEditing && indexPath.section != TableSectionPayloads) return nil;
    if (indexPath.section == TableSectionDevice) return nil;
    return indexPath;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch (indexPath.section) {
        case TableSectionOffsets:
            if (!self.hasOffsets && !self.downloadingOffsets) [self downloadOffsets];
            break;
        case TableSectionExploit:
            if (self.hasOffsets && !self.exploitRunning && !self.exploitReady) [self runExploit];
            break;
        case TableSectionEntitlements:
            if (self.exploitReady && !self.patchingEntitlements && !self.entitlementsPatched) [self patchEntitlements];
            break;
        case TableSectionPayloads:
            if (indexPath.row == self.payloads.count) {
                [self addPayloadFromFile];
            } else {
                Payload *payload = self.payloads[indexPath.row];
                if (self.isEditing) {
                    [self renamePayload:payload];
                } else if ([self.selectedPayload isEqual:payload]) {
                    self.selectedPayload = nil;
                    Settings.lastPayloadFileName = nil;
                    [self.tableView cellForRowAtIndexPath:indexPath].accessoryType = UITableViewCellAccessoryNone;
                } else {
                    if (self.selectedPayload) {
                        [self cellForPayload:self.selectedPayload].accessoryType = UITableViewCellAccessoryNone;
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

- (nullable UITableViewCell *)cellForPayload:(Payload *)payload {
    NSUInteger index = [self.payloads indexOfObject:payload];
    if (index != NSNotFound) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:(NSInteger)index inSection:TableSectionPayloads];
        return [self.tableView cellForRowAtIndexPath:indexPath];
    }
    return nil;
}

- (void)renamePayload:(Payload *)payload {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Payload" message:@"Enter a new name for this payload." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = payload.displayName;
        textField.placeholder = @"payload name";
        textField.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *newName = alert.textFields[0].text;
        if (newName.length == 0 || [newName containsString:@":"] || [newName containsString:@"/"]) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Failed" message:@"Please enter a valid file name without ':' or '/'." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        NSError *error = nil;
        if ([self.payloadStorage renamePayload:payload withNewName:newName error:&error]) {
            [self cellForPayload:payload].textLabel.text = newName;
        } else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Failed" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Document Picker

- (void)addPayloadFromFile {
    NSArray *docTypes = @[@"public.item", @"public.data"];
    @try {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:docTypes inMode:UIDocumentPickerModeImport];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    } @catch (NSException *exception) {
        NSString *message;
        if ([exception.name isEqualToString:NSInternalInconsistencyException]) {
            message = @"iOS 10 cannot show a file picker when NXBoot is installed from an IPA file.";
        } else {
            message = exception.reason;
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error" message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    NSError *error = nil;
    Payload *payload = [self.payloadStorage importPayload:url.path move:YES error:&error];
    if (payload) {
        [self.tableView beginUpdates];
        [self.payloads addObject:payload];
        [self.payloadStorage storePayloadSortOrder:self.payloads];
        if (self.payloads.count == 1 && !self.editing) {
            NSIndexPath *addButtonPath = [NSIndexPath indexPathForRow:0 inSection:TableSectionPayloads];
            [self.tableView deleteRowsAtIndexPaths:@[addButtonPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:0 inSection:TableSectionPayloads];
            [self.tableView insertRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        } else {
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:(self.payloads.count - 1) inSection:TableSectionPayloads];
            [self.tableView insertRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        }
        [self.tableView endUpdates];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import Failed" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark - Navigation

- (UIBarButtonItem *)settingsButtonItem {
    if (@available(iOS 13, *)) {
        return [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"] style:UIBarButtonItemStylePlain target:self action:@selector(settingsButtonTapped:)];
    } else {
        return [[UIBarButtonItem alloc] initWithTitle:@"Settings" style:UIBarButtonItemStylePlain target:self action:@selector(settingsButtonTapped:)];
    }
}

- (void)settingsButtonTapped:(id)sender {
    [self performSegueWithIdentifier:@"Settings" sender:self];
}

- (UIBarButtonItem *)exportLogsButtonItem {
    if (@available(iOS 13, *)) {
        return [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                                style:UIBarButtonItemStylePlain
                                               target:self
                                               action:@selector(exportLogsButtonTapped:)];
    } else {
        return [[UIBarButtonItem alloc] initWithTitle:@"Share Logs"
                                                style:UIBarButtonItemStylePlain
                                               target:self
                                               action:@selector(exportLogsButtonTapped:)];
    }
}

- (void)exportLogsButtonTapped:(id)sender {
    [self exportLogs];
}

- (void)exportLogs {
    NSString *persistentPath = [self persistentLogFilePath];
    NSString *persistentLog = [NSString stringWithContentsOfFile:persistentPath encoding:NSUTF8StringEncoding error:nil];

    NSString *content = persistentLog;
    if (content.length == 0 && self.logs.count > 0) {
        content = [self.logs componentsJoinedByString:@"\n"];
    }

    if (content.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No Logs"
                                                                         message:@"There are no log entries to export yet."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSMutableString *body = [NSMutableString string];
    [body appendString:@"NXBoot Log Export\n"];
    [body appendFormat:@"Date: %@\n", [NSDate date]];
    [body appendFormat:@"Entries (in-memory): %lu\n\n", (unsigned long)self.logs.count];
    [body appendString:content];
    [body appendString:@"\n"];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *fileName = [NSString stringWithFormat:@"nxboot-log-%@.txt", [formatter stringFromDate:[NSDate date]]];
    NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];

    NSError *writeError = nil;
    BOOL wrote = [body writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    if (!wrote || writeError) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Export Failed"
                                                                         message:writeError.localizedDescription ?: @"Could not write log file."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL]
                                                                          applicationActivities:nil];
    if (share.popoverPresentationController) {
        share.popoverPresentationController.barButtonItem = self.navigationItem.leftBarButtonItems.lastObject;
    }
    [self presentViewController:share animated:YES completion:nil];
}

- (IBAction)settingsUnwindAction:(UIStoryboardSegue *)unwindSegue {
    [self restoreRememberedPayload];
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if (self.selectedPayload) {
        [self cellForPayload:self.selectedPayload].accessoryType = UITableViewCellAccessoryNone;
        self.selectedPayload = nil;
    }
    segue.destinationViewController.presentationController.delegate = self;
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    [self restoreRememberedPayload];
}

#pragma mark - NXUSBDeviceEnumeratorDelegate

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
