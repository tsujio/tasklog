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
use Getopt::Long;
use Text::CSV_XS;

my $DB_FILENAME = 'tasklog.sqlite';
my $TIME_ZONE = 'Asia/Tokyo';
my $DATETIME_FORMAT = '%Y-%m-%d %H:%M:%S';
my $DATETIME_NOW = 'datetime("now")';
my $DATETIME_INF_STR = '9999-01-01 00:00:00';
my $DATETIME_INF = "datetime('$DATETIME_INF_STR')";
my $TASKNAME_MAXLEN = 64;

# Set DB file path
my $script_dir = $FindBin::Bin;
my $db_file_path = catfile $script_dir, $DB_FILENAME;

# Get DB file path
sub get_db_file_path {
  $db_file_path;
}

# Actions
my %action_ids = (
  start => 1,
  suspend => 2,
  block => 3,
  close => 4
);

# Convert action string to id
sub str2actionid {
  die "Unknown action." unless defined($_[0]) && exists($action_ids{$_[0]});
  $action_ids{$_[0]};
}

# Convert action id to string
sub actionid2str {
  my %rev = reverse %action_ids;
  die "Unknown action id." unless defined($_[0]) && exists($rev{$_[0]});
  $rev{$_[0]};
}

# Task states
my %state_ids = (
  INITIAL => 0,
  ACTIVE => 1,
  SUSPENDED => 2,
  BLOCKED => 3,
  CLOSED => 4,
);

# Convert state string to number
sub str2stateid {
  die "Unexpected state string." unless exists($state_ids{$_[0]});
  $state_ids{$_[0]};
}

# Convert state number to string
sub stateid2str {
  my %rev = reverse %state_ids;
  die "Unexpected state number." unless exists($rev{$_[0]});
  $rev{$_[0]};
}

# Convert action string to state id
sub action2stateid {
  my %aid2sid = (
    1 => 1,
    2 => 2,
    3 => 3,
    4 => 4,
  );
  $aid2sid{str2actionid(shift)}
}

# Check if list contains given string
sub contain {
  List::Util::any { $_ eq $_[1] } @{$_[0]};
}

# Convert string to datetime sqlite function
sub str2datetime {
  my $str = shift;

  # Return current datetime unless date string given
  return $DATETIME_NOW unless $str;

  # Parse string
  if ($str !~ /^(?:(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})
                 _)?
               (?<hour>\d{2}):(?<minute>\d{2})(?::(?<second>\d{2}))?$
              /x) {
    die "Invalid datetime string format.";
  }

  my $dt = DateTime->now(time_zone => $TIME_ZONE);
  eval {
    $dt->set_year($+{year}) if exists $+{year};
    $dt->set_month($+{month}) if exists $+{month};
    $dt->set_day($+{day}) if exists $+{day};
    $dt->set_hour($+{hour}) if exists $+{hour};
    $dt->set_minute($+{minute}) if exists $+{minute};
    $dt->set_second($+{second} // '00');
  };
  die "Invalid datetime string format." if $@;
  $dt->set_time_zone('UTC');
  return sprintf 'datetime("%s")', $dt->strftime($DATETIME_FORMAT);
}

# Convert utc to localtime string
sub utc2localtime {
  my $utc_str = shift;

  # Parse datetime string
  my $strp = DateTime::Format::Strptime->new(
    pattern => $DATETIME_FORMAT, time_zone => 'UTC');
  my $dt = $strp->parse_datetime($utc_str);

  # Convert timezone
  $dt->set_time_zone($TIME_ZONE);

  # Convert to string
  $dt->strftime($DATETIME_FORMAT);
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
    $dbh->disconnect;
    die $@;
  }
  $dbh->disconnect;
}

# Check if given task exists or not
sub task_exists {
  my $dbh = shift;
  my $task_name = shift;
  my $sth = $dbh->prepare('SELECT COUNT(*) FROM tasks WHERE name = ?');
  $sth->execute($task_name);
  $sth->fetchrow_arrayref->[0] == 1;
}

