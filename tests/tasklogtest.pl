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

# Backup existing DB file
my $backup_db_file_path = tasklog::get_db_file_path .
  strftime('.%Y%m%d%H%M%S', localtime);
if (-e tasklog::get_db_file_path) {
  rename tasklog::get_db_file_path, $backup_db_file_path or die $!;
}

# Test str2stateid()
is(tasklog::str2stateid('INITIAL'), 0, "Id of INITIAL should be 0");
is(tasklog::str2stateid('SUSPENDED'), 1, "Id of SUSPENDED should be 1");
is(tasklog::str2stateid('ACTIVE'), 2, "Id of ACTIVE should be 2");
is(tasklog::str2stateid('BLOCKED'), 3, "Id of BLOCKED should be 3");
is(tasklog::str2stateid('CLOSED'), 4, "Id of CLOSED should be 4");
eval { tasklog::str2stateid() };
like($@, qr/^Unexpected state string/, "Error message should be passed");
eval { tasklog::str2stateid('UNKNOWN') };
like($@, qr/^Unexpected state string/, "Error message should be passed");

# Test stateid2str()
is(tasklog::stateid2str(0), 'INITIAL', "String expr of state id should be INITIAL");
is(tasklog::stateid2str(1), 'SUSPENDED', "String expr of state id should be SUSPENDED");
is(tasklog::stateid2str(2), 'ACTIVE', "String expr of state id should be ACTIVE");
is(tasklog::stateid2str(3), 'BLOCKED', "String expr of state id should be BLOCKED");
is(tasklog::stateid2str(4), 'CLOSED', "String expr of state id should be CLOSED");
eval { tasklog::stateid2str(5) };
like($@, qr/^Unexpected state number./, "Error message should be passed");

# Test contain()
ok(tasklog::contain(['foo', 'bar', 'baz'], 'bar'), "Should recognize list contains given value");
ok(!tasklog::contain(['foo', 'bar', 'baz'], 'barbar'), "Should recognize list does not contain given value");

# Test str2datetime()
is(tasklog::str2datetime('2015-06-19', '02:00:30'), 'datetime("2015-06-18 17:00:30")',
   "Should return appropriate datetime string by UTC");
is(tasklog::str2datetime('02:00:30'),
   sprintf('datetime("%s 17:00:30")', now_jst->subtract(days => 1)->strftime('%Y-%m-%d')),
   "Should return appropriate datetime string by UTC");
is(tasklog::str2datetime('2015-06-19', '02:00'), 'datetime("2015-06-18 17:00:00")',
   "Should return appropriate datetime string by UTC");
is(tasklog::str2datetime('02:00'),
   sprintf('datetime("%s 17:00:00")', now_jst->subtract(days => 1)->strftime('%Y-%m-%d')),
   "Should return appropriate datetime string by UTC");
is(tasklog::str2datetime(), 'datetime("now")',
   "Should return appropriate datetime string by UTC");
eval { tasklog::str2datetime('2015-06-19') };
like($@, qr/^Invalid time string format/, "Error message should be passed");
eval { tasklog::str2datetime('06-19') };
like($@, qr/^Invalid time string format/, "Error message should be passed");
eval { tasklog::str2datetime('2:00') };
like($@, qr/^Invalid time string format/, "Error message should be passed");
eval { tasklog::str2datetime('06-19', '02:00') };
like($@, qr/^Invalid date string format/, "Error message should be passed");

# Test utc2localtime()
is(tasklog::utc2localtime('2015-06-18 17:00:30'), '2015-06-19 02:00:30', "Should be converted to localtime");

# Test execute_db()
ok(! -e tasklog::get_db_file_path, "db file should not exist");
tasklog::execute_db('setup');
ok(-e tasklog::get_db_file_path, "db file should exist after setup");

my $dbh = DBI->connect('dbi:SQLite:dbname=' . tasklog::get_db_file_path,
                       undef, undef, { RaiseError => 1 });

my @tables = $dbh->tables('', 'main', '%', '');
ok(scalar(grep { $_ eq '"main"."activities"' } @tables), "Table activities should exist");
ok(scalar(grep { $_ eq '"main"."tasks"' } @tables), "Table tasks should exist");
ok(scalar(grep { $_ eq '"main"."task_state_history"' } @tables), "Table task_state_history should exist");
ok(scalar(grep { $_ eq '"main"."config"' } @tables), "Table config should exist");

