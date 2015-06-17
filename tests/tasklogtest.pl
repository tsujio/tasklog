use Test::More tests => 2;

use 5.010;
use strict;
use warnings;

use POSIX 'strftime';

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

# Test execute_task()

# Test execute_start()

# Test execute_end()

# Clean up
unlink tasklog::get_db_file_path;
rename $backup_db_file_path, tasklog::get_db_file_path or die $!;
