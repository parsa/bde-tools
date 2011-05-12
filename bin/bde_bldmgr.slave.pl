#!/opt/swt/bin/perl -w
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib/perl";
use lib "$FindBin::Bin/../lib/perl/site-perl";

use File::Path;
use File::Copy;
use Getopt::Long;
use POSIX qw(uname strftime);
use IO::Handle;

use BDE::Build::Uplid;
use Symbols qw(EXIT_SUCCESS EXIT_FAILURE);
use Util::Message qw(fatal debug);
use Util::Retry qw(
    retry_chdir retry_dir
    retry_open retry_open3 retry_system
);
use Util::File::Basename qw(basename dirname);

#------------------------------------------------------------------------------

use constant FAILED       => "!! FAILED";
use constant NOTSUPPORTED => "!! NOTSUPPORTED";
use constant SUCCEEDED    => "** SUCCEEDED";
use constant DEFAULT_JOBS => 4;

#------------------------------------------------------------------------------

=head1 SYNOPSIS

  bde_bldmgr.slave.pl -h | [-d] [-e] [-f <flags>] \
                           [-l <logdir>] [-r root] [-v] \
                           -t <target>[,<target>...] <group|package>

See C<bde_bldmgr.slave.pl -h> for brief usage information.

=head1 DESCRIPTION

This is the slave script remotely invoked by bde_bldmgr to carry out the build
on a given target machine. It collects the results of invoking a local build
and passes back status information (typically via a rsh-initiated network
connection) to the invoking bde_bldmgr.

=head1 NOTES

This script is not intended to be invoked directly; use bde_bldmgr instead.

=head1 MAINTAINER

  Peter Wainwright (pwainwright@bloomberg.net)

=cut

#------------------------------------------------------------------------------

umask 002;
STDOUT->autoflush(1);

my $iamwindows = ($^O =~ /win/i);
my $prog       = basename($0);
my $bindir     = $iamwindows ? $FindBin::Bin : dirname($0);
$bindir =~ s|/|\\|sg if $iamwindows;
my $FS         = $iamwindows ? "\\" : "/";

unless ($iamwindows) {
    $ENV{PATH} = join(':',$bindir,qw[
        /usr/local/bin /usr/bin /bin /usr/ccs/bin
        /opt/SUNWspro/bin /bb/bin
    ]);
    $ENV{RSU_LICENSE_MAP} = "/opt/rational/config/PurifyPlus_License_Map";
}

if ($^O =~ /aix/) {
    # Email from Mark Hannum on 20100720 @ 15:16:33
    #> My guess is that the test script is unsetting the EXTSHM variable ..
    # make sure that 'EXTSHM=on' is set before your pekludge task executes.
    # -Mark

    $ENV{EXTSHM} = "on";
}

#------------------------------------------------------------------------------
# Process command line

my %opts;

Getopt::Long::Configure("bundling");
unless (GetOptions(\%opts,qw[
    after|A=s
    before|B=s
    compiler|c=s
    check|C
    debug|d+
    define|D=s@
    express|e
    envbat|E=s
    help|h
    nodepend|n
    make|M=s
    nice|i:i
    options|o=s
    path|P=s@
    jobs|parallel|j|pa:i
    rebuild|R
    uptodate|U
    uplid|u=s
    where|root|w|r=s
    serial|s
    target|t=s
    tag|T=s

    group|g=s
    flags|f=s@
    verbose|v+
    logdir|l=s
])) {
    usage(), exit 0;
}

usage(),exit 0 if $opts{help};

my $after    = $opts{after}    || '';
my $before   = $opts{before}   || '';
my $compiler = $opts{compiler} || '';
my $check    = $opts{check}    || '';
my $defines  = $opts{define} ? join(' ', map { "-D$_" } @{$opts{define}}) : '';
my $express  = $opts{express}  || 0;
my $make     = $opts{make}     || '';
my $nice     = $opts{nice}     || 0;
my $nodepend = $opts{nodepend} || 0;
my $options  = $opts{options}  || '';
my $rebuild  = $opts{rebuild}  || 0;
my $uptodate = $opts{uptodate} || 0;
my $debug    = $opts{debug}    || 0;
my $group    = $opts{group}    || '';
my $flags    = $opts{flags}    || '';
my $verbose  = $opts{verbose}  || 0;
my $where    = $opts{where}    || $ENV{BDE_ROOT};

my $tag      = $opts{tag}      || "";

if ($opts{envbat}) {
    warn "Got --envbat $opts{envbat}";

    open ENVBAT, '"'.$opts{envbat}.'" && set |';
    while(<ENVBAT>) {
        /^(.*?)=(.*)$/ and $ENV{$1}=$2;
    }
    close(ENVBAT);

    warn "Populated environment to:\n";
    warn "\t$_=$ENV{$_}\n" foreach sort keys %ENV;
}

