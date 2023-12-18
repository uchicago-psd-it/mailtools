#!/usr/bin/env perl 

use warnings;
use strict;

use POSIX qw(strftime);
use File::Find;
use File::stat;
use Getopt::Std;
use Time::Local;
use Data::Dumper;

my %opts = ( i => "/var/mail", d => "mail", m => 1, M => 0, U => 500 );

getopts('hanmMvU:u:f:i:d:c', \%opts);

if ($opts{'h'}) {
  &usage;
  exit 0;
}
if ($opts{'M'}) { $opts{'m'} = 0; }
if ($opts{'u'}) { $opts{'n'} = 1; }

my $doCounts = $opts{'n'} ? 1 : 0;
my $doVerbose = $opts{'v'} ? 1 : 0;


if (($opts{'a'} and ($opts{'u'} or $opts{'f'})) or
    ($opts{'u'} and $opts{'f'}) or
    not ($opts{'a'} or $opts{'u'} or $opts{'f'})) {
  print "Must specify exactly one of -a, -u, or -f\n";
  &usage;
  exit;
}

sub usage() {
  print "Usage: $0 [-v] { -u <username> | { -a [-U <uid>] | -f <filename> } [-c] } [-n] [ -m | -M ] [ -i <inbox path> ] [ -d <mail directory> ]\n";
  print "-v:            Verbose mode. Print more details during processing.";
  print "-a:            look up all users from passwd database\n";
  print "-U uid:        Minimum UID to use when scanning passwd database (default 500)\n";
  print "-u username:   look up user username\n";
  print "-f filename:   look up users in file filename\n";
  print "-c:            output in CSV format.\n";
  print "               ignored with -u\n";
  print "-n:            include message counts\n";
  print "-m:            use mbox format (default)\n";
  print "-M:            use Maildir format [NYI]\n";
  print "-i path:       path to directory containing inbox file(s)\n";
  print "               defaults to '/var/mail'\n";
  print "-d path:       relative path within user's home directory to mail folders.\n";
  print "               defaults to 'mail'\n";
}

sub get_filesize
{
    my $file = shift();

    my $stat = stat($file) || die "stat($file): $!\n";
    my $size = $stat->size or 0;

    return $size;
}

sub prettifySize
{
    my $size = shift();
    if ($size > 1099511627776)  #   TiB: 1024 GiB
    {
        return sprintf("%.2f TB", $size / 1099511627776);
    }
    elsif ($size > 1073741824)  #   GiB: 1024 MiB
    {
        return sprintf("%.2f GB", $size / 1073741824);
    }
    elsif ($size > 1048576)     #   MiB: 1024 KiB
    {
        return sprintf("%.2f MB", $size / 1048576);
    }
    elsif ($size > 1024)        #   KiB: 1024 B
    {
        return sprintf("%.2f KB", $size / 1024);
    }
    else                        #   bytes
    {
        return "$size byte" . ($size == 1 ? "" : "s");
    }
}

# sub readMbox
# examine an mbox-type mail folder to analyze number of messages, dates, and size
# returns a hash of size, count, date where date is the date of the most recent message
# usage: &readMbox(filepath)
#   filepath: full path to the file
sub readMbox {
  my $file = shift();
  my $mboxSize = &get_filesize($file) || 0;
  open(my $fh, '<', $file) or die "Cannot open mbox file $file: $!";
  my $date;
  my $count = 0;
  my $timestamp = 0;

  if ($doCounts) {
    while (my $line = readline($fh)) {
      if ($line =~ /^From +\S+ *\w{3} \w{3}\s+\d{1,2} \d{2}:\d{2}:\d{2} \d{4}/) {
        $count++;
        my ($month, $day, $hour, $minute, $second, $year) = 
          ($line =~ /^From +\S+ *\w{3} (\w{3})\s+(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})/); 
        my %months = ( Jan => 0, Feb => 1, Mar => 2, Apr => 3,
                       May => 4, Jun => 5, Jul => 6, Aug => 7,
                       Sep => 8, Oct => 9, Nov => 10, Dec => 11 );
        $month = $months{$month};
        $year = $year - 1900;
        my $time = timelocal($second, $minute, $hour, $day, $month, $year);
        if ($time > $timestamp) {
          $timestamp = $time;
        }
      }
    }
  }
  
  close($fh);

  $date = strftime("%F", localtime($timestamp));

  return (size => $mboxSize, count => $count, date => $date);
}

### Report fields
my $headerName = "Folder Name";
my $headerFullName = "Full Name";
my $headerSize = "Mailbox Size";
my $headerCount = "Messages";
my $headerTimestamp = "Newest Message";
my $headerForward = "Forward Address";

