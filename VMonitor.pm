package Apache::VMonitor;

BEGIN {
  # RCS/CVS complient:  must be all one line, for MakeMaker
  $Apache::VMonitor::VERSION = do { my @r = (q$Revision: 0.03 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r }; 
}

use strict;
use Apache::Scoreboard ();
use Apache::Constants ();
use GTop ();

@Apache::VMonitor::shortflags = qw(. S _ R W K L D G N);

use constant KBYTE =>       1024;
use constant MBYTE =>    1048576;
use constant GBYTE => 1073741824;

########################
# default config values
########################
%Apache::VMonitor::Config =
  (
     # behavior
   BLINKING => 1,
   REFRESH  => 0,
   VERBOSE  => 0,
     # sections to show
   TOP      => 1,
   MOUNT    => 0,
   FS_USAGE => 1,
   NETLOAD  => 0,
  );

     # devs to show if $Apache::VMonitor::Config{NETLOAD} != 0;
@Apache::VMonitor::NETDEVS  = qw ();

#
# my $newurl = get_url(key,value)
# update some part of the url and return
############
sub get_url{
  my($key,$value) = @_;

  (my $new_url = $Apache::VMonitor::url) =~ s/$key=(\d+)/$key=$value/;
  return $new_url;
}

###########
sub handler{

    ##############################
    # process args and set refresh rate
    ##############################
  my $r = shift;
  my %params = $r->args;

    # modify the default args if requested
  map { $Apache::VMonitor::Config{$_} = $params{$_} 
	if defined $params{$_}
      } keys %Apache::VMonitor::Config;

    # build the updated URL
  $Apache::VMonitor::url = $r->uri."?".join "&", 
    map {"$_=$Apache::VMonitor::Config{$_}"} 
      keys %Apache::VMonitor::Config;

    # if the refresh is non-null, set the refresh header
  $r->header_out
    (Refresh => 
     "$Apache::VMonitor::Config{REFRESH}; URL=$Apache::VMonitor::url"
    ) if $Apache::VMonitor::Config{REFRESH} != 0;

  $r->content_type('text/html');
  $r->send_http_header;

  start_html();
  print_top();
  choice_bar();
  verbose();

  print "</BODY>\n</HTML>\n";

  return Apache::Constants::OK;

} # end of sub handler


#################################
# the html header and refresh bar
#################################
###############
sub start_html{

  print qq{<HTML>
	   <HEAD>
	   <TITLE>Apache::VMonitor</TITLE>
	   </HEAD>
	   <BODY BGCOLOR="white">
	  };

  print
    "&nbsp;" x 10,
    qq{<B><FONT SIZE=+1 COLOR="#339966">Apache::VMonitor</FONT></B>},
    "&nbsp;" x 10,
    "<B>Refresh rate:</B> ",
    join "&nbsp;&nbsp;",
    map
      {
	$Apache::VMonitor::Config{REFRESH} == $_
	  ? qq{[<B><FONT SIZE=+1> $_ </FONT></B>]}
	  : qq{<A HREF="@{[get_url(REFRESH => $_)]}"><B>[ $_ ]</B></A>};
      }
	qw(0 1 5 10 20 30 60);

} # end of start_html

# META: Glibtop has a process list with args - people might want to
# watch processes like squid, mysql so it can be configured to return
# a list of PIDs of the matched processes - see (Process list in the
# gtop manual)


##############
sub print_top{

# META: related to above: probably write an interface to dynamically
# add/remove the sections of report.

  print "<PRE><HR><FONT SIZE=-1>";
  my $gtop = GTop->new;

  if ($Apache::VMonitor::Config{TOP}) {

    ########################
    # uptime and etc...
    #######################
    my $loadavg = $gtop->loadavg();
    printf "<B>%d/%.2d/%d %d:%.2d%s   up %s, load average: %.2f %.2f %.2f",
      map ({($_->[1]+1,$_->[0],$_->[2]+1900)}[(localtime)[3,4,5]]),
      map ({$_->[1] > 11 ? ($_->[1]%12,$_->[0],"pm") : ($_->[1],$_->[0],"am") } 
	   [(localtime)[1,2]]),
      format_time($gtop->uptime()->uptime()),  
      @{$loadavg->loadavg()};

      # linux specific info
    if ($^O eq 'linux'){
      printf ", %d processes: %d running</B>\n",
        $loadavg->nr_tasks,
        $loadavg->nr_running;
    } else {
      print "</B>\n";
    }

    #######################
    # total CPU stats
    #######################
    my $cpu = $gtop->cpu();
    my $total = $cpu->total();
    # META: I always get the same information here! Do you? Is it a bug?
    printf "<B>CPU:   %2.1f%% user, %2.1f%% nice, %2.1f%% sys, %2.1f%% idle</B>\n",
      $cpu->user() * 100 / $total,
      $cpu->nice() * 100 / $total,
      $cpu->sys()  * 100 / $total,
      $cpu->idle() * 100 / $total;

    #######################
    # total mem stats
    #######################
    my $mem = $gtop->mem();
    printf "<B>Mem:  %6dK av, %6dK used, %6dK free, %6dK shared, %6dK buff</B>\n",
      $mem->total()  / 1000,
      $mem->used()   / 1000,
      $mem->free()   / 1000,
      $mem->shared() / 1000,
      $mem->buffer() / 1000;

    #######################
    # total swap stats
    #######################
    # visual alert on swap usage:
    # 1) 5Mb < swap < 10 MB             color: light red
    # 2) 20% < swap (swapping is bad!)  color: red
    # 3) 70% < swap (swap almost used!) color: red + blinking

    my $swap = $gtop->swap();
    my $format = qq{%6dK av, %6dK used, %6dK free, %6d  pagein, %6d  pageout};

    my $swap_total = $swap->total() / 1000;
    my $swap_used  = $swap->used()  / 1000;
    my $swap_free  = $swap->free()  / 1000;
    my $swap_usage = $swap_used * 100 / $swap_total;

    if (5000 < $swap_used and $swap_used < 10000) {
      $format = qq{<B>Swap: <FONT COLOR="#FF99CC">$format</FONT></B>\n};
    } elsif ($swap_usage > 20) {
      $format = qq{<B>Swap: <FONT COLOR="#FF0000">$format</FONT></B>\n};
    } elsif ($swap_usage > 70) {
      # swap on fire!
      $format = qq{<B>@{[blinking("Swap:")]} <FONT COLOR="#FF0000">$format</FONT></B>\n};
    } else {
      $format = qq{<B>Swap: $format</B>\n};
    }

    printf $format,
      $swap_total,
      $swap_used,
      $swap_free,
      $swap->pagein(),
      $swap->pageout();

    #############################################
    # mem usage and other stats per httpd process
    #############################################

    my $image = Apache::Scoreboard->image;

      # init the stats hash
    my %total = map {$_ => 0} qw(size real max_shared);
    print "<HR>";
    printf "<B> ##    %4s %s %6s %6s %6s  %5s  %s  %s  %12s %27s</B>\n", 
      qw(PID M Size Share VSize RSS AccessNum ByteTransf Client), "Request (first 64 chars)";

    for (my $i=-1; $i<Apache::Constants::HARD_SERVER_LIMIT; $i++) {
      # handle the parent case
      my $pid = ($i==-1) ? getppid() : $image->parent($i)->pid;
      last unless $pid;
      my $proc_mem     = $gtop->proc_mem($pid);
      my $size  = $proc_mem->size($pid)  / 1000;

        # workarond for Apache::Scoreboard (or underlying C code) bug,
        # it reports processes that are already dead. So we easily
        # skip them, since their size is zero!
      next if $size == 0;

      my $share = $proc_mem->share($pid) / 1000;
      my $vsize = $proc_mem->vsize($pid) / 1000;
      my $rss   = $proc_mem->rss($pid)   / 1000;

      #  total http size update
      $total{size}  += $size;
      $total{real}  += $size-$share;
      $total{max_shared} = $share if $total{max_shared} < $share;

      my $process = $image->servers($i);

      # handle the parent case
      if ($i == -1) {
	printf "par: %6d %1s %6d %6d %6d %6d  <B>SLOT CHLD  SLOT  CHLD </B>\n",
	$pid,
	$Apache::VMonitor::shortflags[$process->status],
	$size,
	$share,
	$vsize,
	$rss;	
      } else {
	printf "%3d: %6d %1s %6d %6d %6d %6d  %4s %4s %5s %5s  %15.15s %.64s \n",	
	$i,
	$pid,
	$Apache::VMonitor::shortflags[$process->status],
	$size,
	$share,
	$vsize,
	$rss,
	format_counts($process->access_count),
	format_counts($process->my_access_count),
	format_bytes($process->bytes_served),
	format_bytes($process->my_bytes_served),
	$process->client,
	$process->request;
      }

    } # end of for (my $i=0...

    printf "\n<B>Total:     %5dK size, %6dK approx real size (-shared)</B>\n",
      $total{size}, $total{real} + $total{max_shared};

    #  Note how do I calculate the approximate real usage of the memory:
    #  1. For each process sum up the difference between shared and system
    #  memory 2. Now if we add the share size of the process with maximum
    #  shared memory, we will get all the memory that actually is being
    #  used by all httpd processes but the parent process.

    print "<HR>";

  } # end of if ($Apache::VMonitor::Config{TOP})

  #######################
  # mounted filesystems
  #######################
  if ($Apache::VMonitor::Config{MOUNT}) {
    #    print "<B>mount:</B>\n";   

    my($mountlist, $entries) = $gtop->mountlist(1);
    my $fs_number = $mountlist->number;   

    printf "<B>%-30s %-30s %-10s</B>\n", ("DEVICE", "MOUNTED ON", "FS TYPE");
    for (my $i=0; $i < $fs_number; $i++) {
      printf "%-30s %-30s %-10s\n",
	$entries->devname($i),
	$entries->mountdir($i),
	$entries->type($i);
    }

    print "<HR>";

  } # end of if ($Apache::VMonitor::Config{MOUNT})


  #######################
  # filesystem usage
  #######################
  if ($Apache::VMonitor::Config{FS_USAGE}) {
    #    print "<B>df:</B>\n";
      # the header
    printf "<B>%-7s %9s %9s %9s %3s  %9s %7s %5s</B>\n",
      "FS", "Blocks (1k): Total", "SU Avail", "User Avail", "Usage", "Files: Total", "Avail", "Usage";

    my($mountlist, $entries) = $gtop->mountlist(1);
    my $fs_number = $mountlist->number;

      # the filesystems
    for (my $i = 0; $i < $fs_number; $i++) {
      my $fsusage = $gtop->fsusage($entries->mountdir($i));

      my $tot_blocks        = $fsusage->blocks / 2;
      my $su_avail_blocks   = $fsusage->bfree  / 2 ;
      my $user_avail_blocks = $fsusage->bavail / 2;
      my $used_blocks       = $tot_blocks - $su_avail_blocks;
      my $usage_blocks      = $tot_blocks ? ($tot_blocks - $user_avail_blocks)* 100 / $tot_blocks : 0;
      my $tot_files         = $fsusage->files;
      my $free_files        = $fsusage->ffree;
      my $usage_files       = $tot_files ? ($tot_files - $free_files) * 100 / $tot_files : 0;

        # prepare a format
      my $fs_format = "%-16s";
      my $format = "%9d %9d %10d %3d%%        %7d %7d %3d%%";

      # visual alert on filesystems of 90% usage!
      if ($usage_blocks >= 90 || $usage_files >= 90) {
        # fs on fire!
	$format = qq{<B><FONT COLOR="#FF0000">@{[blinking($fs_format)]} $format</FONT></B>\n};
      } else {
	$format = qq{$fs_format $format\n};
      }

      printf $format,
	$entries->mountdir($i),
	$tot_blocks,
	$used_blocks,
	$user_avail_blocks,
	$usage_blocks,
	$tot_files,
	$free_files,
	$usage_files;
    }

    print "<HR>";

  } # end of if ($Apache::VMonitor::Config{FS_USAGE})

  #######################
  # net interfaces stats
  #######################
  if ($Apache::VMonitor::Config{NETLOAD}) {
    if (@Apache::VMonitor::NETDEVS) {
      #      print "<B>Netload:</B>\n";
      for my $dev (@Apache::VMonitor::NETDEVS) {
	my $netload = $gtop->netload($dev);
	next unless $netload;
	printf "<B>%4s</B>\t       MTU:          %4d, collisions:    %d\n", 
	  $dev, 
	  $netload->mtu($dev),
	  $netload->collisions($dev);

	printf "\tTX:    packets:%10d, bytes:%10d, errors:%d\n",
	  $netload->packets_out($dev),
	  $netload->bytes_out($dev),
	  $netload->errors_out($dev);

	printf "\tRX:    packets:%10d, bytes:%10d, errors:%d\n",
	  $netload->packets_in($dev),
	  $netload->bytes_in($dev),
	  $netload->errors_in($dev);

	printf "\tTotal: packets:%10d, bytes:%10d, errors:%d\n\n",
	  $netload->packets_total($dev),
	  $netload->bytes_total($dev),
	  $netload->errors_total($dev);
      }

    } else {
      print qq{Don't know what devices to monitor...\nHint: set \@Apache::VMonitor::NETDEVS\n};
    } # end of if (@Apache::VMonitor::NETDEVS)

      print "<HR>";

  } # end of if ($Apache::VMonitor::Config{NETLOAD})

  print "</FONT>";

} # end of sub print_top


# compacts numbers like 1200234 => 1.2M 
############
sub format_bytes{
  my $bytes = shift || 0;

  return                  $bytes       if $bytes < KBYTE;
  return sprintf "%.@{[int($bytes/KBYTE) < 10 ? 1 : 0]}fK", $bytes/KBYTE if KBYTE < $bytes  and $bytes < MBYTE;
  return sprintf "%.@{[int($bytes/MBYTE) < 10 ? 1 : 0]}fM", $bytes/MBYTE if MBYTE < $bytes  and $bytes < GBYTE;
  return sprintf "%.@{[int($bytes/GBYTE) < 10 ? 1 : 0]}fG", $bytes/GBYTE if GBYTE < $bytes;

} # end of sub format_bytes

# any number that enters we return its compacted version of max 4
# chars in length (5, 123, 1.2M, 12M, 157G)
# note that here 1K is 1000 and not 1024!!!
############
sub format_counts{
  local $_ = shift || 0;

  my $digits = tr/0-9//;
  return $_                                                          if $digits < 4;
  return sprintf "%.@{[$digits%3 == 1 ? 1 : 0]}fK", $_/1000          if $digits < 7;
  return sprintf "%.@{[$digits%3 == 1 ? 1 : 0]}fM", $_/1000000       if $digits < 10;
  return sprintf "%.@{[$digits%3 == 1 ? 1 : 0]}fG", $_/1000000000    if $digits < 13;
  return sprintf "%.@{[$digits%3 == 1 ? 1 : 0]}fT", $_/1000000000000 if $digits < 16;

} # end of sub format_counts

# takes seconds as arguments and returns string of time in days or
# hours if less then one day.
###############
sub format_time{
  my $secs = shift || 0;
  my $hours = $secs/3600;
  return sprintf "%.1f days", $hours/24 if  $hours > 24;
  return sprintf "%d:%.2d", int $hours, int $secs%3600 ?  int (($secs%3600)/60) : 0;
} # end of sub format_time


# should blink or not
############
sub blinking{
  return $Apache::VMonitor::Config{BLINKING} 
    ? join "", "<BLINK>",@_,"</BLINK>"
    : join "", @_;
} # end of sub blinking

# print the form to enable or disable choices
##############
sub choice_bar{

  print "<FONT SIZE=-1>";

  my @hide = ();
  my @show = ();

  foreach (qw(TOP MOUNT FS_USAGE NETLOAD VERBOSE BLINKING)) {
    $Apache::VMonitor::Config{$_} != 0
    ? push @hide, $_
    : push @show, $_;
  }

  print "Show: ", 
    map({ qq{[ <A HREF="@{[get_url($_ => 1)]}">$_</A> ]}
	} @show
       ) , "\n"
	  if @show;

  print "Hide: ", 
    map({ qq{[ <A HREF="@{[get_url($_ => 0)]}">$_</A> ]}
	} @hide
       ) if @hide;

  print "</FONT><HR></PRE>";

} # end of sub choice_bar

############
sub verbose{

  return unless $Apache::VMonitor::Config{VERBOSE};  

  foreach (sort keys %Apache::VMonitor::Config) {
    (my $note = $Apache::VMonitor::abbreviations{$_}) =~ s/\n\n/<P>\n/mg;
    print "$note<HR>"   
      if $Apache::VMonitor::Config{$_}
  }

} # end of sub verbose  


%Apache::VMonitor::abbreviations = 
  (

   VERBOSE =>
   qq{
     <B>Verbose option</B>

     Enables Verbose mode - displays an explanation and abbreviation
     table for each enabled section.

   },

   REFRESH  =>
   qq{
     <B>Refresh Section</B>

       You can tune the automatic refresh rate by clicking on the
       number of desired rate (in seconds). 0 (zero) means "no
       automatic refresh".
   },

   BLINKING =>

   qq{
     <B>Blinking Option</B>

       Apache::VMonitor is capable of visual alerting when something
       is going wrong, as of this moment it colors the problematic
       data in red (e.g when OS starts heavy swapping or file system is
       close to free disk space shortage), and to bring more attention
       it can make it blink. So this option allows you to control this
       mode.

   },

   TOP =>
   qq{
     <B>Top section</B>

       Represents the emulation of top utility, while individually
       reporting only on httpd processes, and provides information
       specific to these processes.

       <B>1st</B>: current date/time, uptime, load average: last 1, 5 and 15
       minutes, total number of processes and how many are in the
       running state.

       <B>2nd</B>: CPU utilization in percents: by processes in user, nice,
       sys and idle state

       <B>3rd</B>: RAM utilization: total available, total used, free, shared
       and buffered

       <B>4th</B>: SWAP utilization: total available, total used, free, how
       many paged in and out

       <B>5th</B>: HTTPD processes:

<UL><LI>
       First line reports the status of parent process (mnemonic 'par')

       Columns:

	 <B>PID</B>   = Id<BR>
	 <B>M</B> = apache mode (See below a full table of abbreviations)<BR>
	 <B>Size</B>  = total size<BR>
	 <B>Share</B> = shared size<BR>
	 <B>VSize</B> = virtual size<BR>
	 <B>RSS</B>   = resident size<BR>
         <B>AccessNum</B>  = How many requests served <BR>
	   &nbsp;&nbsp;&nbsp;&nbsp;<B>CHLD</B> = This Child<BR>
	   &nbsp;&nbsp;&nbsp;&nbsp;<B>SLOT</B> = This Slot <BR>
	 ( when child quits a new child takes its place at the same slot)<BR>
         <B>ByteTransf</B> = How many bytes were transferred (downstream)<BR>
	   &nbsp;&nbsp;&nbsp;&nbsp;<B>CHLD</B> = This Child<BR>
	   &nbsp;&nbsp;&nbsp;&nbsp;<B>SLOT</B> = This Slot <BR>
	 <B>Client</B>  = Client IP<BR>
	 <B>Request</B> = Request (first 64 chars)<BR>

</LI>
<LI>	 Last line reports:

	 <B>Total</B> = a total size of the httpd processes (by summing the SIZE value of each process)

         <B>Approximate real size (-shared)</B> = 

1. For each process sum up the difference between shared and system
memory.

2. Now if we add the share size of the process with maximum
shared memory, we will get all the memory that actually is being
used by all httpd processes but the parent process.

Please note that this might be incorrect for your system, so you use
this number on your own risk. I have verified this number, by writing
it down and then killing all the servers. The system memory went down
by approximately this number. Again, use this number wisely!

</LI>
<LI>The <B>modes</B> a process can be in:

<CODE><B>_</B></CODE> = Waiting for Connection<BR>
<CODE><B>S</B></CODE> = Starting up<BR>
<CODE><B>R</B></CODE> = Reading Request<BR>
<CODE><B>W</B></CODE> = Sending Reply<BR>
<CODE><B>K</B></CODE> = Keepalive (read)<BR>
<CODE><B>D</B></CODE> = DNS Lookup<BR>
<CODE><B>L</B></CODE> = Logging<BR>
<CODE><B>G</B></CODE> = Gracefully finishing<BR>
<CODE><B>.</B></CODE> = Open slot with no current process<BR>
</LI>
</UL>
   },

   MOUNT    =>
   qq{
<B>Mount section</B>

Reports about all mounted filesystems

<B>DEVICE</B>  = The name of the device<BR>
<B>MOUNTED ON</B>  = Mount point of the mounted filesystem<BR>
<B>FS TYPE</B> = The type of the mounted filesystem<BR>

   },

   FS_USAGE =>
   qq{
<B>File System usage</B>

Reports the utilization of all mounted filesystems:

<B>FS</B>  = the mount point of filesystem<BR>

<B>Blocks (1k)</B> = Space usage in blocks of 1k bytes<BR>

<B>Total</B>  = Total existing<BR>
<B>SU Avail</B> = Available to superuser (root) (tells how much space let for real)<BR>
<B>User Avail</B> = Available to user (non-root) (user cannot use last 5% of each filesystem)

<B>Usage</B> = utilization in percents (from user perspective, when it reaches
100%, there are still 5% but only for root processes)

<B>Files</B>: = File nodes usage<BR>
<B>Total</B>   = Total nodes possible <BR>
<B>Avail</B> = Free nodes<BR>
<B>Usage</B> = utilization in percents<BR>

   },

   NETLOAD  =>
   qq{
<B>Netload section</B>

reports network devices statistics:

<B>TX</B> = transmitted<BR>
<B>RX</B> = received<BR>
<B>Total</B> = total :)<BR>
<B>MTU</B> = Maximum Transfer Unit<BR>

Note that in order to report on device 'foo' you should add it to
@Apache::VMonitor::NETDEVS array at the server startup. e.g. to get
the report for 'eth0' and 'lo', set:

<CODE><B>\@Apache::VMonitor::NETDEVS = qw(lo eth0);</B></CODE>


   },

  );


# I have tried to plug this module into an Apache::Status, but it
# wouldn't quite work, because Apache::VMonitor needs to send refresh
# headers, and it's impossible when Apache::Status takes over
# 
# I guess we need a new method for Apache::Status, ether to
# automatically configure a plugged module and just link to a new
# location, with a plugged module autonomic or let everything work
# thru Apache::Status without it intervening with headers and html
# snippets, just let the module to overtake the operation

#Apache::Status->menu_item
# ('VisualMonitor' => 'VisualMonitor',
#  \&handler
# ) if $INC{'Apache.pm'} && Apache->module('Apache::Status');

1;

__END__

=pod

=head1 NAME

Apache::VMonitor - Visual System and Server Processes Monitor

=head1 SYNOPSIS

  # Configuration in httpd.conf
  <Location /sys-monitor>
    SetHandler perl-script
    PerlHandler Apache::VMonitor
  </Location>

  # startup file or <Perl> section:
  use Apache::VMonitor();
  $Apache::VMonitor::Config{BLINKING} = 1;
  $Apache::VMonitor::Config{REFRESH}  = 0;
  $Apache::VMonitor::Config{VERBOSE}  = 0;
  $Apache::VMonitor::Config{TOP}      = 1;
  $Apache::VMonitor::Config{MOUNT}    = 1;
  $Apache::VMonitor::Config{FS_USAGE} = 1;
  $Apache::VMonitor::Config{NETLOAD}  = 1;
  @Apache::VMonitor::NETDEVS  = qw(lo eth0);

=head1 DESCRIPTION

This module emulates the reporting functionalities of top(), mount(),
df() and ifconfig() utilities. It has a visual alert capabilities and
configurable automatic refresh mode. All the sections can be
shown/hidden dynamically through the web interface.

=over

=item refresh mode

From within a displayed monitor (by clicking on a desired refresh
value) or by setting of B<$Apache::VMonitor::Config{REFRESH}> to a number of
seconds between refreshes you can control the refresh rate. e.g:

  $Apache::VMonitor::Config{REFRESH} = 60;

will cause the report to be refreshed every single minute.

Note that 0 (zero) turns automatic refreshing off.

=item top() emulation

Just like top() it shows current date/time, machine uptime, average
load, all the system CPU and memory usage: CPU Load, Mem and Swap
usage.

The top() section includes a swap space usage visual alert
capability. The color of the swap report will be changed:

   1) 5Mb < swap < 10 MB             color: light red
   2) 20% < swap (swapping is bad!)  color: red
   3) 70% < swap (swap almost used!) color: red + blinking