if ($opts{path}) {
    warn "Got --path @{$opts{path}}";

    my $newpath=(join ":",@{$opts{path}});

    if (exists $ENV{BDE_PATH}) {
        $ENV{BDE_PATH} = "$newpath:$ENV{BDE_PATH}";
    }
    else {
        $ENV{BDE_PATH} = $newpath;
    }

    warn "Populated BDE_PATH to: $ENV{BDE_PATH}\n";
}

if ($opts{uptodate} && $opts{rebuild}) {
    fatal "--uptodate and --rebuild are mutually exclusive"
}

# Ensure we pick up tools from the view we are building
unless ($iamwindows) {
  $ENV{PATH} = join(':',"$where/tools/bin",$ENV{PATH});
}

my $uplid;
if ($opts{uplid}) {
    fatal "--uplid and --compiler are mutually exclusive"
      if $opts{compiler};
    $uplid = BDE::Build::Uplid->unexpanded($opts{uplid});
} elsif ($opts{compiler}) {
    $uplid = BDE::Build::Uplid->new({ compiler => $opts{compiler},
                                      where    => $opts{where}
                                    });
} else {
    $uplid = BDE::Build::Uplid->new({ where    => $opts{where} });
}

if ($group) {
    if (@ARGV) {
        usage("Trailing arguments incompatible with --group");
        exit EXIT_FAILURE;
    }
} else {
  SWITCH: foreach (scalar@ARGV) {
        $_==0 and do {
            usage("No --group or trailing group argument supplied");
            exit EXIT_FAILURE;
        };
        $_==1 and do {
            $group = $opts{group} = $ARGV[0];
            last;
        };
      DEFAULT:
        usage("@ARGV: only one trailing group argument allowed");
        exit EXIT_FAILURE;
    }
}

unless ($where) {
   $where = $bindir;
   $where =~s|tools/bin/?$||s;
}

usage("No group or package supplied"),exit EXIT_FAILURE
  unless $opts{group};
usage("No target build type supplied"), exit EXIT_FAILURE
  unless $opts{target};

unless ($opts{logdir}) {
    $opts{logdir}=$bindir;
    $opts{logdir} =~ s{[/\\][^/\\]+[/\\]?$}{/logs};
}

my @targets=split /\W+/,$opts{target};

#------------------------------------------------------------------------------
# logging

{
    my $SLAVELOG;

    sub open_slavelog ($) {
        my $logdir=shift;

        my @lt = localtime();
        my $dtag = sprintf "%04d%02d%02d-%02d%02d%02d",
            ($lt[5]+1900),($lt[4]+1),$lt[3],$lt[2],$lt[1],$lt[0];

        unless (retry_dir $logdir) {
            mkpath($logdir, 0, 0777) or die "cannot make '$logdir': $!\n";
        }
        my $logarch = (uname)[0];
        $logarch =~ s/\s+/_/g;
        my $logfile = "$logdir/slave.$dtag.$group.$uplid.log";

        $SLAVELOG=new IO::Handle;
        retry_open($SLAVELOG,">$logfile") or die "cannot open build output file: $!";
        $SLAVELOG->autoflush(1);

        return $logfile;
    }

    sub write_slavelog (@) {
        print $SLAVELOG @_;
    }

    sub close_slavelog () {
        close $SLAVELOG;
    }
}

sub write_logandverbose (@) {
    write_slavelog @_,"\n";
    print @_,"\n" if $verbose;
}

#------------------------------------------------------------------------------

sub usage {
    my $msg=shift;
    print STDERR "!! $msg\n" if $msg;

    my $DEFAULT_JOBS=DEFAULT_JOBS;

    print <<_USAGE_END;
Usage: $prog -h | [-d] [-e] [-f <flags>] \\
                    [-l <logdir>] [-r root] [-v] \\
                    -t <target>[,<target>...] <group|package>
Local options:
  --debug    | -d            enable debug reporting
  --help     | -h            usage information (this text)
  --flags    | -f <f>=<v>    optional arbitrary flags to pass to bde_build.pl
  --logdir   | -l <path>     log destination directory
  --nice     | -i <niceness> "nice" level for slave process (and children)
  --verbose  | -v            enable verbose output in build
  --target   | -t <targets>  build target or comma-separated list of targets
  --where    | -w <dir>      specify explicit root

Passed to build:
  --after    | -A <target>   make explicit target(s) after regular build
  --before   | -B <target>   make explicit target(s) before regular build
  --compiler | -c <comp>     compiler definition for system (default: 'def')
  --check    | -C            perform 'checkin' code verification
  --define   | -D <macro>    define one or more makefile macro overrides:
                               <name>[=<value>][,<name>[=<value>]...]
  --express  | -e            express build (do not build or run test drivers)
  --group    | -g <grp|pkg>  the group or package to build (required),
                             may also be specified as a trailing argument.
  --jobs     | -j [<jobs>]   build in parallel up to the specified number of
                             jobs (default: $DEFAULT_JOBS jobs)
                             default if platform is not 'dg'
  --make     | -M <target>   make explicit target(s) only (e.g.: 'buildtest')
                             instead of entering normal build process
  --nodepend | -n            do not build dependent packages (not with groups)
  --options  | -o            specify options file (default: default.opts)
  --serial   | -s            serial build (equivalent to -j1)
                             default if platform is 'dg'
  --tag      | -T <string>   add "tag" string to lines of output (defaults to "")
  --rebuild  | -R            force rebuild makefiles even if up to date
  --uptodate | -U            assume makefiles are up-to-date (not with -R)
  --uplid    | -u <uplid>    specify rather than derive platform ID. -c will
                             override or add compiler if specified.

See 'pod2text $0' for more information.

_USAGE_END
}

