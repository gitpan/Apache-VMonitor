package Apache::VMonitor;

BEGIN {
  # RCS/CVS complient:  must be all one line, for MakeMaker
  $Apache::VMonitor::VERSION = do { my @r = (q$Revision: 0.02 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r }; 
}

use strict;
use Apache::Scoreboard ();
use GTop ();

########################
# default config values
########################
# behavior
$Apache::VMonitor::BLINKING = 1;
$Apache::VMonitor::REFRESH  = 0;
$Apache::VMonitor::VERBOSE  = 0;
# sections to show
$Apache::VMonitor::TOP      = 1;
$Apache::VMonitor::MOUNT    = 0;
$Apache::VMonitor::FS_USAGE = 1;
$Apache::VMonitor::NETLOAD  = 0;
# devs to show if $Apache::VMonitor::NETLOAD > 0;
@Apache::VMonitor::NETDEVS  = qw();

###########
sub handler{

    ##############################
    # process and set refresh rate
    ##############################
  my $r = shift;
  my %params = $r->args;
  $Apache::VMonitor::refresh = (defined $params{refresh} and $params{refresh})
    ? int $params{refresh}
    : $Apache::VMonitor::REFRESH;

    # if the refresh is non-null, set the refresh header
  $r->header_out(Refresh =>
		 "$Apache::VMonitor::refresh; URL=".
		 $r->uri."?refresh=$Apache::VMonitor::refresh")
    if $Apache::VMonitor::refresh;

  $r->content_type('text/html');
  $r->send_http_header;

  #################################
  # the html header and refresh bar
  #################################

  print qq{<HTML>
	   <HEAD>
	   <TITLE>Apache::VMonitor</TITLE>
	   </HEAD>
	   <BODY BGCOLOR="white">
	  };

  print
    "&nbsp;" x 10,
    qq{<B><FONT SIZE=+1 COLOR="#339966">Apache::VMonitor</FONT></B>},
    "&nbsp;" x 40,
    "<B>Refresh rate:</B> ",
    join "&nbsp;&nbsp;",
    map
      {
	$Apache::VMonitor::refresh == $_
	  ? qq{[<B><FONT SIZE=+1> $_ </FONT></B>]}
	  : qq{<A HREF="@{[$r->uri]}?refresh=$_"><B>[ $_ ]</B></A>};
      }
	qw(0 5 10 20 30 60);

  print_top();
  abbreviations();

} # end of sub handler

#############
sub print_top{

# META: related to above: probably write an interface to dynamically
# add/remove the sections of report.

  print "<PRE><HR>";
  my $gtop = GTop->new;

  if ($Apache::VMonitor::TOP) {

    my $image = Apache::Scoreboard->image;

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
    my $swap_usage =  $swap_used * 100 / $swap_total;

    if (5000 < $swap_used && $swap_used < 10000) {
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

    ##################################
    # mem usage for each httpd process
    ##################################
      # init the stats hash
    my %total = map {$_ => 0} qw(size real max_shared);

    printf "<HR><B> ##    %4s  %5s %6s %6s %6s  %5s %6s %6s %6s</B>\n", 
      qw(PID SIZE SHARE VSIZE RSS TEXT SHLIB DATA STACK);

    for (my $i=-1; $i<Apache::Constants::HARD_SERVER_LIMIT; $i++) {
      # handle the parent case
      my $pid = ($i==-1) ? getppid() : $image->parent($i)->pid;
      last unless $pid;
      my $proc_mem     = $gtop->proc_mem($pid);
      # is it a GTop bug? if proc_segment() called $proc_mem becomes
      # invalid!  so meanwhile we save the samples and don't use them
      # directly as a printf() params.
      my $size  = $proc_mem->size($pid)  / 1000;
      my $share = $proc_mem->share($pid) / 1000;
      my $vsize = $proc_mem->vsize($pid) / 1000;
      my $rss   = $proc_mem->rss($pid)   / 1000;

      #  total http size update
      $total{size}  += $size;
      $total{real}  += $size-$share;
      $total{max_shared} = $share if $total{max_shared} < $share;

      my $proc_segment = $gtop->proc_segment($pid);
      # handle the parent case
      $i == -1 ? print "par:" : printf "%3.d:",$i+1;
      printf " %6.d %6.d %6.d %6.d %6.d %6.d %6.d %6.d %6.d\n",
	$pid,
	$size,
	$share,
	$vsize,
	$rss,
	$proc_segment->text_rss($pid)  / 1000,
	$proc_segment->shlib_rss($pid) / 1000,
	$proc_segment->data_rss($pid)  / 1000,
	$proc_segment->stack_rss($pid) / 1000;
    } # end of for (my $i=0...

    printf "\n<B>Total:     %5.dK size, %6.dK approx real size (-shared)</B>\n",
      $total{size}, $total{real} + $total{max_shared};

    #  Note how do I calculate the approximate real usage of the memory:
    #  1. For each process sum up the difference between shared and system
    #  memory 2. Now if we add the share size of the process with maximum
    #  shared memory, we will get all the memory that actually is being
    #  used by all httpd processes but the parent process.

    print "<HR>";

  } # end of if ($Apache::VMonitor::TOP)

  #######################
  # mounted filesystems
  #######################
  if ($Apache::VMonitor::MOUNT) {
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
  } # end of if ($Apache::VMonitor::MOUNT)


  #######################
  # filesystem usage
  #######################
  if ($Apache::VMonitor::FS_USAGE) {
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

  } # end of if ($Apache::VMonitor::FS_USAGE)

  #######################
  # net interfaces stats
  #######################
  if ($Apache::VMonitor::NETLOAD) {
    if (@Apache::VMonitor::NETDEVS) {
      #      print "<B>Netload:</B>\n";
      for my $dev (@Apache::VMonitor::NETDEVS) {
	my $netload = $gtop->netload($dev);
	next unless $netload;
	printf "<B>%4s</B>\t       MTU:          %4d, collisions:    %d\n", 
	  $dev, 
	  $netload->mtu($dev),
	  $netload->collisions($dev);

	printf "\tTX:    packets:%10.d, bytes:%10.d, errors:%d\n",
	  $netload->packets_out($dev),
	  $netload->bytes_out($dev),
	  $netload->errors_out($dev);

	printf "\tRX:    packets:%10.d, bytes:%10.d, errors:%d\n",
	  $netload->packets_in($dev),
	  $netload->bytes_in($dev),
	  $netload->errors_in($dev);

	printf "\tTotal: packets:%10.d, bytes:%10.d, errors:%d\n\n",
	  $netload->packets_total($dev),
	  $netload->bytes_total($dev),
	  $netload->errors_total($dev);
      }

    } else {
      print qq{Don't know what devices to monitor...\nHint: set \@Apache::VMonitor::NETDEVS\n};
    } # end of if (@Apache::VMonitor::NETDEVS)

      print "<HR>";
  } # end of if ($Apache::VMonitor::NETLOAD)

} # end of sub print_top


# should blink or not
############
sub blinking{
  return $Apache::VMonitor::BLINKING 
    ? join "", "<BLINK>",@_,"</BLINK>"
    : join "", @_;
} # end of sub blinking


#################
sub abbreviations{

  return unless $Apache::VMonitor::VERBOSE;

    # Abbreviations
  print qq{<PRE>
<B>Abbreviations:</B>
	   PID   = process' id
	   SIZE  = process' size
	   SHARE = process' shared size
	   VSIZE = process' virtual size
	   RSS   = process' resident size
	   TEXT  = process' resident text segments
	   SHLIB = process' resident shared lib segments
	   DATA  = process' resident data segments
	   STACK = process' resident stack segments
	  };

  print "</PRE>\n";
#'

# More hints and explanations will probably come here, if it happens
# for each section, it might be a good idea to make a hash of help
# sections and print them out after or for each section if
# $Apache::VMonitor::VERBOSE is On;

} # end of sub abbreviations


# I have tried to plug this module into an Apache::Status, but it
# wouldn't quite work, because Apache::VMonitor needs to send refresh
# headers, and it's impossible when Apache::Status takes over
# 
# I guess we need a new method for Apache::Status, ether to
# automatically configure a plugged module and just link to a new
# location, with a plugged module autonomical or let everything work
# thru Apache::Status without it intervening with headers and html
# snippets, just let the module to overtake the operation

#Apache::Status->menu_item
# ('VisualMonitor' => 'VisualMonitor',
#  \&handler
# ) if $INC{'Apache.pm'} && Apache->module('Apache::Status');

1;

__END__


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
  $Apache::VMonitor::BLINKING = 1;
  $Apache::VMonitor::REFRESH  = 0;
  $Apache::VMonitor::VERBOSE  = 0;
  $Apache::VMonitor::TOP      = 1;
  $Apache::VMonitor::MOUNT    = 1;
  $Apache::VMonitor::FS_USAGE = 1;
  $Apache::VMonitor::NETLOAD  = 1;
  @Apache::VMonitor::NETDEVS  = qw(lo eth0);

=head1 DESCRIPTION

This module emulates the reporting functionalities of top(), mount(),
df() and ifconfig() utilities. It has a visual alert capabilities and
configurable automatic refresh mode.

=over

=item refresh mode

From within a displayed monitor (by clicking on a desired refresh
value) or by setting of B<$Apache::VMonitor::REFRESH> to a number of
seconds between refreshes you can control the refresh rate. e.g:

  $Apache::VMonitor::REFRESH = 60;

will cause the report to be refreshed every single minute.

Note that 0 (zero) turns refreshing off.

=item top() emulation

Just like top() it shows all the system CPU and
memory usage: CPU Load, Mem and Swap usage.

The top() section includes a swap space usage visual alert
capability. The color of the swap report will be changed:

   1) 5Mb < swap < 10 MB             color: light red
   2) 20% < swap (swapping is bad!)  color: red
   3) 70% < swap (swap almost used!) color: red + blinking

