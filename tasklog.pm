package tasklog;

use 5.010;
use strict;
use warnings;

use DBI;
use FindBin;
use File::Spec::Functions 'catfile';
use List::Util;
use DateTime;
use DateTime::Format::Strptime;

my $DB_FILENAME = 'tasklog.sqlite';
my $TIME_ZONE = 'Asia/Tokyo';
my $DATETIME_FORMAT = '%Y-%m-%d %H:%M:%S';
my $DATETIME_NOW = 'datetime("now")';
my $DATETIME_INF = 'datetime("9999-01-01 00:00:00")';

# Set DB file path
my $script_dir = $FindBin::Bin;
my $db_file_path = catfile $script_dir, $DB_FILENAME;

# Get DB file path
sub get_db_file_path {
  $db_file_path;
}

# Check if list contains given string
sub contain {
  List::Util::any { $_ eq $_[1] } @{$_[0]};
}

# Convert string to datetime sqlite function
sub str2datetime {
  my ($date, $time) = @_[0, 1];

  # Return current datetime unless date string given
  return $DATETIME_NOW unless $date;

  # Use the first argument as time string if # of args is 1
  if (not $time) {
    $time = $date;
    $date = undef;
  }

  # Parse time string
  if ($time !~ /^(\d{2}):(\d{2}):(\d{2})$/) {
    die "Invalid time string format.";
  }
  my ($hour, $min, $sec) = ($1, $2, $3);

  # Use current date if date string not given
  if (not $date) {
    my $dt = DateTime->now(time_zone => $TIME_ZONE);
    eval {
      $dt->set_hour($hour);
      $dt->set_minute($min);
      $dt->set_second($sec);
    };
    die "Invalid time string format." if $@;
    $dt->set_time_zone('UTC');
    return sprintf 'datetime("%s")', $dt->strftime($DATETIME_FORMAT);
  }

  # Parse date string
  if ($date !~ /^(\d{4})-(\d{2})-(\d{2})$/) {
    die "Invalid date string format.";
  }
  my $dt = eval {
    DateTime->new(
      time_zone => $TIME_ZONE,
      year => $1, month => $2, day => $3,
      hour => $hour, minute => $min, second => $sec)
  };
  die "Invalid datetime string format." if $@;
  $dt->set_time_zone('UTC');
  return sprintf 'datetime("%s")', $dt->strftime($DATETIME_FORMAT);
}

# Invoke given function with DB connection
sub invoke_with_connection {
  my ($opt, $func) = @_ > 1 ? ($_[0], $_[1]) : ('', $_[0]);
  my ($readonly, $create) = map { $_ eq $opt } ('readonly', 'create');

  # Check if DB file exists or not
  if ($create) {
    die "DB file $db_file_path already exists." if -e $db_file_path;
  } else {
    die "DB file $db_file_path not found." unless -e $db_file_path;
  }

  my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file_path", undef, undef,
                         { RaiseError => 1, AutoCommit => 0 });
  eval {
    # Enable foreign key constraint
    $dbh->do('PRAGMA foreign_keys = ON;');

    $func->($dbh);
    $dbh->commit unless $readonly;
  };
  if ($@) {
    $dbh->rollback unless $readonly;
    die $@;
  }
  $dbh->disconnect;
}

# Check if given task exists or not
sub task_exists {
  my $dbh = shift;
  my $task_name = shift;
  my $sth = $dbh->prepare('SELECT * FROM tasks WHERE name = ?');
  $sth->execute($task_name);
  $sth->fetchrow_hashref
}

# Check if logs of given task exist
sub task_log_exists {
  my $dbh = shift;
  my $task_name = shift;
  my $sth = $dbh->prepare('SELECT * FROM logs WHERE task_name = ?');
  $sth->execute($task_name);
  $sth->fetchrow_hashref
}

# Execute start command
sub execute_start {
  my $task_name = shift;
  my ($date_str, $time_str) = @_;
  die "Task name must be specified." unless $task_name;

  # Get start datetime
  my $start_datetime = str2datetime($date_str, $time_str);

  invoke_with_connection sub {
    my $dbh = shift;

    # Verify that task to start exists
    die "Task $task_name not found." unless task_exists($dbh, $task_name);

    # Raise error if active tasks exist
    my $cnt = $dbh->selectall_arrayref(
      "SELECT count(*) FROM logs WHERE end_utc = $DATETIME_INF");
    die "$cnt->[0][0] active tasks already exist." if $cnt->[0][0] > 0;

    # Start task
    my $sth = $dbh->prepare(
      "INSERT INTO logs(task_name, start_utc, end_utc) " .
        "VALUES(?, $start_datetime, $DATETIME_INF);");
    $sth->execute($task_name);

    say "Task $task_name started.";
  };
}

# Execute end command
sub execute_end {
  my ($date_str, $time_str) = @_;

  # Get end datetime
  my $end_datetime = str2datetime($date_str, $time_str);

  invoke_with_connection sub {
    my $dbh = shift;

    # Raise error if multiple active tasks exist
    my $active_tasks = $dbh->selectall_arrayref(
      "SELECT task_name FROM logs WHERE end_utc = $DATETIME_INF");
    die "Cannot determine which task to end." if @$active_tasks != 1;

    # End task
    $dbh->do("UPDATE logs SET end_utc = $end_datetime " .
               "WHERE end_utc = $DATETIME_INF;");

    say "Task $active_tasks->[0][0] ended.";
  };
}