Note that you can turn off blinking with:

  $Apache::VMonitor::Config{BLINKING} = 0;

The module doesn't alert when swap is being used just a little (<5Mb),
since it happens most of the time, even when there is plenty of free
RAM.

Then just like in real top() there is a report of the processes, but
it shows all the relevant information about httpd processes only! The
report includes the status of the process (starting, reading, sending
waiting and etc), process' id, size, shared, virtual and resident
size, bytes transferred by process/slot and number of requests
processed by process/slot and a report about the used segments: text,
shared lib, date and stack. It shows the last client's IP and Request
(only 64 chars, as this is the maximum length stored by underlying
Apache core library).

At the end there is a calculation of the total memory being used by
all httpd processes as reported by kernel, plus a result of an attempt
to approximately calculate the real memory usage when sharing is in
place. How do I calculate this:

1. For each process sum up the difference between shared and system
memory.

2. Now if we add the share size of the process with maximum
shared memory, we will get all the memory that actually is being
used by all httpd processes but the parent process.

Please note that this might be incorrect for your system, so you use
this number on your own risk. I have verified this number, by writing
it down and then killing all the servers. The system memory went down
by approximately this number. Again, use this number wisely!

If you don't want the top() section to be displayed set:

  $Apache::VMonitor::Config{TOP} = 0;

