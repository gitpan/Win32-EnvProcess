# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl Win32-EnvProcess.t'

#########################

use File::Copy;
use File::Basename;
use Config;
use Cwd;

use Test::More tests => 21;

use Win32::EnvProcess qw(:all);
ok(1); # If we made it this far, we're ok.

#########################

# Sanity check (2)
is($^O, 'MSWin32', 'OS is Windows');

my $from = ".\\blib\\arch\\auto\\Win32\\EnvProcess\\EnvProcessDll.dll";
ok(-r $from, 'DLL install') or diag ("DLL $from not available (for read)");

my $to   = dirname($Config{perlpath}).'\\EnvProcessDll.dll';
ok(copy($from, $to), "Copy DLL") or 
    diag ("Copy DLL failed: $!\nfrom: $from, to: $to\nPWD:".getcwd());

my @tasks = map {(split)[1]} grep /^cmd.exe/,qx(tasklist);
my @pids = GetPids('cmd.exe');
is(scalar(@pids), 2, 'GetPids') or 
      diag ("There appears to be additional cmd.exe sessions running,\n",
            "please close these down for the duration of these tests.\n");

# If you have to have other cmd.exe's running, then alter this.
my $pid = $pids[0];

# tasks from tasklist and pids from GetPids should be the same,
# but not necessarily in the same order
{
   my %tasks;
   @tasks{@tasks} = undef;
   my %pids;
   @pids{@pids} = undef;
   
   is(scalar(keys %tasks), scalar(keys %pids), 'GetPids matches tasklist') or
         diag ("tasks: @tasks, pids: @pids");
}   


my %hash = qw (var_thing some_value var_another another yavar yavalue);
my $result = SetEnvProcess($pid, %hash);
is(0+$^E, 0, 'os error ok') or diag ("$^E: Value of \@pids is: @pids\n");
ok($result == 3, "Set 3 vars") or diag ("\$result: $result");

$result = SetEnvProcess ($pid, 'NoValue');
is(0+$^E, 0, 'os error ok') or diag ("$^E: NoValue\n");
ok($result == 1, "Set 1 var(no value)") or diag ("\$result: $result");

my @values = GetEnvProcess ($pid, 'USERNAME', 'abcdefg');
is(0+$^E, 0, 'os error ok') or diag ("$^E: 'USERNAME' & 'abcdefg'\n");
ok(scalar(@values) == 2, "Get 2 vars") or diag ("\@values(2): @values");
ok($values[0] eq $ENV{'USERNAME'}, "Check USERNAME") or 
    diag ("\%ENV: $ENV{'USERNAME'}, \$values[0]: $values[0]");
ok(!defined $result[1], "Get 2 vars - 2nd no value") or diag ("\@values(2): @values");

@values = GetEnvProcess ($pid, 'abcdefg');
is(0+$^E, 0, 'os error ok') or diag ("$^E: 'abcdefg'\n");
ok(scalar(@values) == 1, "Get 1 empty var") or diag ("\@values(1): @values");
ok(!defined $result[0], "Get 1 empty var") or diag ("\@values(1): @values");

my @vars = qw (var_thing var_another yavar NoValue);
$result = DelEnvProcess($pid, @vars);
is(0+$^E, 0, 'os error ok') or diag ("$^E: Value of \@pids is: @pids\n");
ok($result == 4, "Delete vars") or diag ("\$result: $result");

$result = DelEnvProcess($pid, 'NonExistantVariable');
is(0+$^E, 0, 'os error ok') or diag ("$^E: Value of \@pids is: @pids\n");
ok($result == 0, "Delete nonvar") or diag ("\$result: $result");

# Uncomment the next line if you do not want the DLL in the Perl bin directory
# unlink $to;