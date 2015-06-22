use Test::More;

use 5.010;
use strict;
use warnings;

use POSIX 'strftime';
use DBI;
use DateTime;

use lib '../';
use tasklog;

sub now_jst { DateTime->now(time_zone => 'Asia/Tokyo') }
my $rows;

# Backup existing DB file
my $backup_db_file_path = tasklog::get_db_file_path .
  strftime('.%Y%m%d%H%M%S', localtime);
if (-e tasklog::get_db_file_path) {
  rename tasklog::get_db_file_path, $backup_db_file_path or die $!;
}

# Test str2stateid()
is(tasklog::str2stateid('INITIAL'), 0, "Id of INITIAL should be 0");
is(tasklog::str2stateid('ACTIVE'), 1, "Id of ACTIVE should be 1");
is(tasklog::str2stateid('SUSPENDED'), 2, "Id of SUSPENDED should be 2");
is(tasklog::str2stateid('BLOCKED'), 3, "Id of BLOCKED should be 3");
is(tasklog::str2stateid('CLOSED'), 4, "Id of CLOSED should be 4");
eval { tasklog::str2stateid() };
like($@, qr/^Unexpected state string/, "Error message should be passed");
eval { tasklog::str2stateid('UNKNOWN') };
like($@, qr/^Unexpected state string/, "Error message should be passed");

# Test stateid2str()
is(tasklog::stateid2str(0), 'INITIAL', "String expr of state id should be INITIAL");
is(tasklog::stateid2str(1), 'ACTIVE', "String expr of state id should be ACTIVE");
is(tasklog::stateid2str(2), 'SUSPENDED', "String expr of state id should be SUSPENDED");
is(tasklog::stateid2str(3), 'BLOCKED', "String expr of state id should be BLOCKED");
is(tasklog::stateid2str(4), 'CLOSED', "String expr of state id should be CLOSED");
eval { tasklog::stateid2str(5) };
like($@, qr/^Unexpected state number./, "Error message should be passed");

# Test contain()
ok(tasklog::contain(['foo', 'bar', 'baz'], 'bar'), "Should recognize list contains given value");
ok(!tasklog::contain(['foo', 'bar', 'baz'], 'barbar'), "Should recognize list does not contain given value");

# Test str2datetime()
is(tasklog::str2datetime('2015-06-19_02:00:30'), 'datetime("2015-06-18 17:00:30")',
   "Should return appropriate datetime string by UTC");
is(tasklog::str2datetime('02:00:30'),
   sprintf('datetime("%s 17:00:30")', now_jst->subtract(days => 1)->strftime('%Y-%m-%d')),
   "Should return appropriate datetime string by UTC");
is(tasklog::str2datetime('2015-06-19_02:00'), 'datetime("2015-06-18 17:00:00")',
   "Should return appropriate datetime string by UTC");
is(tasklog::str2datetime('02:00'),
   sprintf('datetime("%s 17:00:00")', now_jst->subtract(days => 1)->strftime('%Y-%m-%d')),
   "Should return appropriate datetime string by UTC");
is(tasklog::str2datetime(), 'datetime("now")',
   "Should return appropriate datetime string by UTC");
eval { tasklog::str2datetime('2015-06-19') };
like($@, qr/^Invalid datetime string format/, "Error message should be passed");
eval { tasklog::str2datetime('06-19') };
like($@, qr/^Invalid datetime string format/, "Error message should be passed");
eval { tasklog::str2datetime('2:00') };
like($@, qr/^Invalid datetime string format/, "Error message should be passed");
eval { tasklog::str2datetime('06-19_02:00') };
like($@, qr/^Invalid datetime string format/, "Error message should be passed");

# Test utc2localtime()
is(tasklog::utc2localtime('2015-06-18 17:00:30'), '2015-06-19 02:00:30', "Should be converted to localtime");

# Test execute_db()
ok(! -e tasklog::get_db_file_path, "db file should not exist");
tasklog::execute_db({}, 'setup');
ok(-e tasklog::get_db_file_path, "db file should exist after setup");

my $dbh = DBI->connect('dbi:SQLite:dbname=' . tasklog::get_db_file_path,
                       undef, undef, { RaiseError => 1 });

my @tables = $dbh->tables('', 'main', '%', '');
ok(scalar(grep { $_ eq '"main"."activities"' } @tables), "Table activities should exist");
ok(scalar(grep { $_ eq '"main"."tasks"' } @tables), "Table tasks should exist");
ok(scalar(grep { $_ eq '"main"."config"' } @tables), "Table config should exist");

eval { tasklog::execute_db({}, 'setup', '2015-01-01_00:00:00') };
like($@, qr/^Too many arguments were passed./, "Error message should be passed");

# Test execute_task()

## Test task add
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks');
is(scalar @$rows, 0, "Task should not be exist");

tasklog::execute_task({}, 'add', 'testtask1');
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks');
is(scalar @$rows, 1, "A single task should be added");
is($rows->[0][0], 'testtask1', "Task name should be specified name");
is($rows->[0][1], 0, "Task state should be INITIAL");

