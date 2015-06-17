use 5.010;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin";
use tasklog;
exit tasklog::main(@ARGV);