# Test execute_task()

## Test task add
tasklog::execute_task('add', 'testtask1');
my $rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is(scalar @$rows, 1, "A single task should be added");
is($rows->[0][0], 'testtask1', "Task name should be specified name");
is($rows->[0][1], 0, "Task state should be INITIAL");

eval { tasklog::execute_task('add', 'testtask1') };
ok(index($@, "Task testtask1 already exists.") != -1, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is(scalar @$rows, 1, "# of tasks should not change");

tasklog::execute_task('add', 'testtask2');
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is(scalar @$rows, 1, "New task should be added");
is($rows->[0][0], 'testtask2', "Task name should be specified name");
is($rows->[0][1], 0, "Task state should be INITIAL");

eval { tasklog::execute_task('add', 'testtask1') };
isnt(index($@, "Task testtask1 already exists."), -1, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is(scalar @$rows, 1, "# of tasks should not change");

## Test task remove
tasklog::execute_task('remove', 'testtask1');
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is(scalar @$rows, 0, "Task should be removed");
$rows = $dbh->selectall_arrayref('SELECT COUNT(*) FROM tasks');
is(scalar $rows->[0][0], 1, "Other tasks should not be removed");

eval { tasklog::execute_task('remove', 'testtask1') };
like($@, qr/Task testtask1 not found/, "Error message should be passed");

tasklog::execute_task('add', 'testtask1');

## Test task state
tasklog::execute_task('add', 'testtask3');
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask3"');
is($rows->[0][1], 0, "Task state should be INITIAL");

tasklog::execute_task('state', 'testtask3', 'SUSPENDED');
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask3"');
is($rows->[0][1], 1, "Task state should be SUSPENDED");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask3"');
is(scalar @$rows, 1, "Task history should be recorded");
is($rows->[0][2], 0, "State of recorded history should be INITIAL");

eval { tasklog::execute_task('state', 'testtask3', 'SUSPENDED') };
like($@, qr/^State of task is already specified one./, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask3"');
is($rows->[0][1], 1, "Task state should not change");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask3"');
is(scalar @$rows, 1, "Task history should not be recorded");

eval { tasklog::execute_task('state', 'testtask99', 'SUSPENDED') };
like($@, qr/^Task testtask99 not found/, "Error message should be passed");

eval { tasklog::execute_task('state', 'testtask3', 'UNKNOWN') };
like($@, qr/^Unexpected state string./, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask3"');
is($rows->[0][1], 1, "Task state should not change");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask3"');
is(scalar @$rows, 1, "Task history should not be recorded");

# Test execute_start()
tasklog::execute_start('testtask1');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities WHERE task_name = "testtask1"');
is(scalar @$rows, 1, "A single activity should be added");
is($rows->[0][1], 'testtask1', "Specified task name should be started");
is($rows->[0][3], '9999-01-01 00:00:00', "End time should be infinite");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE state = 2');
is(scalar @$rows, 1, "A single active task alone should exist");
is($rows->[0][1], 2, "State of started task should be ACTIVE");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask1"');
is(scalar @$rows, 1, "Task history should be recorded");
is($rows->[0][2], 0, "State of recorded history should be INITIAL");

eval { tasklog::execute_start('testtask1') };
like($@, qr/^active task already exist/, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 1, "Activity should not be added");
is($rows->[0][3], '9999-01-01 00:00:00', "Existing activity should not end");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask1"');
is(scalar @$rows, 1, "Task history should not be recorded");

eval { tasklog::execute_start('testtask99') };
like($@, qr/^Task testtask99 not found/, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 1, "Activity should not be added");
is($rows->[0][3], '9999-01-01 00:00:00', "Existing activity should not end");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask1"');
is(scalar @$rows, 1, "Task history should not be recorded");

eval { tasklog::execute_start('testtask2') };
like($@, qr/^active task already exists/, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 1, "Activity should not be added");
is($rows->[0][3], '9999-01-01 00:00:00', "Existing activity should not end");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask1"');
is(scalar @$rows, 1, "Task history should not be recorded");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask2"');
is(scalar @$rows, 0, "Task history should not be recorded");

# Test execute_end()
tasklog::execute_end();
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 1, "End command should not add new activity");
isnt($rows->[0][3], '9999-01-01 00:00:00', "End time should be recorded");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is($rows->[0][1], 1, "State of ended task should be SUSPEND");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask1"');
is(scalar @$rows, 2, "Task history should be recorded");
is($rows->[1][2], 2, "State of recorded history should be ACTIVE");
is($rows->[0][3], $dbh->selectall_arrayref('SELECT * FROM activities')->[-1][3], "State change time should be equal to activity end time");

eval { tasklog::execute_end() };
like($@, qr/^Cannot determine which task to end./, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 1, "Activity should not be added");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is($rows->[0][1], 1, "State of task should not change");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask1"');
is(scalar @$rows, 2, "New history should not recorded");

# Test execute_switch()
tasklog::execute_start('testtask1');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities WHERE task_name = "testtask1" ORDER BY start_utc');
is(scalar @$rows, 2, "New activity should be added");
is($rows->[1][1], 'testtask1', "Specified task name should be started");
is($rows->[1][3], '9999-01-01 00:00:00', "End time should be infinite");
isnt($rows->[0][3], '9999-01-01 00:00:00', "Existing activity should not be affected");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is($rows->[0][1], 2, "State of started task should be ACTIVE");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask1"');
is(scalar @$rows, 3, "Task history should be recorded");
is($rows->[2][2], 1, "State of recorded history should be SUSPENDED");
is($rows->[1][3], $dbh->selectall_arrayref('SELECT * FROM activities')->[-1][2], "State change time should be equal to activity start time");

tasklog::execute_switch('testtask2');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities ORDER BY start_utc');
is(scalar @$rows, 3, "New activity should be added");
is($rows->[2][1], 'testtask2', "Specified task name should be started");
is($rows->[2][2], $rows->[1][3], "Start time should be equal to end time of previous activity");
is($rows->[2][3], '9999-01-01 00:00:00', "End time should be infinite");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is($rows->[0][1], 2, "State of started task should be ACTIVE");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is($rows->[0][1], 1, "State of started task should be SUSPEND");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask1"');
is(scalar @$rows, 4, "Task history should be recorded");
is($rows->[3][2], 2, "State of recorded history should be ACTIVE");
is($rows->[3][3], $dbh->selectall_arrayref('SELECT * FROM activities')->[-1][2], "State change time should be equal to current activity start time");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask2"');
is(scalar @$rows, 1, "Task history should be recorded");
is($rows->[0][2], 0, "State of recorded history should be INITIAL");
is($rows->[0][3], $dbh->selectall_arrayref('SELECT * FROM activities')->[-1][2], "State change time should be equal to current activity start time");

eval { tasklog::execute_switch('testtask2') };
like($@, qr/^Specified task is already active/, "Switching to the same task should not be allowed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities ORDER BY start_utc');
is(scalar @$rows, 3, "New activity should not be added");
is($rows->[2][3], '9999-01-01 00:00:00', "End time should not change");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is($rows->[0][1], 2, "State should not change");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask2"');
is(scalar @$rows, 1, "Task history should not be recorded");

eval { tasklog::execute_switch('testtask99') };
like($@, qr/^Task testtask99 not found/, "Switching to unknown task should not be allowed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities ORDER BY start_utc');
is(scalar @$rows, 3, "New activity should not be added");
is($rows->[2][3], '9999-01-01 00:00:00', "End time should not change");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is($rows->[0][1], 2, "State should not change");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask2"');
is(scalar @$rows, 1, "Task history should not be recorded");

tasklog::execute_end();
eval { tasklog::execute_switch('testtask2') };
like($@, qr/^Cannot determine which task to switch/, "Switching from non-active task should not be allowed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities ORDER BY start_utc');
is(scalar @$rows, 3, "New activity should not be added");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is($rows->[0][1], 1, "State should not change");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask2"');
is(scalar @$rows, 2, "Task history should not be recorded");

# Clean up
unlink tasklog::get_db_file_path;
if (-e $backup_db_file_path) {
  rename $backup_db_file_path, tasklog::get_db_file_path or die $!;
}

done_testing();