tasklog::execute_task({}, 'add', 'testtask2');
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks ORDER BY created_at');
is(scalar @$rows, 2, "New task should be added");
is($rows->[1][0], 'testtask2', "Task name should be specified name");
is($rows->[1][1], 0, "Task state should be INITIAL");

eval { tasklog::execute_task({}, 'add', 'testtask1') };
like($@, qr/^Task testtask1 already exists./, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks');
is(scalar @$rows, 2, "# of tasks should not change");

eval { tasklog::execute_task({}, 'add', '') };
like($@, qr/^Task name must be specified/, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks');
is(scalar @$rows, 2, "# of tasks should not change");

eval { tasklog::execute_task({}, 'add', 'x' x 64) };
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks');
is(scalar @$rows, 3, "New task should be added");
eval { tasklog::execute_task({}, 'add', 'x' x 65) };
like($@, qr/^Too long task name/, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks');
is(scalar @$rows, 3, "# of tasks should not change");

eval { tasklog::execute_task({}, 'add', 'testtask3', '2015-01-01_00:00:00') };
like($@, qr/^Too many arguments were passed./, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks');
is(scalar @$rows, 3, "# of tasks should not change");

# Test execute_start()
eval { tasklog::execute_start({}, 'testtask1', '2015-01-01_00:00:00') };
like($@, qr/^Too many arguments were passed./, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 0, "Activity should not be added");

eval { tasklog::execute_start({}, 'testtask99') };
like($@, qr/^Task testtask99 not found/, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 0, "Activity should not be added");

tasklog::execute_start({}, 'testtask1');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities WHERE task_name = "testtask1"');
is(scalar @$rows, 1, "A single activity should be added");
is($rows->[0][1], 'testtask1', "Specified task name should be started");
is($rows->[0][2], 1, "Action should be start");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE state = 1');
is(scalar @$rows, 1, "# of active task should be 1");

eval { tasklog::execute_start({}, 'testtask1') };
like($@, qr/^active task already exist/, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 1, "Activity should not be added");

# Test execute_suspend()
tasklog::execute_suspend({});
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 2, "Activity should be added");
is($rows->[1][1], 'testtask1', "Should suspend active task");
is($rows->[1][2], 2, "Should add suspend activity");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is($rows->[0][1], 2, "State should be SUSPEND");

eval { tasklog::execute_suspend({}) };
like($@, qr/^Cannot determine which task to suspend./, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 2, "Activity should not be added");

tasklog::execute_start({}, 'testtask1');
tasklog::execute_suspend({}, 'testtask2');
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is(scalar $rows->[0][1], 1, "State should be ACTIVE");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is(scalar $rows->[0][1], 2, "State should be SUSPENDED");

eval { tasklog::execute_suspend({}, 'testtask100') };
like($@, qr/^Task testtask100 not found./, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 4, "Activity should not be added");

eval { tasklog::execute_suspend({}, 'testtask1', '2015-01-01_00:00:00') };
like($@, qr/^Too many arguments were passed./, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 4, "Activity should not be added");

# Test execute_block()
tasklog::execute_block({}, 'testtask2');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 5, "Activity should be added");
is($rows->[4][1], 'testtask2', "Should block specified task");
is($rows->[4][2], 3, "Should add block activity");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is(scalar $rows->[0][1], 3, "State should be BLOCKED");

eval { tasklog::execute_block({}, 'testtask1', '2015-01-01_00:00:00') };
like($@, qr/^Too many arguments were passed./, "Error message should be passed");

# Test execute_close()
tasklog::execute_close({});
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 6, "Activity should be added");
is($rows->[5][1], 'testtask1', "Should close active task");
is($rows->[5][2], 4, "Should add close activity");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is(scalar $rows->[0][1], 4, "State should be CLOSED");

eval { tasklog::execute_close({}, 'testtask1', '2015-01-01_00:00:00') };
like($@, qr/^Too many arguments were passed./, "Error message should be passed");

# Test execute_switch()
tasklog::execute_start({}, 'testtask1');
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE state = 1');
is(scalar @$rows, 1, "# of active tasks should be 1");
is($rows->[0][0], 'testtask1', "Active task name should be specified one");

tasklog::execute_switch({}, 'testtask2');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 9, "2 activities should be added");
is($rows->[7][1], 'testtask1', "Previous active task should be suspended");
is($rows->[7][2], 2, "Previous active task should be suspended");
is($rows->[8][1], 'testtask2', "Specified task should be active");
is($rows->[8][2], 1, "Specified task should be active");
is($rows->[7][3], $rows->[8][3], "Datetime of added activities should be equal");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is($rows->[0][1], 2, "State of previous task should be SUSPENDED");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is($rows->[0][1], 1, "State of current task should be ACTIVE");