#------------------------------------------------------------------------------

MAIN: {
    # on windows, go to view specified by root
    if ($iamwindows) {
        retry_chdir($where);
        #retry_system("cleartool update")
    }

    # if NOT on windows, renice process if --nice option is in effect
    if (!$iamwindows) {
        system("renice -n $nice $$") if $nice;
    }

    # open slave log file; returns log filename
    my $logfile=open_slavelog($opts{logdir});

    # preamble
    write_logandverbose "** $prog started";
    write_logandverbose "-- build root is $where" if $where;
    write_logandverbose "** building targets: @targets";
    write_logandverbose "-- verbosity level $verbose";
    write_logandverbose "-- express mode ".($express?"enabled":"disabled");

    # construct common command arguments
    my @basecmd=("$bindir${FS}bde_build.pl");
    if ($iamwindows) {
        unshift @basecmd,qq["$^X"]; #prefix with Perl itself (in quotes) for Windows
    }

    # -A, -B, -c, -C, -d, -D, -e, -M, -n, -o, -R, -u, -w
    push @basecmd,"-A",$after if $after;
    push @basecmd,"-B",$before if $before;
    push @basecmd,"-c",$compiler if $compiler;
    push @basecmd,"-C" if $check;
    push @basecmd,"-d" if $debug;
    push @basecmd,$defines if $defines;
    push @basecmd,"-e" if $express;
    push @basecmd,"-M",$make if $make;
    push @basecmd,"-n" if $nodepend;
    push @basecmd,"-o",$options if $options;
    push @basecmd,"-R" if $rebuild;
    push @basecmd,"-U" if $uptodate;
    push @basecmd,"-u",$uplid if $uplid;
    push @basecmd,"-w",$where if $where;

    # on distributed builds, always rebuild and skip non-compliant package tests
    push @basecmd,"-R","-E";

    # -j, -s
    if ($opts{serial}) {
        push @basecmd,"-s";
    } elsif ($opts{jobs}) {
        push @basecmd,"-j",$opts{jobs};
    }

    # -f : f=v,f=v,f=v -ff=v -ff=v
    if ($flags) {
        foreach my $flagset (@$flags) {
            foreach my $flag (split ",",$flagset) {
                my ($opt,$value) = split /=/,$flag,2;
                unless ($opt=~/^-/) {
                    $opt=((length $opt>1)?"--":"-").$opt; #may omit leading '-';
                }
                push @basecmd,$opt;
                push @basecmd,$value if defined $value;
            }
        }
    }

    # -t : invoke for each target specified
    for my $target (@targets) {
        # construct target-specific command arguments
        my @cmd = @basecmd;
        push @cmd,"-t",$target,$group;
        print "-- running command: @cmd\n" if $verbose>=2;

        # invoke command
        my ($rdh, $wrh)=(new IO::Handle,new IO::Handle);
        my $pid=retry_open3($rdh,$wrh,$rdh,@cmd);
        my $output="";

        my $prefixString="<< $tag";
        my $logPrefix="";

        if($tag) {
            $logPrefix="$tag: ";
        }

        while (my $line=<$rdh>) {
            print $prefixString,$line if $verbose>=3;
            write_slavelog($logPrefix.strftime(" %H%M%S:",localtime).$line);
            $output.=$logPrefix.$line;
        }

        close $rdh; close $wrh;
        waitpid($pid,0); #reap child status into $?

        # examine output and send result string
        my $tagTrailer="";
        $tagTrailer=" $tag" if $tag;

        if ($? != 0) {
            if ($output =~ /ERROR:\s*Capabilities\s*of\s*\w+\s*deny\s*build/) {
                print NOTSUPPORTED, " ", $target,$tagTrailer," ";
            }
            else {
                print FAILED," ",$target,$tagTrailer," ";
		my $n = undef;
                for my $f ($output =~ /\(see (.*?[\\\/]make\.[^\\\/]+\.log)\)/gm) {
			$n = 1;
	                print "[see $f]";
                }
		if (!$n) {
			for my $e ($output =~ /^(ERROR:.*)/gm) {
				$n = 1;
		                print "[$e]";
	                }
		}
		if (!$n) {
	                print "[see $logfile]";
                }
            }
        } else {
            print SUCCEEDED," ",$target,$tagTrailer;
        }
        print "\n";
    }

    # postamble
    write_logandverbose "** $prog finished **";

    # close up shop
    close_slavelog();
    exit EXIT_SUCCESS;
}

#------------------------------------------------------------------------------