The default is to display this section.

=item mount() emulation

This section reports about mounted filesystems, the same way as if you
have called mount() with no parameters.

If you want the mount() section to be displayed set:

  $Apache::VMonitor::Config{MOUNT} = 1;

The default is NOT to display this section.

=item df() emulation 

This section completely reproduces the df() utility. For each mounted
filesystem it reports the number of total and available blocks (for
both superuser and user), and usage in percents.

In addition it reports about available and used filenodes in numbers
and percents.

This section has a capability of visual alert which is being triggered
when either some filesystem becomes more than 90% full or there are
less 10% of free filenodes left. When that happens the filesystem
related line will go bold and red and a mounting point will blink if
the blinking is turned on. You can the blinking off with:

  $Apache::VMonitor::Config{BLINKING} = 0;

If you don't want the df() section to be displayed set:

  $Apache::VMonitor::Config{FS_USAGE} = 0;

The default is to display this section.

=item ifconfig() emulation 

This section emulates the reporting capabilities of the ifconfig()
utility. It reports how many packets and bytes were received and
transmitted, their total, counts of errors and collisions, mtu
size. in order to display this section you need to set two variables:

  $Apache::VMonitor::Config{NETLOAD} = 1;

and to set a list of net devices to report for, like:

  @Apache::VMonitor::NETDEVS  = qw(lo eth0);