# Get current task name
sub get_current_task {
  my $dbh = shift;
  my $rows = $dbh->selectall_arrayref(
    'SELECT * FROM tasks WHERE state = ?', undef, str2stateid('ACTIVE'));
  die "There are multiple active tasks." if @$rows > 1;
  @$rows > 0 ? $rows->[0][0] : undef;
}

# Record activity
sub record_activity {
  my ($dbh, $task_name, $action, $when_utc) = @_;

  # Verify preconditions
  die "Task $task_name not found." unless task_exists($dbh, $task_name);
  my $row = $dbh->selectrow_arrayref(
    'SELECT state FROM tasks WHERE name = ?', undef, $task_name);
  die "Unexpected task state." if $row->[0] == action2stateid($action);

  # Add activity
  my $sth = $dbh->prepare(
    "INSERT INTO activities(task_name, action, when_utc) " .
      "VALUES(?, ?, $when_utc);");
  $sth->execute($task_name, str2actionid($action));

  # Change task state
  $sth = $dbh->prepare('UPDATE tasks SET state = ? WHERE name = ?');
  $sth->execute(action2stateid($action), $task_name);
  die "Unexpectedly " . $sth->rows . " rows have changed." if $sth->rows != 1;
}

# Execute start command
sub execute_start {
  my $opts = shift;
  my $task_name = shift;
  die "Task name must be specified." unless $task_name;
  die "Too many arguments were passed." if @_;

  # Get start datetime
  my $start_utc = str2datetime($opts->{date});

  invoke_with_connection sub {
    my $dbh = shift;

    # Verify that no active task exists
    die "active task already exists." if get_current_task($dbh);

    # Record start activity
    record_activity($dbh, $task_name, 'start', $start_utc);

    say "Task $task_name started.";
  };
}

# Inactivate (suspend, block, close, ...) task
sub inactivate_task {
  my $cmd = shift;
  my $opts = shift;
  my $task_name = shift;
  die "Too many arguments were passed." if @_;

  # Get datetime
  my $when_utc = str2datetime($opts->{date});

  invoke_with_connection sub {
    my $dbh = shift;

    # inactivate current task if task name not specified
    $task_name //= get_current_task($dbh);
    die "Cannot determine which task to $cmd." unless $task_name;

    # Record activity
    record_activity($dbh, $task_name, $cmd, $when_utc);
  };

  $task_name
}

# Execute suspend command
sub execute_suspend {
  my $task_name = inactivate_task('suspend', @_);
  say "Task $task_name suspended.";
}

# Execute block command
sub execute_block {
  my $task_name = inactivate_task('block', @_);
  say "Task $task_name blocked.";
}

# Execute close command
sub execute_close {
  my $task_name = inactivate_task('close', @_);
  say "Task $task_name closed.";
}

# Execute switch command
sub execute_switch {
  my $opts = shift;
  my $task_name = shift;
  die "Task name must be specified." unless $task_name;
  die "Too many arguments were passed." if @_;

  my $cmd =
    $opts->{suspend} ? 'suspend' :
      $opts->{block} ? 'block' :
        $opts->{close} ? 'close' :
          'suspend';
  my $sw_utc = str2datetime($opts->{date});

  invoke_with_connection sub {
    my $dbh = shift;

    # Verify that task to end exists
    my $old_task = get_current_task($dbh);
    die "Cannot determine which task to switch." unless $old_task;

    # Switching to current task is invalid
    die "Specified task is already active." if $old_task eq $task_name;

    record_activity($dbh, $old_task, $cmd, $sw_utc);
    record_activity($dbh, $task_name, 'start', $sw_utc);

    say "Task switched: $old_task -> $task_name";
  };
}