Note that you can turn off blinking with:

  $Apache::VMonitor::BLINKING = 0;

The module doesn't alert when swap is being used just a little (<5Mb),
since it happens most of the time, even when there is plenty of free
RAM.

Then just like in real top() there is a report of the processes, but
it shows all the relevant information about httpd processes only! The
report includes process' id, size, shared, virtual and resident size,
and a report about the used segments: text, shared lib, date and stack.

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

  $Apache::VMonitor::TOP = 0;

The default is to display this section.

=item mount() emulation

This section reports about mounted filesystems, the same way as if you
have called mount() with no parameters.

If you want the mount() section to be displayed set:

  $Apache::VMonitor::MOUNT = 1;

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

  $Apache::VMonitor::BLINKING = 0;

If you don't want the df() section to be displayed set:

  $Apache::VMonitor::FS_USAGE = 0;

The default is to display this section.

=item ifconfig() emulation 

This section emulates the reporting capabilities of the ifconfig()
utility. It reports how many packets and bytes were received and
transmitted, their total, counts of errors and collisions, mtu
size. in order to display this section you need to set two variables:

  $Apache::VMonitor::NETLOAD = 1;

and to set a list of net devices to report for, like:

  @Apache::VMonitor::NETDEVS  = qw(lo eth0);

The default is NOT to display this section.

