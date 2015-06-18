use Test::More tests => 51;

use 5.010;
use strict;
use warnings;

use POSIX 'strftime';
use DBI;

use lib '../';
use tasklog;

# Backup existing DB file
my $backup_db_file_path = tasklog::get_db_file_path .
  strftime('.%Y%m%d%H%M%S', localtime);
if (-e tasklog::get_db_file_path) {
  rename tasklog::get_db_file_path, $backup_db_file_path or die $!;
}

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

tasklog::execute_task('add', 'testtask1');

# Test execute_start()
tasklog::execute_start('testtask1');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities WHERE task_name = "testtask1"');
is(scalar @$rows, 1, "A single activity should be added");
is($rows->[0][1], 'testtask1', "Specified task name should be started");
is($rows->[0][3], '9999-01-01 00:00:00', "End time should be infinite");

$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is($rows->[0][1], 2, "State of started task should be ACTIVE");

$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask1"');
is(scalar @$rows, 1, "Task history should be recorded");
is($rows->[0][2], 0, "State of recorded history should be INITIAL");

eval { tasklog::execute_start('testtask1') };
isnt(index($@, 'active task already exist'), -1, "Error message should be passed");
$rows = $dbh->selectall_arrayref('SELECT * FROM activities');
is(scalar @$rows, 1, "Activity should not be added");
is($rows->[0][3], '9999-01-01 00:00:00', "Existing activity should not end");

# Test execute_end()
tasklog::execute_end();
$rows = $dbh->selectall_arrayref('SELECT * FROM activities WHERE task_name = "testtask1"');
is(scalar @$rows, 1, "End command should not add new activity");
isnt($rows->[0][3], '9999-01-01 00:00:00', "End time should be recorded");

$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is($rows->[0][1], 1, "State of ended task should be SUSPEND");

$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask1"');
is(scalar @$rows, 2, "Task history should be recorded");
is($rows->[1][2], 2, "State of recorded history should be ACTIVE");

eval { tasklog::execute_end() };
isnt(index($@, "Cannot determine which task to end."), -1, "Error message should be passed");

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

tasklog::execute_switch('testtask2');
$rows = $dbh->selectall_arrayref('SELECT * FROM activities ORDER BY start_utc');
is(scalar @$rows, 3, "New activity should be added");
is($rows->[2][1], 'testtask2', "Specified task name should be started");
is($rows->[2][3], '9999-01-01 00:00:00', "End time should be infinite");
isnt($rows->[1][3], '9999-01-01 00:00:00', "Existing activity should not be affected");

$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask2"');
is($rows->[0][1], 2, "State of started task should be ACTIVE");
$rows = $dbh->selectall_arrayref('SELECT * FROM tasks WHERE name = "testtask1"');
is($rows->[0][1], 1, "State of started task should be SUSPEND");

$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask1"');
is(scalar @$rows, 4, "Task history should be recorded");
is($rows->[3][2], 2, "State of recorded history should be ACTIVE");
$rows = $dbh->selectall_arrayref('SELECT * FROM task_state_history WHERE task_name = "testtask2"');
is(scalar @$rows, 1, "Task history should be recorded");
is($rows->[0][2], 0, "State of recorded history should be INITIAL");

# Clean up
unlink tasklog::get_db_file_path;
if (-e $backup_db_file_path) {
  rename $backup_db_file_path, tasklog::get_db_file_path or die $!;
}