# Execute show command
sub execute_show {
  invoke_with_connection 'readonly', sub {
    my $dbh = shift;
    my $sth = $dbh->prepare('SELECT * FROM activities ORDER BY when_utc');
    $sth->execute;

    # Show activities
    say "id\ttask_name\taction\twhen";
    say "-" x 79;
    while (my $row = $sth->fetchrow_hashref) {
      printf "%s\t%s\t%s\t%s\n",
        $row->{id}, $row->{task_name},
        actionid2str($row->{action}),
        utc2localtime($row->{when_utc});
    }
  };
}

# Execute task command
sub execute_task {
  my $opts = shift;
  my $subcmd = shift;
  my $task_name = shift;

  $subcmd //= 'list';
  if (not contain ['add', 'remove', 'list'], $subcmd) {
    die "Unexpected subcommand for 'task'";
  }
  if (contain ['add', 'remove'], $subcmd) {
    die "Task name must be specified." unless $task_name;
    die "Too long task name." if length $task_name > $TASKNAME_MAXLEN;
  }
  die "Too many arguments were passed." if @_;

  if ($subcmd eq 'add') {
    # Add task
    invoke_with_connection sub {
      my $dbh = shift;
      die "Task $task_name already exists." if task_exists($dbh, $task_name);
      my $sth = $dbh->prepare(
        "INSERT INTO tasks(name, state, created_at) " .
          "VALUES(?, ?, $DATETIME_NOW)");
      $sth->execute($task_name, str2stateid('INITIAL'));
      die "Unexpectedly " . $sth->rows . " rows have changed."
        unless $sth->rows == 1;
      say "Added new task: $task_name";
    };
  } elsif ($subcmd eq 'remove') {
    # Remove task
    invoke_with_connection sub {
      my $dbh = shift;
      die "Task $task_name not found." unless task_exists($dbh, $task_name);
      my $sth = $dbh->prepare('DELETE FROM tasks WHERE name = ?');
      $sth->execute($task_name);
      die "Unexpectedly " . $sth->rows . " rows seem to be affected."
        unless $sth->rows == 1;
      say "Removed task: $task_name";
    };
  } elsif ($subcmd eq 'list') {
    # List tasks
    invoke_with_connection 'readonly', sub {
      my $dbh = shift;
      my $sth = $dbh->prepare('SELECT * FROM tasks;');
      $sth->execute();
      say "name\tstate\tcreated_at";
      say '-' x 79;
      while (my $row = $sth->fetchrow_hashref) {
        next if stateid2str($row->{state}) eq 'CLOSED' && !$opts->{all};

        say sprintf "%s\t%s\t%s",
          $row->{name}, stateid2str($row->{state}),
          utc2localtime($row->{created_at});
      }
    };
  }
}

my @DB_DUMP_FORMATS = (
  {
    table => 'tasks',
    columns => ['name', 'state', 'created_at'],
    orderby => 'name',
  },
  {
    table => 'activities',
    columns => ['id', 'task_name', 'action', 'when_utc'],
    orderby => 'id',
  },
);