# Execute switch command
sub execute_switch {
  my $task_name = shift;
  die "Task name must be specified." unless $task_name;

  invoke_with_connection sub {
    my $dbh = shift;

    # Verify that task to start exists
    die "Task $task_name not found." unless task_exists($dbh, $task_name);

    # Raise error if multiple active tasks exist
    my $active_tasks = $dbh->selectall_arrayref(
      "SELECT task_name FROM logs WHERE end_utc = $DATETIME_INF");
    die "Cannot determine which task to switch." if @$active_tasks != 1;

    # Switch task
    $dbh->do("UPDATE logs SET end_utc = $DATETIME_NOW " .
               "WHERE end_utc = $DATETIME_INF;");
    my $sth = $dbh->prepare("INSERT INTO logs(task_name, start_utc, end_utc) " .
                              "VALUES(?, $DATETIME_NOW, $DATETIME_INF);");
    $sth->execute($task_name);

    say "Task switched: $active_tasks->[0][0] -> $task_name";
  };
}

# Execute show command
sub execute_show {
  invoke_with_connection 'readonly', sub {
    my $dbh = shift;
    my $sth = $dbh->prepare('SELECT * FROM logs ORDER BY start_utc');
    $sth->execute;

    # Show logs
    say "id\ttask_name\tstart\tend";
    say "-" x 79;
    my $strp = DateTime::Format::Strptime->new(
      pattern => $DATETIME_FORMAT, time_zone => 'UTC');
    while (my $row = $sth->fetchrow_hashref) {
      # Parse datetime string
      my $start_dt = $strp->parse_datetime($row->{start_utc});
      my $end_dt = $strp->parse_datetime($row->{end_utc});

      # Convert timezone
      $start_dt->set_time_zone($TIME_ZONE);
      $end_dt->set_time_zone($TIME_ZONE);

      # Print
      printf "%s\t%s\t%s\t%s\n",
        $row->{id}, $row->{task_name},
        $start_dt->strftime($DATETIME_FORMAT),
        $end_dt->strftime($DATETIME_FORMAT);
    }
  };
}

# Execute task command
sub execute_task {
  my $arg = shift;
  my $task_name = shift;
  if (not $arg or not contain ['add', 'remove', 'list'], $arg) {
    die "Unexpected args for 'task'";
  }
  if (($arg eq 'add' or $arg eq 'remove') and not $task_name) {
    die "Task name must be specified.";
  }

  if ($arg eq 'add') {
    # Add task
    invoke_with_connection sub {
      my $dbh = shift;
      die "Task $task_name already exists." if task_exists($dbh, $task_name);
      my $sth = $dbh->prepare('INSERT INTO tasks(name) VALUES(?);');
      $sth->execute($task_name);
      say "Added new task: $task_name";
    };
  } elsif ($arg eq 'remove') {
    # Remove task
    invoke_with_connection sub {
      my $dbh = shift;
      die "Task $task_name not found." unless task_exists($dbh, $task_name);
      die "Cannot delete task $task_name because some logs have been recorded."
        if task_log_exists($dbh, $task_name);
      my $sth = $dbh->prepare('DELETE FROM tasks WHERE name = ?');
      $sth->execute($task_name);
      say "Removed task: $task_name";
    };
  } elsif ($arg eq 'list') {
    # List tasks
    invoke_with_connection 'readonly', sub {
      my $dbh = shift;
      my $sth = $dbh->prepare('SELECT * FROM tasks;');
      $sth->execute();
      while (my $row = $sth->fetchrow_hashref) {
        say $row->{name};
      }
    };
  }
}

# Execute db command
sub execute_db {
  my $arg = shift;
  if (not $arg or not contain ['setup', 'desc'], $arg) {
    die "Unexpected args for 'db'";
  }

  if ($arg eq 'setup') {
    # Setup DB
    invoke_with_connection 'create', sub {
      my $dbh = shift;
      $dbh->do(<<SQL);
CREATE TABLE logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_name CHAR(64) REFERENCES tasks(name) NOT NULL,
  start_utc DATETIME NOT NULL,
  end_utc DATETIME NOT NULL
);
SQL
      $dbh->do(<<SQL);
CREATE TABLE tasks (
  name CHAR(64) PRIMARY KEY
);
SQL
      $dbh->do(<<SQL);
CREATE TABLE config (
  name CHAR(32) PRIMARY KEY,
  value VARCHAR(256) NOT NULL
);
SQL
      $dbh->do(
        'INSERT INTO config(name, value) VALUES("version", "0.1.0");');
    };
  } elsif ($arg eq 'desc') {
    # Show DB description
    invoke_with_connection 'readonly', sub {
      my $dbh = shift;
      my $rows = $dbh->selectall_arrayref('SELECT * FROM config;');
      say '[DB config]';
      say "$_->[0] = $_->[1]" foreach @$rows;
      say '';
    };
  }
}

sub main {
  # List of commands
  my @commands = ('start', 'end', 'switch', 's', 'show', 'task', 'db');

  # Check user input command
  my $cmd = shift;
  if (not $cmd or not contain \@commands, $cmd) {
    say <<EOS;

COMMANDS:
  start TASK [[yyyy-MM-dd] hh:mm:ss]
  end [[yyyy-MM-dd] hh:mm:ss]
  switch TASK       (alias: s)
  show
  task (add TASK| remove TASK| list)
  db (setup | desc)
  help
EOS
    return 0;
  }

  # Execute command
  if ($cmd eq 'start') { execute_start(@_); }
  elsif ($cmd eq 'end') { execute_end(@_); }
  elsif ($cmd eq 'switch' or $cmd eq 's') { execute_switch(@_); }
  elsif ($cmd eq 'show') { execute_show(@_); }
  elsif ($cmd eq 'task') { execute_task(@_); }
  elsif ($cmd eq 'db') { execute_db(@_); }
  else { die "Unknown command: $cmd"; }

  return 0;
}