The default is NOT to display this section.

=item abbreviations and hints

The monitor uses many abbreviations, which might be knew for you. If
you enable the VERBOSE mode with:

  $Apache::VMonitor::Config{VERBOSE} = 1;

this section will reveal all the full names of the abbreviations at
the bottom of the report.

The default is NOT to display this section.

=back

=head1 CONFIGURATION


To enable this module you should modify a configuration in
B<httpd.conf>, if you add the following configuration:

  <Location /sys-monitor>
    SetHandler perl-script
    PerlHandler Apache::VMonitor
  </Location>

The monitor will be displayed when you request
http://localhost/sys-monitor or alike.

You can control the behavior of this module by configuring the
following variables in the startup file or inside the B<<Perl>>
section.

Module loading:

  use Apache::VMonitor();

Monitor reporting behavior:

  $Apache::VMonitor::Config{BLINKING} = 1;
  $Apache::VMonitor::Config{REFRESH}  = 0;
  $Apache::VMonitor::Config{VERBOSE}  = 0;

Control over what sections to display:

  $Apache::VMonitor::Config{TOP}      = 1;
  $Apache::VMonitor::Config{MOUNT}    = 1;
  $Apache::VMonitor::Config{FS_USAGE} = 1;
  $Apache::VMonitor::Config{NETLOAD}  = 1;