# Execute db command
sub execute_db {
  my $opts = shift;
  my $subcmd = shift;
  if (not $subcmd or not contain ['setup', 'desc', 'dump', 'import'], $subcmd) {
    die "Unexpected args for 'db'";
  }
  die "Too many arguments were passed." if @_;

  if ($subcmd eq 'setup') {
    # Setup DB
    invoke_with_connection 'create', sub {
      my $dbh = shift;
      $dbh->do(<<SQL);
CREATE TABLE activities (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_name CHAR(64) REFERENCES tasks(name) NOT NULL,
  action INT UNSIGNED NOT NULL,
  when_utc DATETIME NOT NULL
);
SQL
      $dbh->do(<<SQL);
CREATE TABLE tasks (
  name CHAR(64) PRIMARY KEY,
  state INT UNSIGNED NOT NULL,
  created_at DATETIME NOT NULL
);
SQL
      $dbh->do(<<SQL);
CREATE TABLE config (
  name CHAR(32) PRIMARY KEY,
  value VARCHAR(256) NOT NULL
);
SQL
      $dbh->do(
        'INSERT INTO config(name, value) VALUES("version", "0.3.0");');

      say "Created: $db_file_path";
    };
  } elsif ($subcmd eq 'desc') {
    # Show DB description
    invoke_with_connection 'readonly', sub {
      my $dbh = shift;
      my $rows = $dbh->selectall_arrayref('SELECT * FROM config;');
      say '[DB config]';
      say "$_->[0] = $_->[1]" foreach @$rows;
      say '';
    };
  } elsif ($subcmd eq 'dump') {
    # Dump DB
    invoke_with_connection 'readonly', sub {
      my $dbh = shift;
      foreach (@DB_DUMP_FORMATS) {
        say "### " . $_->{table} . " ###";
        my $stmt = sprintf 'SELECT * FROM %s ORDER BY %s',
          $_->{table}, $_->{orderby};
        my $sth = $dbh->prepare($stmt);
        $sth->execute;
        my $csv = Text::CSV_XS->new({binary => 1});
        while (my $row = $sth->fetchrow_hashref) {
          $csv->combine(@{$row}{@{$_->{columns}}}) or die $csv->error_diag();
          say $csv->string();
        }
      }
    };
  } elsif ($subcmd eq 'import') {
    # Import into DB
    invoke_with_connection sub {
      my $dbh = shift;
      my $sth;
      my $csv = Text::CSV_XS->new({binary => 1});
      while (<STDIN>) {
        chomp;
        if (/^### (\S+) ###$/) {
          my ($cols) = grep { $_->{table} eq $1 } @DB_DUMP_FORMATS;
          $cols = $cols->{columns};
          $sth = $dbh->prepare(
            sprintf 'INSERT INTO %s(%s) VALUES(%s)',
            $1, join(',', @$cols), substr('?,' x @$cols, 0, -1));
          next;
        }

        $csv->parse($_) or die "Failed to parse line.";
        $sth->execute($csv->fields);
      }
    };
  }
}

sub main {
  GetOptions(\my %opts, qw(
    suspend|s
    block|b
    close|c
    date|d=s
    all|a
  )) or die "Option parse error";
  @_ = @ARGV;

  # List of commands
  my @commands = (
    'start', 'suspend', 'block', 'close', 'switch', 's',
    'show', 'task', 'db');

  # Check user input command
  my $cmd = shift;
  if (not $cmd or not contain \@commands, $cmd) {
    say <<EOS;

COMMANDS:
  (start | suspend | block | close) TASK
  switch (alias: s) TASK
  show
  task (add | remove) TASK
       list
         --all -a        Lists all tasks including closed ones
  db (setup | desc | dump | import)
  help

OPTIONS:
  --suspend -s    Suspend current task (Used with the switch command)
  --block -b      Block current task (Used with the switch command)
  --close -c      Close current task (Used with the switch command)
  --date -d [yyyy-MM-dd_]hh:mm[:ss]
EOS
    return 0;
  }

  # Execute command
  if ($cmd eq 'start') { execute_start(\%opts, @_); }
  elsif ($cmd eq 'suspend') { execute_suspend(\%opts, @_); }
  elsif ($cmd eq 'block') { execute_block(\%opts, @_); }
  elsif ($cmd eq 'close') { execute_close(\%opts, @_); }
  elsif ($cmd eq 'switch' or $cmd eq 's') { execute_switch(\%opts, @_); }
  elsif ($cmd eq 'show') { execute_show(\%opts, @_); }
  elsif ($cmd eq 'task') { execute_task(\%opts, @_); }
  elsif ($cmd eq 'db') { execute_db(\%opts, @_); }
  else { die "Unknown command: $cmd"; }

  return 0;
}
