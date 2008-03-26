
# Session.pm : (c) 2000 Matt Hucke 
#
# v1.0 01/2000
# v1.1 02/2005 - better constructor, better error handling, general cleanup
# v2.0 04/2005 - renamed and rewrote for Baldrick project, broke off base class Session.
# v3.0 08/2007 - major rewrite, cleanup, verify checking

package Baldrick::FileSession;

use strict;
use FileHandle;
use DirHandle;

use Baldrick::Util;
use Baldrick::Session;

our @ISA = qw(Baldrick::Session Baldrick::Turnip);

our $PATTERN = '^[a-zA-Z0-9]+\.ses';

sub _setupDirectory # ()
# Try to find an appropriate directory for session files, beginning
# with what the admin requested in the config.
{
	my ($self) = @_;

    my $srv = $self->{_servername} || $ENV{SERVER_NAME} || 'deflt';
    $srv =~ s#[/\\;]##g; # clean.
    $srv =~ s/^www\.//; # truncate.

	my @places = (
		$self->getConfig('directory'), 
        "/tmp/sessions/$srv",
        "/tmp/sessions",
		"../sessions",
        "/tmp",
        "/var/tmp",
	);

	foreach my $dir (@places)
	{
        next if (!$dir);

		return $dir if ((-d $dir) && (-w $dir));
		mkdir ($dir, oct("0755"));
		return $dir if ((-d $dir) && (-w $dir));
	} 

	$self->abort("couldn't find anywhere to put the session files in:" .
        join(", ", @places));
}

sub _getFileName # ( $sid )
{
    my ($self, $sid) = @_;

    $self->{_directory} ||= $self->_setupDirectory();

    $self->abort("getFileName() called without SID argument") if (!$sid);

    return "$self->{_directory}/$sid.ses";
}

sub loadAnySession
## Load an existing session file into $args{out}
# DO NOT MODIFY ANY PART OF $self !! 
{
    my ($self, %args) = @_;

    my $sid = requireArg(\%args, 'sid');

    my $fn = $self->_getFileName($sid);
    my $fh = new FileHandle($self->_getFileName($sid), 'r' );

    if (!$fh)
    {
        $self->writeLog("[Session] cannot load session $sid: $!.\n") 
            unless ($args{quiet});
        return -1;
    } 

    my $out = requireArg(\%args, 'out');
	while (my $line = <$fh>)
    {
        chomp($line);        
        my $equals = index($line, '=');
        if ($equals>0)
        {
            my $k = substr($line, 0, $equals);
            my $v = substr($line, $equals+1);

            $v =~ s/\\\n/\n/g;        # put linefeeds back in
            $out->{$k} = $v;
        }
    }

    $fh->close();
    return 0;
}

sub write # ()
{
    my ($self, %args) = @_;

    my $creating = $args{create} || 0;
    my $mode = $creating ? 
        O_WRONLY | O_CREAT | O_EXCL :     # linux has no O_EXLOCK
        O_WRONLY | O_TRUNC | O_EXLOCK ;

    my $verb = $creating ? "creat" : "writ";

    my $fname = $self->_getFileName( $self->getID() );
    $self->mutter("${verb}ing session file $fname");
    my $fh = new FileHandle($fname, $mode);
    if (!$fh)
    {
        $self->abort("[Session] cannot write $fname, mode $mode: $!");
    } 

    my $con = $self->getContents();
    foreach my $k (sort keys %$con)
    {
        my $v=$con->{$k};
        $v=~s/\n/\\n/g;
        $fh->print("$k=$v\n");
    } 
    $fh->close();
    return 0;
}


sub _idInUse
{
	my ($self, $id) = @_;

	my $sfile = $self->_getFileName($id);

	return 1 if (-f $sfile);
	return 0;
}	

sub cleanupExpired
# Clean up other session files that have expired.
{
    my ($self, %args) = @_;

    return 0 unless ($args{maxidle} || $args{lifespan});

    my $delCount = 0;
    my $dir = ($self->{_directory} || $self->_setupDirectory());

    my $dh = new DirHandle( $dir );
    return -1 unless (defined($dh));

    my $now = time();
    my ($action, $actionArg) = split(/\s+/, $self->getConfig('cleanup-action'));
    if ($action eq 'moveto')
    {
        mkdir($actionArg) unless (-d $actionArg);
    } 

    while (my $fn = $dh->read())
    {
        next unless ($fn =~ m/$PATTERN/);

        my $fullpath = $dir . "/" . $fn;

        my @stats = stat($fullpath);
        next if ($#stats< 10);

        if (Baldrick::Session::_staticCheckSessionExpiration(
                %args, age =>  $now - $stats[10], idle => $now - $stats[9] )
            )
        {
            if ($action eq 'moveto' && $actionArg)
            {
                my $outfile = $actionArg . "/" . $fn;
                if (!rename($fullpath, $outfile))
                {   
                    $self->writeLog("session-cleanup: fail to rename $fullpath to $outfile", warning => 1);
                    unlink($fullpath);
                } 
            } else {
                # default: delete
                unlink($fullpath);
            }
            ++$delCount;
        } 
    }
    return $delCount;
}

sub getAllSessionMetaInfo   # cannot be static as we need directory name.
{
    my ($self, %args) = @_;

    my $dir = ($self->{_directory} || $self->_setupDirectory());

    my $dh = new DirHandle( $dir );
    return 0 unless (defined($dh));
   
    my %sessions;
    
    while (my $fn = $dh->read())
    {
        next unless ($fn =~ m/$PATTERN/);
        my $k = $fn;
        $k =~ s/\.ses$//;

        my $fullpath = $dir . "/" . $fn;

        my @stats = stat($fullpath);
        next if ($#stats< 10);
       
        $sessions{$k} = {
            created => $stats[10],
            modified => $stats[9], 
        };
    }
    return \%sessions; 
}

1;