What net devices to display if B<$Apache::VMonitor::Config{NETLOAD}> is ON:

  @Apache::VMonitor::NETDEVS  = qw(lo);

Read the L<DESCRIPTION|/DESCRIPTION> section for a complete
explanation of each of these variables.

=head1 DYNAMIC RECONFIGURATION

C<Apache::VMonitor> allows you to dynamically turn on and off all the
sections and enter a verbose mode that explains each section and the
used abbreviations.

=head1 PREREQUISITES

You need to have B<Apache::Scoreboard> and B<GTop> installed. And of
course a running mod_perl enabled apache server.

=head1 BUGS

Netload section reports negative bytes transferring when the numbers
are very big, consider it a bug or a feature, but the problem is in
the underlying libgtop library or GTop module and demands
investigation.

=head1 TODO

I want to include a report about open file handlers per process to
track file handlers leaking. It's easy to do that by just reading them
from C</proc/$pid/fd> but you cannot do that unless you are
root. C<libgtop> doesn't have this capability - if you come up with
solution, please let me know. Thanks!

=head1 SEE ALSO

L<Apache>, L<mod_perl>, L<Apache::Scoreboard>, L<GTop>

=head1 AUTHORS

Stas Bekman <sbekman@iname.com>

=head1 COPYRIGHT

The Apache::VMonitor module is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=cut