=item abbreviations and hints

The monitor uses many abbreviations, which might be knew for you. If
you enable the VERBOSE mode with:

  $Apache::VMonitor::VERBOSE = 1;

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

  $Apache::VMonitor::BLINKING = 1;
  $Apache::VMonitor::REFRESH  = 0;
  $Apache::VMonitor::VERBOSE  = 0;

Control over what sections to display:

  $Apache::VMonitor::TOP      = 1;
  $Apache::VMonitor::MOUNT    = 1;
  $Apache::VMonitor::FS_USAGE = 1;
  $Apache::VMonitor::NETLOAD  = 1;

What net devices to display if B<$Apache::VMonitor::NETLOAD> is ON:

  @Apache::VMonitor::NETDEVS  = qw(lo);

Read the L<DESCRIPTION|/DESCRIPTION> section for a complete
explanation of each of these variables.

=head1 PREREQUISITES

You need to have B<Apache::Scoreboard> and B<GTop> installed. And of
course a running mod_perl enabled apache server.

=head1 SEE ALSO

L<Apache>, L<mod_perl>, L<Apache::Scoreboard>, L<GTop>

=head1 AUTHORS

Stas Bekman <sbekman@iname.com>

=head1 COPYRIGHT

The Apache::VMonitor module is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=cut