### Field lengths for formatting
# Start by using the report headers as max length and grow if needed
my $longestName = length($headerName);
my $longestFullName = length($headerFullName);
my $longestSize = length($headerSize);
my $longestCount = length($headerCount);
my $longestTimestamp = length($headerTimestamp);
my $longestForward = length($headerForward);

#### mbox. port over maildir later
my $mboxPath = $opts{'d'};
my $mboxInboxes = $opts{'i'};

# Username specified, get all the gory details
if ($opts{'u'}) {
  my $mailUser = $opts{'u'};
  my $fullName = `getent passwd $mailUser | cut -d: -f5`;
  chomp $fullName;
  $fullName =~ s/,.*//;
  if (length($fullName) > $longestFullName) {
    $longestFullName = length($fullName);
  }
  my $userDirectory = `getent passwd $mailUser | cut -d: -f6`;
  chomp $userDirectory;
  my $forward = "";
  my $mailDir = "$userDirectory/$mboxPath";
  my $mailInbox = "$mboxInboxes/$mailUser";
  my %mailboxes;
  my @mailFolders;
  my $totalCount = 0;
  my $totalSize = 0;
  find ( 
    { 
      wanted => sub {
        $File::Find::prune = 1 if /^\..+/;
        return unless -f;
        return if /^\./;
        my $mailFolder = $File::Find::name =~ s/^$mailDir\///r;
        push @mailFolders, $mailFolder;
      },
      follow => 1 
    }, $mailDir);

  my %inbox = &readMbox($mailInbox);
  $totalCount += $inbox{'count'};
  $totalSize += $inbox{'size'};
  foreach my $mailFolder (@mailFolders) {
    if (length($mailFolder) > $longestName) {
      $longestName = length($mailFolder);
    }
    my %mailbox = &readMbox("$mailDir/$mailFolder");
    if (length(&prettifySize($mailbox{'size'})) > $longestSize) {
      $longestSize = length(&prettifySize($mailbox{'size'}));
    }
    if (length($mailbox{'count'}) > $longestCount) {
      $longestCount = length($mailbox{'count'});
    }
    $mailboxes{$mailFolder} = \%mailbox;
    $totalCount += $mailbox{'count'};
    $totalSize += $mailbox{'size'};
  }

  ### Print out the report
  # Ensure an extra space after each field
  $longestName++; $longestSize++; $longestCount++;
  # Header
  printf "%-${longestName}s %-${longestSize}s %-${longestCount}s %-${longestTimestamp}s\n", $headerName, $headerSize, $headerCount, $headerTimestamp;
  print '-' x ($longestName + $longestSize + $longestCount + $longestTimestamp + 3), "\n";
  # Inbox
  printf "%-${longestName}s %-${longestSize}s %-${longestCount}s %-${longestTimestamp}s\n", "INBOX", &prettifySize($inbox{'size'}), $inbox{'count'}, $inbox{'date'};
  # Other Mailboxes
  foreach my $reportLine ( @mailFolders ) {
    printf "%-${longestName}s %-${longestSize}s %-${longestCount}s %-${longestTimestamp}s\n", $reportLine, &prettifySize(${mailboxes{$reportLine}}{'size'}), ${mailboxes{$reportLine}}{'count'}, ${mailboxes{$reportLine}}{'date'};
  }
  # Footer
  print '-' x ($longestName + $longestSize + $longestCount + $longestTimestamp + 3), "\n";
  printf "%-${longestName}s %-${longestSize}s %-${longestCount}s\n", "TOTAL", &prettifySize($totalSize), $totalCount;
  exit;
} 

