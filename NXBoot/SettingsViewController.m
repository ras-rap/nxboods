#import "SettingsViewController.h"
#import "Settings.h"
#import "SwitchTableViewCell.h"

@interface SettingsViewController ()

@end

enum SettingsSection {
    SettingsSectionRememberPayload,
    SettingsSectionCount
};

@implementation SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.clearsSelectionOnViewWillAppear = NO;
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return SettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case SettingsSectionRememberPayload:
            return @"Keep the last payload selection across app restarts or navigation. It is booted immediately when a device is connected.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SwitchTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchTableViewCell" forIndexPath:indexPath];
    switch (indexPath.section) {
        case SettingsSectionRememberPayload:
            cell.customLabel.text = @"Remember payload selection";
            cell.customSwitch.on = Settings.rememberPayload;
            cell.customSwitch.enabled = YES;
            [cell.customSwitch addTarget:self
                                  action:@selector(setRememberPayload:)
                        forControlEvents:UIControlEventTouchUpInside];
            break;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark - Switch actions

- (void)setRememberPayload:(UISwitch *)sender {
    Settings.rememberPayload = sender.on;
}

@end