eval { tasklog::execute_switch({}, 'testtask2') };
like($@, qr/^Specified task is already active/, "Switching to the same task should not be allowed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 9, "New activity should not be added");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is($rows->[0][1], 1, "State should not change");

eval { tasklog::execute_switch({}, 'testtask99') };
like($@, qr/^Task testtask99 not found/, "Switching to unknown task should not be allowed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 9, "New activity should not be added");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is($rows->[0][1], 1, "State should not change");

tasklog::execute_switch({suspend => 1}, 'testtask1');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 11, "2 activities should be added");
is($rows->[-2][1], 'testtask2', "Previous active task should be suspended");
is($rows->[-2][2], 2, "Previous active task should be suspended");
is($rows->[-1][1], 'testtask1', "Specified task should be active");
is($rows->[-1][2], 1, "Specified task should be active");
is($rows->[-2][3], $rows->[-1][3], "Datetime of added activities should be equal");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is($rows->[0][1], 2, "State of previous task should be SUSPENDED");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is($rows->[0][1], 1, "State of current task should be ACTIVE");

tasklog::execute_switch({block => 1}, 'testtask2');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 13, "2 activities should be added");
is($rows->[-2][1], 'testtask1', "Previous active task should be blocked");
is($rows->[-2][2], 3, "Previous active task should be blocked");
is($rows->[-1][1], 'testtask2', "Specified task should be active");
is($rows->[-1][2], 1, "Specified task should be active");
is($rows->[-2][3], $rows->[-1][3], "Datetime of added activities should be equal");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is($rows->[0][1], 3, "State of previous task should be BLOCKED");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is($rows->[0][1], 1, "State of current task should be ACTIVE");

tasklog::execute_switch({close => 1}, 'testtask1');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 15, "2 activities should be added");
is($rows->[-2][1], 'testtask2', "Previous active task should be closed");
is($rows->[-2][2], 4, "Previous active task should be closed");
is($rows->[-1][1], 'testtask1', "Specified task should be active");
is($rows->[-1][2], 1, "Specified task should be active");
is($rows->[-2][3], $rows->[-1][3], "Datetime of added activities should be equal");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is($rows->[0][1], 4, "State of previous task should be CLOSED");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is($rows->[0][1], 1, "State of current task should be ACTIVE");

tasklog::execute_switch({suspend => 1, block => 1, close => 1}, 'testtask2');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 17, "2 activities should be added");
is($rows->[-2][1], 'testtask1', "Previous active task should be suspended");
is($rows->[-2][2], 2, "Previous active task should be closed");
is($rows->[-1][1], 'testtask2', "Specified task should be active");
is($rows->[-1][2], 1, "Specified task should be active");
is($rows->[-2][3], $rows->[-1][3], "Datetime of added activities should be equal");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is($rows->[0][1], 2, "State of previous task should be SUSPENDED");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is($rows->[0][1], 1, "State of current task should be ACTIVE");

eval { tasklog::execute_switch({}, 'testtask2', '2015-01-01_00:00:00') };
like($@, qr/^Too many arguments were passed./, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 17, "New activity should not be added");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is($rows->[0][1], 1, "State should not change");

tasklog::execute_suspend({});
eval { tasklog::execute_switch({}, 'testtask2') };
like($@, qr/^Cannot determine which task to switch/, "Switching from non-active task should not be allowed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 18, "New activity should not be added");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is($rows->[0][1], 2, "State should not change");

# Test task_exists()
ok(tasklog::task_exists($dbh, 'testtask1'), "Task should exist");
ok(!tasklog::task_exists($dbh, 'testtask99'), "Task should not exist");

# Test get_current_task()
eval { tasklog::execute_suspend({}) };
ok(!defined tasklog::get_current_task($dbh), "Should not return current task");
tasklog::execute_start({}, 'testtask1');
is(tasklog::get_current_task($dbh), 'testtask1', "Should return current task");
# Test date option
eval { tasklog::execute_suspend({}) };
tasklog::execute_start({date => '2100-01-01_12:00:00'}, 'testtask1');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities ORDER BY when_utc');
is($rows->[-1][3], '2100-01-01 03:00:00', "Datetime should be specified one");

tasklog::execute_suspend({date => '2100-02-01_12:00:00'}, 'testtask1');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities ORDER BY when_utc');
is($rows->[-1][3], '2100-02-01 03:00:00', "Datetime should be specified one");

tasklog::execute_block({date => '2100-03-01_12:00:00'}, 'testtask1');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities ORDER BY when_utc');
is($rows->[-1][3], '2100-03-01 03:00:00', "Datetime should be specified one");

tasklog::execute_close({date => '2100-04-01_12:00:00'}, 'testtask1');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities ORDER BY when_utc');
is($rows->[-1][3], '2100-04-01 03:00:00', "Datetime should be specified one");

tasklog::execute_start({}, 'testtask1');
tasklog::execute_switch({date => '2100-05-01_12:00:00'}, 'testtask2');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities ORDER BY when_utc');
is($rows->[-1][3], '2100-05-01 03:00:00', "Datetime should be specified one");
is($rows->[-2][3], '2100-05-01 03:00:00', "Datetime should be specified one");

# Clean up
unlink tasklog::get_db_file_path;
if (-e $backup_db_file_path) {
  rename $backup_db_file_path, tasklog::get_db_file_path or die $!;
}

done_testing();