# User list specified or "all"
# Print a summary of all included users
if ($opts{'a'} or $opts{'f'}) {
  $headerName = "User";
  $longestName = length($headerName);
  my @userlist;
  my %userMailboxes;
  if ($opts{'a'}) {
    #die "-a is not yet implemented.\n"
    my @output = `getent passwd`; 
    foreach my $line (@output) {
      chomp($line);
      my @l = split(':',$line);
      if ($l[2] >= $opts{'U'}) {
        push(@userlist, $l[0]);
      }
    }
    if (-f "/etc/aliases") {
      open(my $fh, '<', "/etc/aliases") or die "$!\n";
      while (my $line = readline($fh)) {
        chomp($line);
        $line =~ s/#.*//;
        if ($line =~ /^\S+:\s*\S+(?:@\S+)?/) {
          my ($n, $t) = ($line =~ /^(\S+):\s*(.*)$/);
          my @getent = split(':', `getent passwd $n`);
          next if (@getent and $getent[2] < $opts{'U'});
          unless ( grep(/^$n$/, @userlist) ) {
            $userMailboxes{$n}{'fullName'} = "";
            $userMailboxes{$n}{'count'} = 0;
            $userMailboxes{$n}{'size'} = 0;
            $userMailboxes{$n}{'forward'} = $t;
            if (length($n) > $longestName) {
              $longestName = length($n);
            }
            if (length($userMailboxes{$n}{'forward'}) > $longestForward) {
              $longestForward = length($userMailboxes{$n}{'forward'});
            }
          }
        }
      }
    }
  }
  if ($opts{'f'}) {  
    my $userFile = $opts{'f'};
    open(my $fh, '<', $userFile) or die "Cannot open userlist file $userFile: $!";
    while (my $line = readline($fh)) {
      chomp($line);
      push(@userlist, $line);
    }
    close($fh); 
  }
  foreach my $mailUser (@userlist) {
    print "BEGIN USER $mailUser\n" if $doVerbose;
    my $count = 0;
    my $size = 0;
    my $forward = "";

    my $userDirectory = `getent passwd $mailUser | cut -d: -f6`;
    chomp $userDirectory;
    my $fullName = `getent passwd $mailUser | cut -d: -f5`;
    chomp $fullName;
    $fullName =~ s/,.*//;
    if (length($fullName) > $longestFullName) {
      $longestFullName = length($fullName);
    }
    my $mailDir = "$userDirectory/$mboxPath";
    my $mailInbox = "$mboxInboxes/$mailUser";

#    print "DEBUG: BEGIN INBOX\n";
    my %inbox = (-f $mailInbox ) ? &readMbox($mailInbox) : ( count => 0, size => 0 );
    $count += $inbox{'count'} if $inbox{'count'};
    $size += $inbox{'size'} if $inbox{'size'};
#    print "DEBUG: END INBOX\n";

    my @mailFolders;
    find (
      {
        wanted => sub {
          $File::Find::prune = 1 if /^\..+/;
          return unless -f;
          return if /^\./;
          my $mailFolder = $File::Find::name =~ s/^$mailDir\///r;
          push @mailFolders, $mailFolder;
        },
        follow => 1
      }, $mailDir) unless !-e $mailDir;

    foreach my $mailFolder (@mailFolders) {
      #print "DEBUG: BEGIN FOLDER $mailFolder\n";
      my %mailbox = &readMbox("$mailDir/$mailFolder");
      $count += $mailbox{'count'};
      $size += $mailbox{'size'};
      #print "DEBUG: END FOLDER $mailFolder\n";
    }

    if (length($mailUser) > $longestName) {
      $longestName = length($mailUser);
    }
    if (length(&prettifySize($size)) > $longestSize) {
      $longestSize = length(&prettifySize($size));
    }
    if (length($count) > $longestCount) {
      $longestCount = length($count);
    }

    ### Check forwarding rules
    # Start with .procmailrc rules
    if (-f "$userDirectory/.procmailrc") {
      open(my $fh, '<', "$userDirectory/.procmailrc") or die "$!\n";
      my $flag = 0;
      while (my $line = readline($fh)) {
        chomp($line);
        if ($line =~ /^:0/) {
          $flag = 1;
          next;
        }
        if ($flag) {
          if ($line =~ /^!\s*\S+@\S+/) {
            $forward = $line =~ s/^!\s*(.*)/$1/r;
          } else {
            $flag = 0;
          }
        }
      }
      close($fh);
    } 
    # Check for .forward files
    if (-f "$userDirectory/.forward") {
      open(my $fh, '<', "$userDirectory/.forward") or die "$!\n";
      while (my $line = readline($fh)) {
        chomp($line);
        if ($line =~ /^\S+@\S+/) {
          $forward = $line;
        }
      }
      close($fh);
    }
    $userMailboxes{$mailUser} = { size => $size, count => $count};  #unless ($count == 0 and $doCounts);
    $userMailboxes{$mailUser}{'fullName'} = $fullName;
    $userMailboxes{$mailUser}{'forward'} = $forward;
    if (length($userMailboxes{$mailUser}{'forward'}) > $longestForward) {
      $longestForward = length($userMailboxes{$mailUser}{'forward'});
    }

    print "DEBUG: END USER $mailUser\n" if $doVerbose;
  }

  # Check for any other forwards in /etc/aliases
  if (-f "/etc/aliases") {
    open(my $fh, '<', "/etc/aliases") or die "$!\n";
    while (my $line = readline($fh)) {
      chomp($line);
      $line =~ s/#.*//;
      if ($line =~ /^\S+:\s*\S+(?:@\S+)?/) {
        my ($n, $t) = ($line =~ /^(\S+):\s*(.*)$/);
        if ($userMailboxes{$n}) {
          $userMailboxes{$n}{'forward'} = $t;
          if (length($userMailboxes{$n}{'forward'}) > $longestForward) {
            $longestForward = length($userMailboxes{$n}{'forward'});
          }
        }
      }
    }
  }

  #print Dumper(\%userMailboxes);
  ### Print out the report
  # Ensure an extra space after each field
  $longestName++; $longestSize++; $longestCount++;
  # Header
  if ($opts{'c'}) {
    my @fields = ($headerName, $headerFullName, $headerSize);
    push(@fields, $headerCount) if $doCounts;
    push(@fields, $headerForward);
    printf "%s,%s,%s," . ($doCounts ? "%s," : "") . "%s\n", @fields; 
    foreach my $userMailbox (sort keys %userMailboxes) {
      my %box = %{$userMailboxes{$userMailbox}};
      my @fields = ($userMailbox, $box{'fullName'}, &prettifySize($box{'size'}));
      push(@fields, $box{'count'}) if $doCounts;
      push(@fields, $box{'forward'});
      printf "%s,%s,%s," . ($doCounts ? "%s," : "") . "%s\n", @fields;
    }
    #if ($doCounts) {
    #  printf "%s,%s,%s,%s,%s\n", $headerName, $headerFullName, $headerSize, $headerCount, $headerForward;
    #  foreach my $userMailbox (sort keys %userMailboxes) {
    #    my %box = %{ $userMailboxes{$userMailbox}};
    #    printf "%s,%s,%s,%s,%s\n", $userMailbox, $box{'fullName'}, &prettifySize($box{'size'}), 
    #                               $box{'count'}, $box{'forward'};
    #  }
    #} else {
    #  printf "%s,%s,%s,%s\n", $headerName,$headerFullName,$headerSize,$headerForward;
    #  foreach my $userMailbox (sort keys %userMailboxes) {
    #    my %box = %{ $userMailboxes{$userMailbox}};
    #    printf "%s,%s,%s,%s\n", $userMailbox, $box{'fullName'}, &prettifySize($box{'size'}), $box{'forward'};
    #  }
    #}

  } else {
    my @fields = ($headerName, $headerFullName, $headerSize);
    push(@fields, $headerCount) if $doCounts;
    push(@fields, $headerForward);
    printf "%-${longestName}s %-${longestFullName}s %-${longestSize}s " . ($doCounts ? "%-${longestCount}s " : "") . "%-${longestForward}s\n", @fields;
    print '-' x ($longestName + $longestFullName + $longestSize + ($doCounts ? $longestCount+1 : 0) + $longestForward + 3), "\n";
    foreach my $userMailbox (sort keys %userMailboxes) {
      my %box = %{$userMailboxes{$userMailbox}};
      my @fields = ($userMailbox, $box{'fullName'}, &prettifySize($box{'size'}));
      push(@fields, $box{'count'}) if $doCounts;
      push(@fields, $box{'forward'});
      printf "%-${longestName}s %-${longestFullName}s %-${longestSize}s " . ($doCounts ? "%-${longestCount}s " : "") . "%-${longestForward}s\n", @fields;
    }
    #if ($doCounts) {
    #  printf "%-${longestName}s %-${longestFullName}s %-${longestSize}s %-${longestCount}s %-${longestForward}s\n", $headerName, $headerFullName, $headerSize, $headerCount, $headerForward;
    #  print '-' x ($longestName + $longestFullName + $longestSize + $longestCount + $longestForward + 2), "\n";
    #  foreach my $userMailbox (sort keys %userMailboxes) {
    #    my %box = %{ $userMailboxes{$userMailbox}};
    #    printf "%-${longestName}s %-${longestFullName}s %-${longestSize}s %-${longestCount}s %-${longestForward}s\n", $userMailbox, $box{'fullName'},
    #                                                                                    &prettifySize($box{'size'}), $box{'count'}, $box{'forward'};
    #  }
    #} else {
    #  printf "%-${longestName}s %-${longestFullName}s %-${longestSize}s %-${longestForward}s\n", $headerName, $headerFullName, $headerSize, $headerForward;
    #  print '-' x ($longestName + $longestFullName + $longestSize + $longestForward + 2), "\n";
    #  foreach my $userMailbox (sort keys %userMailboxes) {
    #    my %box = %{ $userMailboxes{$userMailbox}};
    #    printf "%-${longestName}s %-${longestFullName}s %-${longestSize}s %-${longestForward}s\n", $userMailbox, $box{'fullName'}, &prettifySize($box{'size'}), $box{'forward'};
    #  }
    #}
  }
  exit;
}
 
#my $mailInbox = $ARGV[0];
#my %testbox = &readMbox($mailInbox);
#print "Mailbox size: $testbox{'size'}\n";
#print "Message count: $testbox{'count'}\n";
#print "Latest message: $testbox{'date'}\n";
